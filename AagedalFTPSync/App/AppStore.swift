import AppKit
import Combine
import Foundation
import ServiceManagement

enum MetadataReprocessPhase: Equatable, Sendable {
    case idle
    case running
    case succeeded(Date, MetadataReprocessResult)
    case failed(String)
}

struct MetadataProgrammingClipRequest: Equatable, Sendable {
    let id = UUID()
    let jobID: UUID
    let clipID: UUID
    let date: Date
}

struct MetadataClipPositionUpdate: Equatable, Sendable {
    let id = UUID()
    let jobID: UUID
    let clipID: UUID
    let position: ScheduledGPSPosition
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var jobs: [SyncJob]
    @Published private(set) var metadataPresets: [MetadataPreset]
    @Published private(set) var photographerLibrary: [PhotographerProfile]
    @Published private(set) var serverProfiles: [ServerProfile]
    @Published private(set) var metadataAuditEntries: [UUID: [MetadataAuditEntry]] = [:]
    @Published private(set) var syncFailureEntries: [UUID: [SyncFailureRecord]] = [:]
    @Published private(set) var phases: [UUID: JobPhase] = [:]
    @Published private(set) var metadataReprocessPhases: [UUID: MetadataReprocessPhase] = [:]
    @Published private(set) var resettingJobs: Set<UUID> = []
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published var selectedJobID: UUID?
    @Published var metadataMapRequestedDate: Date?
    @Published private(set) var metadataProgrammingClipRequest: MetadataProgrammingClipRequest?
    @Published private(set) var metadataClipPositionUpdate: MetadataClipPositionUpdate?
    @Published var alertMessage: String?
    @Published private(set) var newJobDraftRequestID: UUID?

    private let persistenceCoordinator: AppPersistenceCoordinator
    private let configurationTransferCoordinator = ConfigurationTransferCoordinator()
    private let metadataLibraryCoordinator: MetadataLibraryCoordinator
    private let launchAtLoginCoordinator: any LaunchAtLoginCoordinating
    private let sourceSignatureRepository: SourceSignatureRepository
    private let jobResetService: JobResetService
    private let engine: SyncEngine
    private let syncConcurrencyController: SyncConcurrencyController
    private let failureNotificationCoordinator: SyncFailureNotificationCoordinator
    private let scheduler: SyncScheduler
    private let jobDraftTemplate: SyncJob?
    private var metadataReprocessTasks: [UUID: Task<Void, Never>] = [:]
    private var resetTasks: [UUID: Task<Void, Never>] = [:]
    private var sourceSignatureMaintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private var transferTotals = JobTransferTotals()

    init(
        repository: JobRepository = JobRepository(),
        metadataPresetRepository: MetadataPresetRepository = MetadataPresetRepository(),
        photographerProfileRepository: PhotographerProfileRepository = PhotographerProfileRepository(),
        serverProfileRepository: ServerProfileRepository = ServerProfileRepository(),
        metadataAuditRepository: MetadataAuditRepository = MetadataAuditRepository(),
        syncFailureRepository: SyncFailureRepository = SyncFailureRepository(),
        sourceSignatureRepository: SourceSignatureRepository = SourceSignatureRepository(),
        jobResetService: JobResetService = JobResetService(),
        keychain: KeychainStore = KeychainStore(),
        engine: SyncEngine? = nil,
        syncConcurrencyController: SyncConcurrencyController = SyncConcurrencyController(),
        failureNotificationCoordinator: SyncFailureNotificationCoordinator = SyncFailureNotificationCoordinator(),
        launchAtLoginCoordinator: any LaunchAtLoginCoordinating = LaunchAtLoginCoordinator(),
        jobDraftTemplate: SyncJob? = nil
    ) {
        let persistenceCoordinator = AppPersistenceCoordinator(
            jobRepository: repository,
            metadataPresetRepository: metadataPresetRepository,
            photographerProfileRepository: photographerProfileRepository,
            serverProfileRepository: serverProfileRepository,
            metadataAuditRepository: metadataAuditRepository,
            syncFailureRepository: syncFailureRepository,
            keychain: keychain
        )
        self.persistenceCoordinator = persistenceCoordinator
        metadataLibraryCoordinator = MetadataLibraryCoordinator(
            persistenceCoordinator: persistenceCoordinator
        )
        self.sourceSignatureRepository = sourceSignatureRepository
        self.jobResetService = jobResetService
        self.engine = engine ?? SyncEngine(sourceSignatureRepository: sourceSignatureRepository)
        self.syncConcurrencyController = syncConcurrencyController
        self.failureNotificationCoordinator = failureNotificationCoordinator
        self.launchAtLoginCoordinator = launchAtLoginCoordinator
        self.jobDraftTemplate = jobDraftTemplate
        scheduler = SyncScheduler()
        let persistenceLoad = persistenceCoordinator.load()
        jobs = persistenceLoad.state.jobs
        metadataPresets = persistenceLoad.state.metadataPresets
        photographerLibrary = persistenceLoad.state.photographerLibrary
        serverProfiles = persistenceLoad.state.serverProfiles
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
        for task in sourceSignatureMaintenanceTasks.values { task.cancel() }
    }

