import Foundation

struct AppPersistentState: Sendable {
    let jobs: [SyncJob]
    let metadataPresets: [MetadataPreset]
    let photographerLibrary: [PhotographerProfile]
    let serverProfiles: [ServerProfile]
    let metadataAuditEntries: [UUID: [MetadataAuditEntry]]
    let syncFailureEntries: [UUID: [SyncFailureRecord]]

    init(
        jobs: [SyncJob],
        metadataPresets: [MetadataPreset],
        photographerLibrary: [PhotographerProfile],
        serverProfiles: [ServerProfile] = [],
        metadataAuditEntries: [UUID: [MetadataAuditEntry]],
        syncFailureEntries: [UUID: [SyncFailureRecord]]
    ) {
        self.jobs = jobs
        self.metadataPresets = metadataPresets
        self.photographerLibrary = photographerLibrary
        self.serverProfiles = serverProfiles
        self.metadataAuditEntries = metadataAuditEntries
        self.syncFailureEntries = syncFailureEntries
    }
}

struct AppPersistenceLoadResult: Sendable {
    let state: AppPersistentState
    let jobsRecoveredFromBackup: Bool
    let warnings: [String]
}

struct CredentialedJobSaveResult: Sendable {
    let jobs: [SyncJob]
    let savedJob: SyncJob
    let cleanupWarnings: [String]
}

struct CredentialedServerProfileSaveResult: Sendable {
    let jobs: [SyncJob]
    let profiles: [ServerProfile]
    let savedProfile: ServerProfile
    let cleanupWarnings: [String]
}

private struct AppPersistenceTransactionError: LocalizedError {
    let operation: Error
    let rollback: Error

    var errorDescription: String? {
        "The change failed (\(operation.localizedDescription)), and the previous saved state could not be fully restored (\(rollback.localizedDescription))."
    }
}

private struct AppPersistenceRollbackError: LocalizedError {
    let failures: [Error]

    var errorDescription: String? {
        failures.map(\.localizedDescription).joined(separator: "; ")
    }
}

@MainActor
final class AppPersistenceCoordinator {
    private let jobRepository: JobRepository
    private let metadataPresetRepository: MetadataPresetRepository
    private let photographerProfileRepository: PhotographerProfileRepository
    private let serverProfileRepository: ServerProfileRepository
    private let metadataAuditRepository: MetadataAuditRepository
    private let syncFailureRepository: SyncFailureRepository
    private let keychain: KeychainStore

    private var cachedPasswords: [String: String] = [:]
    private var loadedCredentialIDs = Set<String>()

    init(
        jobRepository: JobRepository,
        metadataPresetRepository: MetadataPresetRepository,
        photographerProfileRepository: PhotographerProfileRepository,
        serverProfileRepository: ServerProfileRepository = ServerProfileRepository(),
        metadataAuditRepository: MetadataAuditRepository,
        syncFailureRepository: SyncFailureRepository,
        keychain: KeychainStore
    ) {
        self.jobRepository = jobRepository
        self.metadataPresetRepository = metadataPresetRepository
        self.photographerProfileRepository = photographerProfileRepository
        self.serverProfileRepository = serverProfileRepository
        self.metadataAuditRepository = metadataAuditRepository
        self.syncFailureRepository = syncFailureRepository
        self.keychain = keychain
    }

