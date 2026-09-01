import AppKit
import Combine
import Foundation
import ServiceManagement

struct JobTransferTotals: Sendable {
    private var cumulativeFileCounts: [UUID: Int] = [:]
    private var latestSessionFileCounts: [UUID: Int] = [:]

    mutating func record(jobID: UUID, fileCount: Int) {
        latestSessionFileCounts[jobID] = fileCount
        guard fileCount > 0 else { return }
        cumulativeFileCounts[jobID, default: 0] += fileCount
    }

    func fileCount(jobID: UUID, latestSessionOnly: Bool) -> Int {
        let counts = latestSessionOnly ? latestSessionFileCounts : cumulativeFileCounts
        return counts[jobID, default: 0]
    }

    mutating func reset(jobID: UUID) {
        cumulativeFileCounts[jobID] = 0
        latestSessionFileCounts[jobID] = 0
    }

    mutating func remove(jobID: UUID) {
        cumulativeFileCounts[jobID] = nil
        latestSessionFileCounts[jobID] = nil
    }
}

enum MetadataReprocessPhase: Equatable, Sendable {
    case idle
    case running
    case succeeded(Date, MetadataReprocessResult)
    case failed(String)
}

struct SyncConcurrencyPolicy: Equatable, Sendable {
    static let appDefault = SyncConcurrencyPolicy(globalLimit: 2, perHostLimit: 1)

    let globalLimit: Int
    let perHostLimit: Int?

    init(globalLimit: Int, perHostLimit: Int?) {
        precondition(globalLimit > 0)
        precondition(perHostLimit == nil || perHostLimit! > 0)
        self.globalLimit = globalLimit
        self.perHostLimit = perHostLimit
    }
}

struct SyncRemoteHost: Hashable, Sendable {
    let host: String
    let port: Int

    init?(endpoint: Endpoint) {
        guard endpoint.kind.isRemote else { return nil }
        host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        port = endpoint.port
    }

    static func hosts(for job: SyncJob) -> Set<SyncRemoteHost> {
        Set([job.left, job.right, job.processedFolder].compactMap { endpoint in
            endpoint.flatMap(SyncRemoteHost.init(endpoint:))
        })
    }
}

struct SyncConcurrencySnapshot: Equatable, Sendable {
    let activeCount: Int
    let pendingCount: Int
}

actor SyncConcurrencyController {
    private struct PendingRequest {
        let id: UUID
        let hosts: Set<SyncRemoteHost>
        let continuation: CheckedContinuation<UUID, any Error>
    }

    private let policy: SyncConcurrencyPolicy
    private var activeLeases: [UUID: Set<SyncRemoteHost>] = [:]
    private var activeHostCounts: [SyncRemoteHost: Int] = [:]
    private var pendingRequests: [PendingRequest] = []

    init(policy: SyncConcurrencyPolicy = .appDefault) {
        self.policy = policy
    }

    func acquire(hosts: Set<SyncRemoteHost>) async throws -> UUID {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests.append(PendingRequest(
                    id: requestID,
                    hosts: hosts,
                    continuation: continuation
                ))
                admitAvailableRequests()
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(requestID) }
        }
    }

    func release(_ leaseID: UUID) {
        guard let hosts = activeLeases.removeValue(forKey: leaseID) else { return }
        for host in hosts {
            let remaining = activeHostCounts[host, default: 1] - 1
            activeHostCounts[host] = remaining > 0 ? remaining : nil
        }
        admitAvailableRequests()
    }

    func snapshot() -> SyncConcurrencySnapshot {
        SyncConcurrencySnapshot(
            activeCount: activeLeases.count,
            pendingCount: pendingRequests.count
        )
    }

    private func cancelPendingRequest(_ requestID: UUID) {
        guard let index = pendingRequests.firstIndex(where: { $0.id == requestID }) else { return }
        let request = pendingRequests.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
        admitAvailableRequests()
    }

    private func admitAvailableRequests() {
        while activeLeases.count < policy.globalLimit,
              let index = pendingRequests.firstIndex(where: { canAdmit($0.hosts) }) {
            let request = pendingRequests.remove(at: index)
            activeLeases[request.id] = request.hosts
            for host in request.hosts {
                activeHostCounts[host, default: 0] += 1
            }
            request.continuation.resume(returning: request.id)
        }
    }

    private func canAdmit(_ hosts: Set<SyncRemoteHost>) -> Bool {
        guard activeLeases.count < policy.globalLimit else { return false }
        guard let perHostLimit = policy.perHostLimit else { return true }
        return hosts.allSatisfy { activeHostCounts[$0, default: 0] < perHostLimit }
    }
}