    func addJob() -> SyncJob {
        let job = makeJobDraft()
        let updatedJobs = jobs + [job]
        guard persistAndPublishJobs(updatedJobs) else { return job }
        selectedJobID = job.id
        phases[job.id] = .stopped
        return job
    }

    func makeJobDraft() -> SyncJob {
        var job = jobDraftTemplate ?? SyncJob()
        job.id = UUID()
        job.name = uniqueName()
        job.isEnabled = false
        job.startsOnAppLaunch = false
        return job
    }

    func requestNewJobDraft() {
        newJobDraftRequestID = UUID()
    }

    @discardableResult
    func saveJob(_ job: SyncJob, leftPassword: String, rightPassword: String) -> Bool {
        let resolvedJob: SyncJob
        do {
            resolvedJob = try job.resolvingServerProfiles(in: serverProfiles)
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
        if let message = resolvedJob.validationMessage {
            alertMessage = message
            return false
        }
        let previousJob = jobs.first(where: { $0.id == job.id })
        let wasEnabled = previousJob?.isEnabled ?? false
        do {
            let result = try persistenceCoordinator.saveJob(
                previousJobs: jobs,
                draftJob: resolvedJob,
                leftPassword: leftPassword,
                rightPassword: rightPassword
            )
            jobs = result.jobs
            scheduleSourceSignatureMaintenance(jobID: result.savedJob.id)
            for warning in result.cleanupWarnings {
                appendAlert("An obsolete saved password could not be removed: \(warning)")
            }
            if result.savedJob.isEnabled, !wasEnabled { transferTotals.reset(jobID: result.savedJob.id) }
            scheduler.reschedule(result.savedJob.id, job: result.savedJob)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveServerProfile(_ profile: ServerProfile, password: String) -> Bool {
        if let message = profile.validationMessage {
            alertMessage = message
            return false
        }
        let affectedJobIDs = Set(jobs.compactMap { job in
            job.left.serverProfileID == profile.id || job.right.serverProfileID == profile.id
                ? job.id
                : nil
        })
        do {
            let result = try persistenceCoordinator.saveServerProfile(
                previousJobs: jobs,
                previousProfiles: serverProfiles,
                draftProfile: profile,
                password: password
            )
            jobs = result.jobs
            serverProfiles = result.profiles
            for warning in result.cleanupWarnings {
                appendAlert("An obsolete saved password could not be removed: \(warning)")
            }
            for jobID in affectedJobIDs {
                scheduleSourceSignatureMaintenance(jobID: jobID)
                scheduler.reschedule(jobID, job: jobs.first(where: { $0.id == jobID }))
            }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func serverProfileUsages(for profileID: UUID) -> [ServerProfileUsage] {
        jobs.compactMap { $0.serverProfileUsage(for: profileID) }.sorted {
            let comparison = $0.jobName.localizedCaseInsensitiveCompare($1.jobName)
            return comparison == .orderedSame
                ? $0.jobID.uuidString < $1.jobID.uuidString
                : comparison == .orderedAscending
        }
    }

    @discardableResult
    func duplicateServerProfile(_ profileID: UUID) -> ServerProfile? {
        do {
            let result = try persistenceCoordinator.duplicateServerProfile(
                profileID: profileID,
                jobs: jobs,
                previousProfiles: serverProfiles
            )
            jobs = result.jobs
            serverProfiles = result.profiles
            for warning in result.cleanupWarnings {
                appendAlert("An obsolete saved password could not be removed: \(warning)")
            }
            return result.savedProfile
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func removeServerProfile(_ profileID: UUID) -> Bool {
        do {
            let result = try persistenceCoordinator.removeServerProfile(
                profileID: profileID,
                jobs: jobs,
                previousProfiles: serverProfiles
            )
            serverProfiles = result.profiles
            for warning in result.cleanupWarnings {
                appendAlert("The removed server password could not be deleted: \(warning)")
            }
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
        do {
            guard let updated = try metadataLibraryCoordinator.saveAutomation(
                automation,
                for: jobID,
                state: metadataLibraryState
            ) else { return false }
            jobs = updated.jobs
            photographerLibrary = updated.photographers
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateMetadataClipPosition(
        _ position: ScheduledGPSPosition,
        clipID: UUID,
        jobID: UUID
    ) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }),
              var automation = job.metadataAutomation,
              let clipIndex = automation.clips.firstIndex(where: { $0.id == clipID }) else {
            return false
        }
        automation.clips[clipIndex].gpsPosition = position
        guard saveMetadataAutomation(automation, for: jobID) else { return false }
        metadataClipPositionUpdate = MetadataClipPositionUpdate(
            jobID: jobID,
            clipID: clipID,
            position: position
        )
        return true
    }

    func requestMetadataProgramming(for clipID: UUID, jobID: UUID, at date: Date) {
        selectedJobID = jobID
        metadataProgrammingClipRequest = MetadataProgrammingClipRequest(
            jobID: jobID,
            clipID: clipID,
            date: date
        )
    }

    func consumeMetadataProgrammingClipRequest(_ requestID: UUID) {
        guard metadataProgrammingClipRequest?.id == requestID else { return }
        metadataProgrammingClipRequest = nil
    }

    func photographerUsageCount(_ photographerID: UUID) -> Int {
        metadataLibraryCoordinator.usageCount(for: photographerID, in: jobs)
    }

    func photographerLibraryExportData() -> Data? {
        do {
            return try metadataLibraryCoordinator.exportData(for: photographerLibrary)
        } catch {
            alertMessage = "The photographer list could not be exported: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importPhotographerLibrary(from data: Data) -> PhotographerLibraryImportResult? {
        do {
            let importResult = try metadataLibraryCoordinator.importLibrary(
                from: data,
                state: metadataLibraryState
            )
            jobs = importResult.state.jobs
            photographerLibrary = importResult.state.photographers
            return importResult.result
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

    func metadataProgrammingExportData(
        for job: SyncJob,
        automation: MetadataAutomation,
        on days: Set<Date>,
        calendar: Calendar,
        password: String?
    ) -> Data? {
        let restrictedAutomation = automation.restricted(to: days, calendar: calendar)
        guard !restrictedAutomation.clips.isEmpty else {
            alertMessage = "The selected days do not contain any metadata programming to export."
            return nil
        }

        var restrictedJob = job
        restrictedJob.metadataAutomation = restrictedAutomation
        do {
            return try configurationTransferCoordinator.exportData(
                scope: .metadata,
                password: password,
                state: ConfigurationTransferState(
                    jobs: [restrictedJob],
                    metadataPresets: [],
                    photographers: restrictedAutomation.photographers
                )
            )
        } catch {
            alertMessage = "The metadata programming could not be exported: \(error.localizedDescription)"
            return nil
        }
    }

    func supportBundleData(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> Data? {
        do {
            return try SupportBundleCodec.encode(
                jobs: jobs,
                metadataPresetCount: metadataPresets.count,
                photographerCount: photographerLibrary.count,
                failures: syncFailureEntries,
                applicationVersion: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                operatingSystem: processInfo.operatingSystemVersionString
            )
        } catch {
            alertMessage = "The support bundle could not be created: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importConfiguration(
        from data: Data,
        password: String?,
        expectedScope: ConfigurationTransferScope? = nil,
        metadataTargetJobID: UUID? = nil
    ) -> ConfigurationImportResult? {
        do {
            let prepared = try configurationTransferCoordinator.prepareImport(
                from: data,
                password: password,
                currentState: currentConfigurationTransferState,
                expectedScope: expectedScope,
                metadataTargetJobID: metadataTargetJobID
            )
            try persistenceCoordinator.saveConfiguration(
                previous: currentPersistentState,
                updated: AppPersistentState(
                    jobs: prepared.state.jobs,
                    metadataPresets: prepared.state.metadataPresets,
                    photographerLibrary: prepared.state.photographers,
                    serverProfiles: prepared.state.serverProfiles,
                    metadataAuditEntries: metadataAuditEntries,
                    syncFailureEntries: syncFailureEntries
                )
            )
            serverProfiles = prepared.state.serverProfiles
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
        do {
            let updated = try metadataLibraryCoordinator.saveProfile(
                profile,
                state: metadataLibraryState
            )
            jobs = updated.jobs
            photographerLibrary = updated.photographers
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func removePhotographerProfile(_ photographerID: UUID) -> Bool {
        do {
            let updated = try metadataLibraryCoordinator.removeProfile(
                photographerID,
                state: metadataLibraryState
            )
            jobs = updated.jobs
            photographerLibrary = updated.photographers
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
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
        scheduleSourceSignatureMaintenance(jobID: jobID)
        for warning in persistenceCoordinator.removeCredentials(for: job, retainedJobs: updatedJobs) {
            appendAlert("A saved password for the deleted job could not be removed: \(warning)")
        }
        if selectedJobID == jobID { selectedJobID = jobs.last?.id }
        phases[jobID] = nil
        metadataReprocessPhases[jobID] = nil
        failureNotificationCoordinator.removeJob(jobID)
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
        failureNotificationCoordinator.recordSuccess(jobID: jobID)
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

    func revealDownloadFolder(for job: SyncJob) {
        guard let destination = job.destinationEndpoint, destination.kind == .local else {
            alertMessage = "This job does not have a local download folder."
            return
        }

        do {
            let access = try BookmarkAccess(endpoint: destination)
            let downloadURL = if job.usesManagedFolderStructure {
                try ManagedOutputFolder.syncedFiles.url(
                    inside: access.url,
                    createIfNeeded: false
                )
            } else {
                access.url
            }
            NSWorkspace.shared.activateFileViewerSelecting([downloadURL])
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func scheduleSourceSignatureMaintenance(jobID: UUID) {
        sourceSignatureMaintenanceTasks[jobID]?.cancel()
        sourceSignatureMaintenanceTasks[jobID] = Task { [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            do {
                if let job = jobs.first(where: { $0.id == jobID }) {
                    try await sourceSignatureRepository.pruneSignatures(
                        jobID: jobID,
                        retainingSourceEndpoints: Self.sourceEndpoints(for: job)
                    )
                } else {
                    try await sourceSignatureRepository.removeSignatures(jobID: jobID)
                }
            } catch {
                appendAlert("Saved source signatures could not be cleaned up: \(error.localizedDescription)")
            }
            sourceSignatureMaintenanceTasks[jobID] = nil
        }
    }

    private static func sourceEndpoints(for job: SyncJob) -> [Endpoint] {
        switch job.direction {
        case .leftToRight: [job.left]
        case .rightToLeft: [job.right]
        case .bidirectional: [job.left, job.right]
        }
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var launchAtLoginRequiresApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginCoordinator.setEnabled(enabled)
        } catch {
            alertMessage = "Launch at Login could not be \(enabled ? "enabled" : "disabled"): \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLoginCoordinator.status
    }

    func openLoginItemsSettings() {
        launchAtLoginCoordinator.openSettings()
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

    func password(for endpoint: Endpoint) throws -> String {
        try persistenceCoordinator.password(for: endpoint) ?? ""
    }

    func password(for serverProfile: ServerProfile) throws -> String {
        try persistenceCoordinator.password(for: serverProfile.endpoint()) ?? ""
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
              let savedJob = jobs.first(where: { $0.id == jobID }) else { return .skipped }
        let job: SyncJob
        do {
            job = try savedJob.resolvingServerProfiles(in: serverProfiles)
        } catch {
            let message = error.localizedDescription
            recordSyncFailure(message, jobID: jobID)
            phases[jobID] = .failed(message, retryAt: nil)
            return .failed(message)
        }
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
            failureNotificationCoordinator.recordSuccess(jobID: jobID)
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
              let savedJob = jobs.first(where: { $0.id == jobID }) else { return }
        let job: SyncJob
        do {
            job = try savedJob.resolvingServerProfiles(in: serverProfiles)
        } catch {
            let message = error.localizedDescription
            metadataReprocessPhases[jobID] = .failed(message)
            alertMessage = message
            return
        }
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
            serverProfiles: serverProfiles,
            metadataAuditEntries: metadataAuditEntries,
            syncFailureEntries: syncFailureEntries
        )
    }

    private var metadataLibraryState: MetadataLibraryState {
        MetadataLibraryState(jobs: jobs, photographers: photographerLibrary)
    }

    private var currentConfigurationTransferState: ConfigurationTransferState {
        ConfigurationTransferState(
            jobs: jobs,
            metadataPresets: metadataPresets,
            photographers: photographerLibrary,
            serverProfiles: serverProfiles
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
        if let jobName = jobs.first(where: { $0.id == jobID })?.name {
            failureNotificationCoordinator.recordFailure(
                jobID: jobID,
                jobName: jobName,
                message: message
            )
        }
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