    func load() -> AppPersistenceLoadResult {
        var warnings: [String] = []

        var serverProfiles: [ServerProfile]
        let serverProfilesLoaded: Bool
        do {
            let result = try serverProfileRepository.loadResult()
            serverProfiles = result.profiles
            serverProfilesLoaded = true
            if result.recoveredFromBackup {
                warnings.append("The server profile library was damaged, so its most recent backup was restored.")
            }
        } catch {
            serverProfiles = []
            serverProfilesLoaded = false
            warnings.append("Saved server profiles could not be loaded: \(error.localizedDescription)")
        }

        let metadataPresets: [MetadataPreset]
        do {
            let result = try metadataPresetRepository.loadResult()
            metadataPresets = result.presets
            if result.recoveredFromBackup {
                warnings.append("The metadata preset library was damaged, so its most recent backup was restored.")
            }
        } catch {
            metadataPresets = []
            warnings.append("Saved metadata presets could not be loaded: \(error.localizedDescription)")
        }

        var photographerLibrary: [PhotographerProfile]
        do {
            let result = try photographerProfileRepository.loadResult()
            photographerLibrary = result.photographers
            if result.recoveredFromBackup {
                warnings.append("The photographer library was damaged, so its most recent backup was restored.")
            }
        } catch {
            photographerLibrary = []
            warnings.append("Saved photographers could not be loaded: \(error.localizedDescription)")
        }

        var jobs: [SyncJob]
        let jobsRecoveredFromBackup: Bool
        do {
            let result = try jobRepository.loadResult()
            jobs = result.jobs
            jobsRecoveredFromBackup = result.recoveredFromBackup
            if result.recoveredFromBackup {
                warnings.append("The jobs file was damaged, so the most recent backup was restored. Review your jobs before starting them.")
            }
        } catch {
            jobs = []
            jobsRecoveredFromBackup = false
            warnings.append("Saved jobs could not be loaded: \(error.localizedDescription)")
        }

        if serverProfilesLoaded {
            let migration = ServerProfile.migratingEmbeddedEndpoints(
                in: jobs,
                existingProfiles: serverProfiles
            )
            if migration.migratedEndpointCount > 0 {
                do {
                    try saveServerProfileMigration(
                        previousJobs: jobs,
                        previousProfiles: serverProfiles,
                        migratedJobs: migration.jobs,
                        migratedProfiles: migration.profiles
                    )
                    jobs = migration.jobs
                    serverProfiles = migration.profiles
                } catch {
                    warnings.append(
                        "Existing remote connections could not be migrated to server profiles. "
                            + "They remain unchanged and migration will be retried next time: \(error.localizedDescription)"
                    )
                }
            }
        }

        for index in jobs.indices {
            do {
                jobs[index] = try jobs[index].resolvingServerProfiles(in: serverProfiles)
            } catch {
                warnings.append("“\(jobs[index].name)” could not resolve its saved server profile: \(error.localizedDescription)")
            }
        }

        let migratedPhotographers = Self.mergedPhotographerLibrary(
            photographerLibrary,
            with: jobs.flatMap { $0.metadataAutomation?.photographers ?? [] }
        )
        if migratedPhotographers != photographerLibrary {
            do {
                try photographerProfileRepository.save(migratedPhotographers)
                photographerLibrary = migratedPhotographers
            } catch {
                warnings.append("Photographers from existing jobs could not be added to the shared library: \(error.localizedDescription)")
            }
        }

        let metadataAuditEntries: [UUID: [MetadataAuditEntry]]
        do {
            let result = try metadataAuditRepository.loadResult()
            metadataAuditEntries = Dictionary(grouping: result.entries, by: \.jobID)
            if result.recoveredFromBackup {
                warnings.append("The metadata audit trail was damaged, so its most recent backup was restored.")
            }
        } catch {
            metadataAuditEntries = [:]
            warnings.append("The metadata audit trail could not be loaded: \(error.localizedDescription)")
        }

        let syncFailureEntries: [UUID: [SyncFailureRecord]]
        do {
            let result = try syncFailureRepository.loadResult()
            syncFailureEntries = Dictionary(grouping: result.entries, by: \.jobID)
            if result.recoveredFromBackup {
                warnings.append("The sync error log was damaged, so its most recent backup was restored.")
            }
        } catch {
            syncFailureEntries = [:]
            warnings.append("The sync error log could not be loaded: \(error.localizedDescription)")
        }

        return AppPersistenceLoadResult(
            state: AppPersistentState(
                jobs: jobs,
                metadataPresets: metadataPresets,
                photographerLibrary: photographerLibrary,
                serverProfiles: serverProfiles,
                metadataAuditEntries: metadataAuditEntries,
                syncFailureEntries: syncFailureEntries
            ),
            jobsRecoveredFromBackup: jobsRecoveredFromBackup,
            warnings: warnings
        )
    }

    func saveJobs(_ jobs: [SyncJob]) throws {
        try jobRepository.save(jobs)
    }

    func saveMetadataPresets(_ presets: [MetadataPreset]) throws {
        try metadataPresetRepository.save(presets)
    }

    func savePhotographers(_ photographers: [PhotographerProfile]) throws {
        try photographerProfileRepository.save(photographers)
    }

