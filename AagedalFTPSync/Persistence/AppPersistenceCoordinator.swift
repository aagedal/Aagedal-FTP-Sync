import Foundation

struct AppPersistentState: Sendable {
    let jobs: [SyncJob]
    let metadataPresets: [MetadataPreset]
    let photographerLibrary: [PhotographerProfile]
    let metadataAuditEntries: [UUID: [MetadataAuditEntry]]
    let syncFailureEntries: [UUID: [SyncFailureRecord]]
}

struct AppPersistenceLoadResult: Sendable {
    let state: AppPersistentState
    let jobsRecoveredFromBackup: Bool
    let warnings: [String]
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
    private let metadataAuditRepository: MetadataAuditRepository
    private let syncFailureRepository: SyncFailureRepository
    private let keychain: KeychainStore

    private var cachedPasswords: [String: String] = [:]
    private var loadedCredentialIDs = Set<String>()

    init(
        jobRepository: JobRepository,
        metadataPresetRepository: MetadataPresetRepository,
        photographerProfileRepository: PhotographerProfileRepository,
        metadataAuditRepository: MetadataAuditRepository,
        syncFailureRepository: SyncFailureRepository,
        keychain: KeychainStore
    ) {
        self.jobRepository = jobRepository
        self.metadataPresetRepository = metadataPresetRepository
        self.photographerProfileRepository = photographerProfileRepository
        self.metadataAuditRepository = metadataAuditRepository
        self.syncFailureRepository = syncFailureRepository
        self.keychain = keychain
    }

    func load() -> AppPersistenceLoadResult {
        var warnings: [String] = []

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

        let jobs: [SyncJob]
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

    func savePasswords(leftPassword: String, rightPassword: String, for job: SyncJob) throws {
        if job.left.kind.isRemote, !leftPassword.isEmpty {
            try savePasswordIfNeeded(leftPassword, for: job.left.credentialID)
        }
        if job.right.kind.isRemote, !rightPassword.isEmpty {
            try savePasswordIfNeeded(rightPassword, for: job.right.credentialID)
        }
    }

    func removeCredentialsNoLongerUsed(previousJob: SyncJob, updatedJob: SyncJob) {
        let previousIDs = Set([previousJob.left, previousJob.right]
            .filter(\.kind.isRemote)
            .map(\.credentialID))
        let updatedIDs = Set([updatedJob.left, updatedJob.right]
            .filter(\.kind.isRemote)
            .map(\.credentialID))
        for credentialID in previousIDs.subtracting(updatedIDs) {
            removeCredential(credentialID)
        }
    }

    func removeCredentials(for job: SyncJob) {
        for credentialID in Set([job.left.credentialID, job.right.credentialID]) {
            removeCredential(credentialID)
        }
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

    private func savePasswordIfNeeded(_ password: String, for credentialID: String) throws {
        if loadedCredentialIDs.contains(credentialID), cachedPasswords[credentialID] == password {
            return
        }
        try keychain.setPassword(password, for: credentialID)
        cachedPasswords[credentialID] = password
        loadedCredentialIDs.insert(credentialID)
    }

    private func removeCredential(_ credentialID: String) {
        keychain.removePassword(for: credentialID)
        cachedPasswords[credentialID] = nil
        loadedCredentialIDs.remove(credentialID)
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