struct PhotographerLibraryImportResult: Equatable, Sendable {
    let addedCount: Int
    let updatedCount: Int
    let unchangedCount: Int
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var jobs: [SyncJob]
    @Published private(set) var metadataPresets: [MetadataPreset]
    @Published private(set) var photographerLibrary: [PhotographerProfile]
    @Published private(set) var metadataAuditEntries: [UUID: [MetadataAuditEntry]] = [:]
    @Published private(set) var syncFailureEntries: [UUID: [SyncFailureRecord]] = [:]
    @Published private(set) var phases: [UUID: JobPhase] = [:]
    @Published private(set) var metadataReprocessPhases: [UUID: MetadataReprocessPhase] = [:]
    @Published private(set) var resettingJobs: Set<UUID> = []
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published var selectedJobID: UUID?
    @Published var alertMessage: String?

    private let persistenceCoordinator: AppPersistenceCoordinator
    private let configurationTransferCoordinator = ConfigurationTransferCoordinator()
    private let sourceSignatureRepository: SourceSignatureRepository
    private let jobResetService: JobResetService
    private let engine: SyncEngine
    private let syncConcurrencyController: SyncConcurrencyController
    private let scheduler: SyncScheduler
    private var metadataReprocessTasks: [UUID: Task<Void, Never>] = [:]
    private var resetTasks: [UUID: Task<Void, Never>] = [:]
    private var transferTotals = JobTransferTotals()

    init(
        repository: JobRepository = JobRepository(),
        metadataPresetRepository: MetadataPresetRepository = MetadataPresetRepository(),
        photographerProfileRepository: PhotographerProfileRepository = PhotographerProfileRepository(),
        metadataAuditRepository: MetadataAuditRepository = MetadataAuditRepository(),
        syncFailureRepository: SyncFailureRepository = SyncFailureRepository(),
        sourceSignatureRepository: SourceSignatureRepository = SourceSignatureRepository(),
        jobResetService: JobResetService = JobResetService(),
        keychain: KeychainStore = KeychainStore(),
        engine: SyncEngine? = nil,
        syncConcurrencyController: SyncConcurrencyController = SyncConcurrencyController()
    ) {
        let persistenceCoordinator = AppPersistenceCoordinator(
            jobRepository: repository,
            metadataPresetRepository: metadataPresetRepository,
            photographerProfileRepository: photographerProfileRepository,
            metadataAuditRepository: metadataAuditRepository,
            syncFailureRepository: syncFailureRepository,
            keychain: keychain
        )
        self.persistenceCoordinator = persistenceCoordinator
        self.sourceSignatureRepository = sourceSignatureRepository
        self.jobResetService = jobResetService
        self.engine = engine ?? SyncEngine(sourceSignatureRepository: sourceSignatureRepository)
        self.syncConcurrencyController = syncConcurrencyController
        scheduler = SyncScheduler()
        let persistenceLoad = persistenceCoordinator.load()
        jobs = persistenceLoad.state.jobs
        metadataPresets = persistenceLoad.state.metadataPresets
        photographerLibrary = persistenceLoad.state.photographerLibrary
        metadataAuditEntries = persistenceLoad.state.metadataAuditEntries
        syncFailureEntries = persistenceLoad.state.syncFailureEntries
        for warning in persistenceLoad.warnings {
            appendAlert(warning)
        }
        refreshLaunchAtLoginStatus()
        selectedJobID = jobs.last?.id
        for index in jobs.indices {
            let configuredToStart = jobs[index].startsOnAppLaunch
            let shouldStart = !persistenceLoad.jobsRecoveredFromBackup && configuredToStart
            jobs[index].startOnAppLaunch = configuredToStart
            jobs[index].isEnabled = shouldStart
            phases[jobs[index].id] = .stopped
        }
        scheduler.delegate = self
        scheduler.restart(with: jobs)
    }

    deinit {
        for task in metadataReprocessTasks.values { task.cancel() }
        for task in resetTasks.values { task.cancel() }
    }

    func addJob() -> SyncJob {
        var job = SyncJob(name: uniqueName())
        job.isEnabled = false
        job.startsOnAppLaunch = false
        let updatedJobs = jobs + [job]
        guard persistAndPublishJobs(updatedJobs) else { return job }
        selectedJobID = job.id
        phases[job.id] = .stopped
        return job
    }