    private func saveServerProfileMigration(
        previousJobs: [SyncJob],
        previousProfiles: [ServerProfile],
        migratedJobs: [SyncJob],
        migratedProfiles: [ServerProfile]
    ) throws {
        do {
            try serverProfileRepository.save(migratedProfiles)
            try jobRepository.save(migratedJobs)
        } catch {
            let operationError = error
            if let rollbackError = attemptRollback([
                { try self.jobRepository.save(previousJobs) },
                { try self.serverProfileRepository.save(previousProfiles) }
            ]) {
                throw AppPersistenceTransactionError(operation: operationError, rollback: rollbackError)
            }
            throw operationError
        }
    }

    func saveJobsAndPhotographers(
        previousJobs: [SyncJob],
        previousPhotographers: [PhotographerProfile],
        updatedJobs: [SyncJob],
        updatedPhotographers: [PhotographerProfile]
    ) throws {
        do {
            try photographerProfileRepository.save(updatedPhotographers)
            try jobRepository.save(updatedJobs)
        } catch {
            let operationError = error
            if let rollbackError = attemptRollback([
                { try self.jobRepository.save(previousJobs) },
                { try self.photographerProfileRepository.save(previousPhotographers) }
            ]) {
                throw AppPersistenceTransactionError(operation: operationError, rollback: rollbackError)
            }
            throw operationError
        }
    }

    func saveConfiguration(
        previous: AppPersistentState,
        updated: AppPersistentState
    ) throws {
        do {
            try photographerProfileRepository.save(updated.photographerLibrary)
            try metadataPresetRepository.save(updated.metadataPresets)
            try jobRepository.save(updated.jobs)
        } catch {
            let operationError = error
            if let rollbackError = attemptRollback([
                { try self.jobRepository.save(previous.jobs) },
                { try self.metadataPresetRepository.save(previous.metadataPresets) },
                { try self.photographerProfileRepository.save(previous.photographerLibrary) }
            ]) {
                throw AppPersistenceTransactionError(operation: operationError, rollback: rollbackError)
            }
            throw operationError
        }
    }

    func appendMetadataAudit(_ report: MetadataRunReport) throws -> [MetadataAuditEntry] {
        try metadataAuditRepository.append(report)
    }

    func removeMetadataAudit(jobID: UUID) throws -> [MetadataAuditEntry] {
        try metadataAuditRepository.remove(jobID: jobID)
    }

    func appendSyncFailure(_ entry: SyncFailureRecord) throws -> [SyncFailureRecord] {
        try syncFailureRepository.append(entry)
    }

    func removeSyncFailures(jobID: UUID) throws -> [SyncFailureRecord] {
        try syncFailureRepository.remove(jobID: jobID)
    }

    func password(for endpoint: Endpoint) throws -> String? {
        guard endpoint.kind.isRemote else { return nil }
        let credentialID = endpoint.credentialID
        if loadedCredentialIDs.contains(credentialID) {
            return cachedPasswords[credentialID]
        }

        let password = try keychain.password(for: credentialID)
        loadedCredentialIDs.insert(credentialID)
        if let password { cachedPasswords[credentialID] = password }
        return password
    }

    func saveJob(
        previousJobs: [SyncJob],
        draftJob: SyncJob,
        leftPassword: String,
        rightPassword: String
    ) throws -> CredentialedJobSaveResult {
        let previousJob = previousJobs.first(where: { $0.id == draftJob.id })
        let leftUpdate = try prepareCredentialUpdate(
            endpoint: draftJob.left,
            previousEndpoint: previousJob?.left,
            password: leftPassword
        )
        let rightUpdate = try prepareCredentialUpdate(
            endpoint: draftJob.right,
            previousEndpoint: previousJob?.right,
            password: rightPassword
        )

        var stagedCredentialIDs: [String] = []
        do {
            for update in [leftUpdate, rightUpdate] {
                guard let stagedPassword = update.stagedPassword else { continue }
                try keychain.setPassword(stagedPassword, for: update.endpoint.credentialID)
                cachedPasswords[update.endpoint.credentialID] = stagedPassword
                loadedCredentialIDs.insert(update.endpoint.credentialID)
                stagedCredentialIDs.append(update.endpoint.credentialID)
            }
        } catch {
            throw rollbackStagedCredentials(stagedCredentialIDs, after: error)
        }

        var savedJob = draftJob
        savedJob.left = leftUpdate.endpoint
        savedJob.right = rightUpdate.endpoint
        var updatedJobs = previousJobs
        if let index = updatedJobs.firstIndex(where: { $0.id == savedJob.id }) {
            updatedJobs[index] = savedJob
        } else {
            updatedJobs.append(savedJob)
        }

        do {
            try jobRepository.save(updatedJobs)
        } catch {
            throw rollbackStagedCredentials(stagedCredentialIDs, after: error)
        }

        let previousCredentialIDs = credentialIDs(in: previousJob.map { [$0] } ?? [])
        let retainedCredentialIDs = credentialIDs(in: updatedJobs)
        let cleanupWarnings = removeCredentials(previousCredentialIDs.subtracting(retainedCredentialIDs))
        return CredentialedJobSaveResult(
            jobs: updatedJobs,
            savedJob: savedJob,
            cleanupWarnings: cleanupWarnings
        )
    }

    func saveServerProfile(
        previousJobs: [SyncJob],
        previousProfiles: [ServerProfile],
        draftProfile: ServerProfile,
        password suppliedPassword: String
    ) throws -> CredentialedServerProfileSaveResult {
        let previousProfile = previousProfiles.first(where: { $0.id == draftProfile.id })
        let savedPassword = try previousProfile.map { try password(forCredentialID: $0.credentialID) } ?? nil
        let requestedPassword = suppliedPassword.isEmpty ? nil : suppliedPassword

        var savedProfile = draftProfile
        let stagedPassword: String?
        if let previousProfile, savedPassword == requestedPassword {
            savedProfile.credentialID = previousProfile.credentialID
            stagedPassword = nil
        } else {
            savedProfile.credentialID = UUID().uuidString
            stagedPassword = requestedPassword
        }

        var stagedCredentialIDs: [String] = []
        if let stagedPassword {
            do {
                try keychain.setPassword(stagedPassword, for: savedProfile.credentialID)
                cachedPasswords[savedProfile.credentialID] = stagedPassword
                loadedCredentialIDs.insert(savedProfile.credentialID)
                stagedCredentialIDs.append(savedProfile.credentialID)
            } catch {
                throw rollbackStagedCredentials(stagedCredentialIDs, after: error)
            }
        }

        var updatedProfiles = previousProfiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == savedProfile.id }) {
            updatedProfiles[index] = savedProfile
        } else {
            updatedProfiles.append(savedProfile)
        }

        var updatedJobs = previousJobs
        for index in updatedJobs.indices {
            if updatedJobs[index].left.serverProfileID == savedProfile.id {
                updatedJobs[index].left = savedProfile.endpoint(remotePath: updatedJobs[index].left.remotePath)
            }
            if updatedJobs[index].right.serverProfileID == savedProfile.id {
                updatedJobs[index].right = savedProfile.endpoint(remotePath: updatedJobs[index].right.remotePath)
            }
        }

        do {
            try serverProfileRepository.save(updatedProfiles)
            try jobRepository.save(updatedJobs)
        } catch {
            let operationError = error
            let transactionError: Error
            if let rollbackError = attemptRollback([
                { try self.jobRepository.save(previousJobs) },
                { try self.serverProfileRepository.save(previousProfiles) }
            ]) {
                transactionError = AppPersistenceTransactionError(
                    operation: operationError,
                    rollback: rollbackError
                )
            } else {
                transactionError = operationError
            }
            throw rollbackStagedCredentials(stagedCredentialIDs, after: transactionError)
        }

        let previousCredentialIDs = credentialIDs(in: previousProfiles, jobs: previousJobs)
        let retainedCredentialIDs = credentialIDs(in: updatedProfiles, jobs: updatedJobs)
        let cleanupWarnings = removeCredentials(previousCredentialIDs.subtracting(retainedCredentialIDs))
        return CredentialedServerProfileSaveResult(
            jobs: updatedJobs,
            profiles: updatedProfiles,
            savedProfile: savedProfile,
            cleanupWarnings: cleanupWarnings
        )
    }

    func removeCredentials(for job: SyncJob, retainedJobs: [SyncJob]) -> [String] {
        removeCredentials(credentialIDs(in: [job]).subtracting(credentialIDs(in: retainedJobs)))
    }

    private func attemptRollback(_ operations: [() throws -> Void]) -> Error? {
        var failures: [Error] = []
        for operation in operations {
            do {
                try operation()
            } catch {
                failures.append(error)
            }
        }
        return failures.isEmpty ? nil : AppPersistenceRollbackError(failures: failures)
    }

    private struct CredentialUpdate {
        let endpoint: Endpoint
        let stagedPassword: String?
    }

    private func prepareCredentialUpdate(
        endpoint: Endpoint,
        previousEndpoint: Endpoint?,
        password suppliedPassword: String
    ) throws -> CredentialUpdate {
        guard endpoint.kind.isRemote else {
            return CredentialUpdate(endpoint: endpoint, stagedPassword: nil)
        }
        // A referenced profile owns its Keychain credential. Saving a job may
        // change only the endpoint's remote path, never the shared password.
        if endpoint.serverProfileID != nil {
            return CredentialUpdate(endpoint: endpoint, stagedPassword: nil)
        }

        if let previousEndpoint, previousEndpoint.kind.isRemote {
            let savedPassword = try password(forCredentialID: previousEndpoint.credentialID)
            let requestedPassword = suppliedPassword.isEmpty ? nil : suppliedPassword
            if savedPassword == requestedPassword {
                var unchangedEndpoint = endpoint
                unchangedEndpoint.credentialID = previousEndpoint.credentialID
                return CredentialUpdate(endpoint: unchangedEndpoint, stagedPassword: nil)
            }
        }

        var stagedEndpoint = endpoint
        stagedEndpoint.credentialID = UUID().uuidString
        return CredentialUpdate(
            endpoint: stagedEndpoint,
            stagedPassword: suppliedPassword.isEmpty ? nil : suppliedPassword
        )
    }

    private func password(forCredentialID credentialID: String) throws -> String? {
        if loadedCredentialIDs.contains(credentialID) {
            return cachedPasswords[credentialID]
        }
        let password = try keychain.password(for: credentialID)
        loadedCredentialIDs.insert(credentialID)
        if let password { cachedPasswords[credentialID] = password }
        return password
    }

    private func rollbackStagedCredentials(_ credentialIDs: [String], after operationError: Error) -> Error {
        var rollbackFailures: [Error] = []
        for credentialID in credentialIDs {
            do {
                try keychain.removePassword(for: credentialID)
            } catch {
                rollbackFailures.append(error)
            }
            cachedPasswords[credentialID] = nil
            loadedCredentialIDs.remove(credentialID)
        }
        guard !rollbackFailures.isEmpty else { return operationError }
        return AppPersistenceTransactionError(
            operation: operationError,
            rollback: AppPersistenceRollbackError(failures: rollbackFailures)
        )
    }

    private func credentialIDs(in jobs: [SyncJob]) -> Set<String> {
        Set(jobs.flatMap { job in
            [job.left, job.right]
                .filter { $0.kind.isRemote && $0.serverProfileID == nil }
                .map(\.credentialID)
        })
    }

    private func credentialIDs(in profiles: [ServerProfile], jobs: [SyncJob]) -> Set<String> {
        Set(profiles.map(\.credentialID)).union(credentialIDs(in: jobs))
    }

    private func removeCredentials(_ credentialIDs: Set<String>) -> [String] {
        var warnings: [String] = []
        for credentialID in credentialIDs {
            do {
                try keychain.removePassword(for: credentialID)
                cachedPasswords[credentialID] = nil
                loadedCredentialIDs.remove(credentialID)
            } catch {
                warnings.append(error.localizedDescription)
            }
        }
        return warnings
    }

    private static func mergedPhotographerLibrary(
        _ existing: [PhotographerProfile],
        with profiles: [PhotographerProfile]
    ) -> [PhotographerProfile] {
        var merged = existing
        for profile in profiles where !profile.photographerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.normalizedPrefixes.isEmpty {
            if let index = merged.firstIndex(where: { $0.id == profile.id }) {
                merged[index] = profile
            } else {
                merged.append(profile)
            }
        }
        return merged.sorted {
            $0.photographerName.localizedCaseInsensitiveCompare($1.photographerName) == .orderedAscending
        }
    }
}