    @discardableResult
    func saveJob(_ job: SyncJob, leftPassword: String, rightPassword: String) -> Bool {
        if let message = job.validationMessage {
            alertMessage = message
            return false
        }
        let previousJob = jobs.first(where: { $0.id == job.id })
        let wasEnabled = previousJob?.isEnabled ?? false
        do {
            try persistenceCoordinator.savePasswords(
                leftPassword: leftPassword,
                rightPassword: rightPassword,
                for: job
            )
            var updatedJobs = jobs
            if let index = updatedJobs.firstIndex(where: { $0.id == job.id }) { updatedJobs[index] = job }
            else { updatedJobs.append(job) }
            try persistenceCoordinator.saveJobs(updatedJobs)
            jobs = updatedJobs

            if let previousJob {
                persistenceCoordinator.removeCredentialsNoLongerUsed(
                    previousJob: previousJob,
                    updatedJob: job
                )
            }
            if job.isEnabled, !wasEnabled { transferTotals.reset(jobID: job.id) }
            scheduler.reschedule(job.id, job: job)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func updateFilter(jobID: UUID, preset: FilterPreset) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var updatedJobs = jobs
        updatedJobs[index].filter.preset = preset
        _ = persistAndPublishJobs(updatedJobs)
    }

    func updateInterval(jobID: UUID, seconds: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var updatedJobs = jobs
        updatedJobs[index].intervalSeconds = min(max(seconds, 2), 300)
        guard persistAndPublishJobs(updatedJobs) else { return }
        scheduler.reschedule(jobID, job: jobs.first(where: { $0.id == jobID }))
    }

    func updateFileAge(jobID: UUID, recentHours: Int?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var updatedJobs = jobs
        updatedJobs[index].filter.recentHours = recentHours
        if let recentHours,
           let cleanup = updatedJobs[index].targetCleanup,
           cleanup.olderThanHours <= recentHours {
            updatedJobs[index].targetCleanup?.olderThanHours = recentHours + 1
        }
        _ = persistAndPublishJobs(updatedJobs)
    }

    @discardableResult
    func saveMetadataAutomation(_ automation: MetadataAutomation, for jobID: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return false }
        var normalizedAutomation = automation
        normalizedAutomation.photographers = automation.photographers.map { profile in
            var normalized = profile.usingCreatorAsPhotographerName()
            normalized.filenamePrefix = normalized.formattedFilenamePrefixes
            return normalized
        }
        var updatedJob = jobs[index]
        updatedJob.metadataAutomation = normalizedAutomation
        if let message = updatedJob.validationMessage {
            alertMessage = message
            return false
        }

        var updatedJobs = jobs
        updatedJobs[index] = updatedJob
        let updatedPhotographerLibrary = mergedPhotographerLibrary(
            photographerLibrary,
            with: normalizedAutomation.photographers
        )
        if let duplicate = duplicateFilenameInitials(in: updatedPhotographerLibrary) {
            alertMessage = "The filename initials \(duplicate) are already used by another photographer."
            return false
        }
        do {
            try persistenceCoordinator.saveJobsAndPhotographers(
                previousJobs: jobs,
                previousPhotographers: photographerLibrary,
                updatedJobs: updatedJobs,
                updatedPhotographers: updatedPhotographerLibrary
            )
            photographerLibrary = updatedPhotographerLibrary
            jobs = updatedJobs
            return true
        } catch {
            alertMessage = "Metadata programming could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func photographerUsageCount(_ photographerID: UUID) -> Int {
        jobs.reduce(into: 0) { count, job in
            if job.metadataAutomation?.photographers.contains(where: { $0.id == photographerID }) == true {
                count += 1
            }
        }
    }

    func photographerLibraryExportData() -> Data? {
        do {
            return try PhotographerLibraryTransferCodec.encode(photographerLibrary)
        } catch {
            alertMessage = "The photographer list could not be exported: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importPhotographerLibrary(from data: Data) -> PhotographerLibraryImportResult? {
        do {
            let importedProfiles = try PhotographerLibraryTransferCodec.decode(data)
            return try importPhotographerProfiles(importedProfiles)
        } catch {
            alertMessage = "The photographers could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    func configurationExportData(
        scope: ConfigurationTransferScope,
        password: String?
    ) -> Data? {
        do {
            return try configurationTransferCoordinator.exportData(
                scope: scope,
                password: password,
                state: currentConfigurationTransferState
            )
        } catch {
            alertMessage = "The configuration could not be exported: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importConfiguration(from data: Data, password: String?) -> ConfigurationImportResult? {
        do {
            let prepared = try configurationTransferCoordinator.prepareImport(
                from: data,
                password: password,
                currentState: currentConfigurationTransferState
            )
            try persistenceCoordinator.saveConfiguration(
                previous: currentPersistentState,
                updated: AppPersistentState(
                    jobs: prepared.state.jobs,
                    metadataPresets: prepared.state.metadataPresets,
                    photographerLibrary: prepared.state.photographers,
                    metadataAuditEntries: metadataAuditEntries,
                    syncFailureEntries: syncFailureEntries
                )
            )
            jobs = prepared.state.jobs
            metadataPresets = prepared.state.metadataPresets
            photographerLibrary = prepared.state.photographers
            for importedID in prepared.importedJobIDs.values {
                phases[importedID] = .stopped
            }
            if let selectedJobID = prepared.selectedJobID {
                self.selectedJobID = selectedJobID
            }
            return prepared.result
        } catch {
            alertMessage = "The configuration could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func savePhotographerProfile(_ profile: PhotographerProfile) -> Bool {
        let normalizedProfile = profile.usingCreatorAsPhotographerName()
        let trimmedName = normalizedProfile.photographerName
        guard !trimmedName.isEmpty else {
            alertMessage = "Give the photographer a name."
            return false
        }
        guard !normalizedProfile.normalizedPrefixes.isEmpty else {
            alertMessage = "Give \(trimmedName) filename initials."
            return false
        }
        let otherPrefixes = Set(photographerLibrary
            .filter { $0.id != normalizedProfile.id }
            .flatMap(\.normalizedPrefixes))
        if let duplicate = normalizedProfile.normalizedPrefixes.first(where: otherPrefixes.contains) {
            alertMessage = "The filename initials \(duplicate) are already used by another photographer."
            return false
        }

        var updatedProfile = normalizedProfile
        updatedProfile.filenamePrefix = normalizedProfile.formattedFilenamePrefixes
        var updatedLibrary = photographerLibrary
        if let index = updatedLibrary.firstIndex(where: { $0.id == profile.id }) {
            updatedLibrary[index] = updatedProfile
        } else {
            updatedLibrary.append(updatedProfile)
        }
        updatedLibrary.sort {
            $0.photographerName.localizedCaseInsensitiveCompare($1.photographerName) == .orderedAscending
        }

        var updatedJobs = jobs
        for jobIndex in updatedJobs.indices {
            guard var automation = updatedJobs[jobIndex].metadataAutomation,
                  let photographerIndex = automation.photographers.firstIndex(where: { $0.id == profile.id }) else {
                continue
            }
            automation.photographers[photographerIndex] = updatedProfile
            if let message = automation.validationMessage {
                alertMessage = "\(updatedJobs[jobIndex].name): \(message)"
                return false
            }
            updatedJobs[jobIndex].metadataAutomation = automation
        }

        do {
            try persistenceCoordinator.saveJobsAndPhotographers(
                previousJobs: jobs,
                previousPhotographers: photographerLibrary,
                updatedJobs: updatedJobs,
                updatedPhotographers: updatedLibrary
            )
            photographerLibrary = updatedLibrary
            jobs = updatedJobs
            return true
        } catch {
            alertMessage = "The photographer could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func removePhotographerProfile(_ photographerID: UUID) -> Bool {
        let usageCount = photographerUsageCount(photographerID)
        guard usageCount == 0 else {
            let jobsDescription = usageCount == 1 ? "1 sync job" : "\(usageCount) sync jobs"
            alertMessage = "Remove this photographer from \(jobsDescription) before deleting the shared profile."
            return false
        }
        let updatedLibrary = photographerLibrary.filter { $0.id != photographerID }
        guard updatedLibrary.count != photographerLibrary.count else { return true }
        do {
            try persistenceCoordinator.savePhotographers(updatedLibrary)
            photographerLibrary = updatedLibrary
            return true
        } catch {
            alertMessage = "The photographer could not be removed: \(error.localizedDescription)"
            return false
        }
    }

    private func importPhotographerProfiles(
        _ importedProfiles: [PhotographerProfile]
    ) throws -> PhotographerLibraryImportResult {
        var seenIDs = Set<UUID>()
        var normalizedProfiles: [PhotographerProfile] = []
        normalizedProfiles.reserveCapacity(importedProfiles.count)

        for profile in importedProfiles {
            guard seenIDs.insert(profile.id).inserted else {
                throw AppError.invalidConfiguration("The imported list contains the same photographer more than once.")
            }
            var normalized = profile.usingCreatorAsPhotographerName()
            let trimmedName = normalized.photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw AppError.invalidConfiguration("An imported photographer does not have a name.")
            }
            guard !normalized.normalizedPrefixes.isEmpty else {
                throw AppError.invalidConfiguration("Give \(trimmedName) filename initials before importing this list.")
            }
            normalized.name = trimmedName
            normalized.creator = trimmedName
            normalized.filenamePrefix = normalized.formattedFilenamePrefixes
            normalizedProfiles.append(normalized)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: photographerLibrary.map { ($0.id, $0) })
        var mergedByID = existingByID
        for profile in normalizedProfiles {
            mergedByID[profile.id] = profile
        }
        let updatedLibrary = mergedByID.values.sorted {
            $0.photographerName.localizedCaseInsensitiveCompare($1.photographerName) == .orderedAscending
        }
        if let duplicate = duplicateFilenameInitials(in: updatedLibrary) {
            throw AppError.invalidConfiguration("The filename initials \(duplicate) are already used by another photographer.")
        }

        let importedByID = Dictionary(uniqueKeysWithValues: normalizedProfiles.map { ($0.id, $0) })
        var updatedJobs = jobs
        for jobIndex in updatedJobs.indices {
            guard var automation = updatedJobs[jobIndex].metadataAutomation else { continue }
            var changed = false
            for photographerIndex in automation.photographers.indices {
                let photographerID = automation.photographers[photographerIndex].id
                guard let imported = importedByID[photographerID] else { continue }
                automation.photographers[photographerIndex] = imported
                changed = true
            }
            guard changed else { continue }
            if let message = automation.validationMessage {
                throw AppError.invalidConfiguration("\(updatedJobs[jobIndex].name): \(message)")
            }
            updatedJobs[jobIndex].metadataAutomation = automation
        }

        try persistenceCoordinator.saveJobsAndPhotographers(
            previousJobs: jobs,
            previousPhotographers: photographerLibrary,
            updatedJobs: updatedJobs,
            updatedPhotographers: updatedLibrary
        )
        photographerLibrary = updatedLibrary
        jobs = updatedJobs

        let addedCount = normalizedProfiles.filter { existingByID[$0.id] == nil }.count
        let updatedCount = normalizedProfiles.filter {
            guard let existing = existingByID[$0.id] else { return false }
            return existing != $0
        }.count
        return PhotographerLibraryImportResult(
            addedCount: addedCount,
            updatedCount: updatedCount,
            unchangedCount: normalizedProfiles.count - addedCount - updatedCount
        )
    }

    private func mergedPhotographerLibrary(
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

    private func duplicateFilenameInitials(in profiles: [PhotographerProfile]) -> String? {
        var owners: [String: UUID] = [:]
        for profile in profiles {
            for prefix in profile.normalizedPrefixes {
                if let owner = owners[prefix], owner != profile.id {
                    return prefix
                }
                owners[prefix] = profile.id
            }
        }
        return nil
    }

    @discardableResult
    func saveMetadataPreset(_ preset: MetadataPreset) -> Bool {
        let normalized = preset.normalized()
        if let message = normalized.validationMessage {
            alertMessage = message
            return false
        }

        var updatedPresets = metadataPresets
        if let index = updatedPresets.firstIndex(where: { $0.id == normalized.id }) {
            updatedPresets[index] = normalized
        } else {
            updatedPresets.append(normalized)
        }
        updatedPresets.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        do {
            try persistenceCoordinator.saveMetadataPresets(updatedPresets)
            metadataPresets = updatedPresets
            return true
        } catch {
            alertMessage = "The metadata preset could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func removeMetadataPreset(_ presetID: UUID) -> Bool {
        let updatedPresets = metadataPresets.filter { $0.id != presetID }
        guard updatedPresets.count != metadataPresets.count else { return true }
        do {
            try persistenceCoordinator.saveMetadataPresets(updatedPresets)
            metadataPresets = updatedPresets
            return true
        } catch {
            alertMessage = "The metadata preset could not be removed: \(error.localizedDescription)"
            return false
        }
    }

    func setEnabled(_ enabled: Bool, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let wasEnabled = jobs[index].isEnabled
        var updatedJobs = jobs
        updatedJobs[index].isEnabled = enabled
        guard persistAndPublishJobs(updatedJobs) else { return }
        if enabled, !wasEnabled { transferTotals.reset(jobID: jobID) }
        scheduler.reschedule(jobID, job: jobs.first(where: { $0.id == jobID }))
    }

    func removeJob(_ jobID: UUID) {
        guard !isJobBusy(jobID) else {
            alertMessage = "Wait for the current operation to finish before deleting this job."
            return
        }
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let updatedJobs = jobs.filter { $0.id != jobID }
        guard persistAndPublishJobs(updatedJobs, errorPrefix: "The job could not be deleted") else { return }

        scheduler.cancel(jobID)
        persistenceCoordinator.removeCredentials(for: job)
        if selectedJobID == jobID { selectedJobID = jobs.last?.id }
        phases[jobID] = nil
        metadataReprocessPhases[jobID] = nil
        syncFailureEntries[jobID] = nil
        transferTotals.remove(jobID: jobID)
        do {
            let retained = try persistenceCoordinator.removeMetadataAudit(jobID: jobID)
            metadataAuditEntries = Dictionary(grouping: retained, by: \.jobID)
        } catch {
            appendAlert("The metadata audit trail for this job could not be removed: \(error.localizedDescription)")
        }
        do {
            let retained = try persistenceCoordinator.removeSyncFailures(jobID: jobID)
            syncFailureEntries = Dictionary(grouping: retained, by: \.jobID)
        } catch {
            appendAlert("The sync error log for this job could not be removed: \(error.localizedDescription)")
        }
    }

    func runNow(_ jobID: UUID) {
        guard !isJobBusy(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        scheduler.runNow(job)
    }

    func reprocessExistingLocalFiles(
        _ jobID: UUID,
        scope: MetadataReprocessScope = .all
    ) {
        guard !isJobBusy(jobID) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performMetadataReprocess(jobID, scope: scope)
            self.metadataReprocessTasks[jobID] = nil
        }
        metadataReprocessTasks[jobID] = task
    }

    func isJobBusy(_ jobID: UUID) -> Bool {
        scheduler.isBusy(jobID)
            || resettingJobs.contains(jobID)
            || metadataReprocessTasks[jobID] != nil
            || resetTasks[jobID] != nil
    }

    func resetJob(_ jobID: UUID) {
        guard !isJobBusy(jobID),
              let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]
        if let message = JobResetService.validationMessage(for: job) {
            alertMessage = message
            return
        }

        var updatedJobs = jobs
        updatedJobs[index].isEnabled = false
        updatedJobs[index].startsOnAppLaunch = false
        guard persistAndPublishJobs(updatedJobs, errorPrefix: "The job could not be disabled for reset") else {
            return
        }

        scheduler.cancel(jobID)
        phases[jobID] = .stopped
        resettingJobs.insert(jobID)

        let task = Task { [weak self] in
            guard let self else { return }
            defer { resettingJobs.remove(jobID) }
            do {
                let result = try await jobResetService.resetDownloads(for: job)
                try await sourceSignatureRepository.removeSignatures(jobID: jobID)
                let retainedAuditEntries = try persistenceCoordinator.removeMetadataAudit(jobID: jobID)
                let retainedFailures = try persistenceCoordinator.removeSyncFailures(jobID: jobID)

                metadataAuditEntries = Dictionary(grouping: retainedAuditEntries, by: \.jobID)
                syncFailureEntries = Dictionary(grouping: retainedFailures, by: \.jobID)
                metadataReprocessPhases[jobID] = nil
                transferTotals.reset(jobID: jobID)
                let fileDescription = result.deletedFiles == 1
                    ? "1 downloaded file"
                    : "\(result.deletedFiles) downloaded files"
                alertMessage = "“\(job.name)” was reset. Deleted \(fileDescription) from \(result.downloadFolderPath) and cleared its download history. The source and processed files were not changed."
            } catch {
                appendAlert("“\(job.name)” could not be fully reset: \(error.localizedDescription)")
            }
            resetTasks[jobID] = nil
        }
        resetTasks[jobID] = task
    }

    func openLocalFolder(_ endpoint: Endpoint) {
        guard endpoint.kind == .local else { return }
        do {
            let access = try BookmarkAccess(endpoint: endpoint)
            guard NSWorkspace.shared.open(access.url) else {
                throw AppError.folderPermissionLost("Finder could not open the folder.")
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var launchAtLoginRequiresApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            alertMessage = "Launch at Login could not be \(enabled ? "enabled" : "disabled"): \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func startAll() {
        var updatedJobs = jobs
        let newlyEnabledJobIDs = updatedJobs.compactMap { $0.isEnabled ? nil : $0.id }
        for index in updatedJobs.indices {
            updatedJobs[index].isEnabled = true
        }
        guard persistAndPublishJobs(updatedJobs) else { return }
        for jobID in newlyEnabledJobIDs { transferTotals.reset(jobID: jobID) }
        scheduler.restart(with: jobs)
    }

    func stopAll() {
        var updatedJobs = jobs
        for index in updatedJobs.indices { updatedJobs[index].isEnabled = false }
        guard persistAndPublishJobs(updatedJobs) else { return }
        scheduler.restart(with: jobs)
    }

    func password(for endpoint: Endpoint) -> String {
        (try? persistenceCoordinator.password(for: endpoint)) ?? ""
    }

    var activeCount: Int { jobs.filter(\.isEnabled).count }
    var isSyncing: Bool { phases.values.contains(.syncing) }

    func transferredFileCount(for jobID: UUID? = nil) -> Int {
        if let jobID {
            guard let job = jobs.first(where: { $0.id == jobID }) else { return 0 }
            return transferTotals.fileCount(
                jobID: jobID,
                latestSessionOnly: job.showsLatestSessionTransferCountOnly
            )
        }

        return jobs.reduce(into: 0) { count, job in
            count += transferTotals.fileCount(
                jobID: job.id,
                latestSessionOnly: job.showsLatestSessionTransferCountOnly
            )
        }
    }

    func metadataAuditTrail(for jobID: UUID) -> [MetadataAuditEntry] {
        metadataAuditEntries[jobID, default: []]
    }

    func syncFailureHistory(for jobID: UUID) -> [SyncFailureRecord] {
        syncFailureEntries[jobID, default: []].sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    func clearSyncFailureHistory(for jobID: UUID) {
        do {
            let retained = try persistenceCoordinator.removeSyncFailures(jobID: jobID)
            syncFailureEntries = Dictionary(grouping: retained, by: \.jobID)
        } catch {
            alertMessage = "The sync error log could not be cleared: \(error.localizedDescription)"
        }
    }

    /// Persists a completed run's per-file metadata decisions. Engine callers
    /// should invoke this independently from transfer-total accounting.
    func recordMetadataAudit(_ report: MetadataRunReport, jobID: UUID) {
        let scopedReport = MetadataRunReport(entries: report.entries.filter { $0.jobID == jobID })
        guard scopedReport.hasActivity else { return }
        do {
            let retained = try persistenceCoordinator.appendMetadataAudit(scopedReport)
            metadataAuditEntries = Dictionary(grouping: retained, by: \.jobID)
        } catch {
            appendAlert("The metadata audit trail could not be saved: \(error.localizedDescription)")
        }
    }

    private func performSync(_ jobID: UUID) async -> SyncAttempt {
        guard !scheduler.isRunning(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return .skipped }
        let leaseID: UUID
        do {
            leaseID = try await syncConcurrencyController.acquire(
                hosts: SyncRemoteHost.hosts(for: job)
            )
        } catch is CancellationError {
            phases[jobID] = .stopped
            return .cancelled
        } catch {
            let message = error.localizedDescription
            recordSyncFailure(message, jobID: jobID)
            phases[jobID] = .failed(message, retryAt: nil)
            return .failed(message)
        }
        if Task.isCancelled {
            await syncConcurrencyController.release(leaseID)
            phases[jobID] = .stopped
            return .cancelled
        }
        guard scheduler.beginRunning(jobID) else {
            await syncConcurrencyController.release(leaseID)
            return .skipped
        }

        phases[jobID] = .syncing
        let attempt: SyncAttempt
        do {
            let leftPassword = try persistenceCoordinator.password(for: job.left)
            let rightPassword = try persistenceCoordinator.password(for: job.right)
            let result = try await engine.run(job: job, leftPassword: leftPassword, rightPassword: rightPassword)
            let completedAt = Date()
            transferTotals.record(jobID: jobID, fileCount: result.transferred)
            recordMetadataAudit(result.metadataReport, jobID: jobID)
            phases[jobID] = .succeeded(
                completedAt,
                transferred: result.transferred,
                deleted: result.deleted,
                processed: result.processed,
                conflicts: result.conflicts,
                metadataReport: result.metadataReport,
                nextRun: nil
            )
            attempt = .succeeded
        } catch is CancellationError {
            phases[jobID] = .stopped
            attempt = .cancelled
        } catch let failure as SyncRunFailure {
            let partialResult = failure.partialResult
            transferTotals.record(jobID: jobID, fileCount: partialResult.transferred)
            recordMetadataAudit(partialResult.metadataReport, jobID: jobID)
            let message: String
            if let summary = partialResult.summary {
                message = "Sync stopped after \(summary). \(failure.failureDescription)"
            } else {
                message = failure.failureDescription
            }
            recordSyncFailure(message, jobID: jobID)
            phases[jobID] = .failed(message, retryAt: nil)
            attempt = .failed(message)
        } catch {
            let message = error.localizedDescription
            recordSyncFailure(message, jobID: jobID)
            phases[jobID] = .failed(message, retryAt: nil)
            attempt = .failed(message)
        }
        scheduler.endRunning(jobID)
        await syncConcurrencyController.release(leaseID)
        return attempt
    }

    private func performMetadataReprocess(
        _ jobID: UUID,
        scope: MetadataReprocessScope
    ) async {
        guard !scheduler.isRunning(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        let leaseID: UUID
        do {
            leaseID = try await syncConcurrencyController.acquire(
                hosts: SyncRemoteHost.hosts(for: job)
            )
        } catch is CancellationError {
            metadataReprocessPhases[jobID] = .idle
            return
        } catch {
            let message = error.localizedDescription
            metadataReprocessPhases[jobID] = .failed(message)
            alertMessage = message
            return
        }
        if Task.isCancelled {
            await syncConcurrencyController.release(leaseID)
            metadataReprocessPhases[jobID] = .idle
            return
        }
        guard scheduler.beginRunning(jobID) else {
            await syncConcurrencyController.release(leaseID)
            return
        }

        metadataReprocessPhases[jobID] = .running

        do {
            let leftPassword = try persistenceCoordinator.password(for: job.left)
            let rightPassword = try persistenceCoordinator.password(for: job.right)
            let result = try await engine.reprocessExistingLocalFiles(
                job: job,
                scope: scope,
                leftPassword: leftPassword,
                rightPassword: rightPassword
            )
            recordMetadataAudit(result.metadataReport, jobID: jobID)
            metadataReprocessPhases[jobID] = .succeeded(Date(), result)
        } catch is CancellationError {
            metadataReprocessPhases[jobID] = .idle
        } catch {
            let message = error.localizedDescription
            metadataReprocessPhases[jobID] = .failed(message)
            alertMessage = message
        }
        scheduler.endRunning(jobID)
        await syncConcurrencyController.release(leaseID)
    }

    private var currentPersistentState: AppPersistentState {
        AppPersistentState(
            jobs: jobs,
            metadataPresets: metadataPresets,
            photographerLibrary: photographerLibrary,
            metadataAuditEntries: metadataAuditEntries,
            syncFailureEntries: syncFailureEntries
        )
    }

    private var currentConfigurationTransferState: ConfigurationTransferState {
        ConfigurationTransferState(
            jobs: jobs,
            metadataPresets: metadataPresets,
            photographers: photographerLibrary
        )
    }

    @discardableResult
    private func persistAndPublishJobs(
        _ updatedJobs: [SyncJob],
        errorPrefix: String = "Changes could not be saved"
    ) -> Bool {
        do {
            try persistenceCoordinator.saveJobs(updatedJobs)
            jobs = updatedJobs
            return true
        } catch {
            alertMessage = "\(errorPrefix): \(error.localizedDescription)"
            return false
        }
    }

    private func appendAlert(_ message: String) {
        if let alertMessage, !alertMessage.isEmpty {
            self.alertMessage = alertMessage + "\n\n" + message
        } else {
            alertMessage = message
        }
    }

    private func recordSyncFailure(_ message: String, jobID: UUID) {
        let entry = SyncFailureRecord(jobID: jobID, message: message)
        syncFailureEntries[jobID, default: []].append(entry)
        do {
            let retained = try persistenceCoordinator.appendSyncFailure(entry)
            syncFailureEntries = Dictionary(grouping: retained, by: \.jobID)
        } catch {
            appendAlert("The sync error could not be added to the error log: \(error.localizedDescription)")
        }
    }

    private func uniqueName() -> String {
        let base = "Photo sync"
        var candidate = base
        var suffix = 2
        let names = Set(jobs.map(\.name))
        while names.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}

extension AppStore: SyncSchedulerDelegate {
    func syncSchedulerJob(_ jobID: UUID) -> SyncJob? {
        jobs.first(where: { $0.id == jobID })
    }

    func syncSchedulerPerformSync(_ jobID: UUID) async -> SyncAttempt {
        await performSync(jobID)
    }

    func syncSchedulerDidStop(_ jobID: UUID) {
        phases[jobID] = .stopped
    }

    func syncScheduler(
        _ jobID: UUID,
        scheduledNextRunAt date: Date,
        after attempt: SyncAttempt
    ) {
        switch attempt {
        case .succeeded:
            if case .succeeded(
                let completedAt,
                let transferred,
                let deleted,
                let processed,
                let conflicts,
                let metadataReport,
                _
            ) = phases[jobID] {
                phases[jobID] = .succeeded(
                    completedAt,
                    transferred: transferred,
                    deleted: deleted,
                    processed: processed,
                    conflicts: conflicts,
                    metadataReport: metadataReport,
                    nextRun: date
                )
            }
        case .failed(let message):
            phases[jobID] = .failed(message, retryAt: date)
        case .cancelled, .skipped:
            break
        }
    }
}
