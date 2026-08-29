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

enum SyncRetryPolicy {
    static func delay(baseInterval: Double, consecutiveFailures: Int) -> Double {
        var delay = min(max(baseInterval, 2), 300)
        for _ in 1..<max(consecutiveFailures, 1) {
            delay = min(delay * 2, 300)
        }
        return delay
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var jobs: [SyncJob]
    @Published private(set) var metadataPresets: [MetadataPreset]
    @Published private(set) var phases: [UUID: JobPhase] = [:]
    @Published private(set) var metadataReprocessPhases: [UUID: MetadataReprocessPhase] = [:]
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published var selectedJobID: UUID?
    @Published var alertMessage: String?

    private let repository: JobRepository
    private let metadataPresetRepository: MetadataPresetRepository
    private let keychain: KeychainStore
    private let engine = SyncEngine()
    private var scheduleTasks: [UUID: Task<Void, Never>] = [:]
    private var runningJobs: Set<UUID> = []
    private var transferTotals = JobTransferTotals()
    private var cachedPasswords: [String: String] = [:]
    private var loadedCredentialIDs = Set<String>()

    init(
        repository: JobRepository = JobRepository(),
        metadataPresetRepository: MetadataPresetRepository = MetadataPresetRepository(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.repository = repository
        self.metadataPresetRepository = metadataPresetRepository
        self.keychain = keychain
        do {
            let loadResult = try metadataPresetRepository.loadResult()
            metadataPresets = loadResult.presets
            if loadResult.recoveredFromBackup {
                alertMessage = "The metadata preset library was damaged, so its most recent backup was restored."
            }
        } catch {
            metadataPresets = []
            alertMessage = "Saved metadata presets could not be loaded: \(error.localizedDescription)"
        }
        let recoveredFromBackup: Bool
        do {
            let loadResult = try repository.loadResult()
            jobs = loadResult.jobs
            recoveredFromBackup = loadResult.recoveredFromBackup
            if loadResult.recoveredFromBackup {
                appendAlert("The jobs file was damaged, so the most recent backup was restored. Review your jobs before starting them.")
            }
        } catch {
            jobs = []
            recoveredFromBackup = false
            appendAlert("Saved jobs could not be loaded: \(error.localizedDescription)")
        }
        refreshLaunchAtLoginStatus()
        selectedJobID = jobs.last?.id
        for index in jobs.indices {
            let configuredToStart = jobs[index].startsOnAppLaunch
            let shouldStart = !recoveredFromBackup && configuredToStart
            jobs[index].startOnAppLaunch = configuredToStart
            jobs[index].isEnabled = shouldStart
            phases[jobs[index].id] = .stopped
        }
        Task { [weak self] in self?.restartSchedules() }
    }

    deinit {
        for task in scheduleTasks.values { task.cancel() }
    }

    func addJob() -> SyncJob {
        var job = SyncJob(name: uniqueName())
        job.isEnabled = false
        job.startsOnAppLaunch = false
        jobs.append(job)
        selectedJobID = job.id
        phases[job.id] = .stopped
        persist()
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
            if job.left.kind.isRemote, !leftPassword.isEmpty {
                try savePasswordIfNeeded(leftPassword, for: job.left.credentialID)
            }
            if job.right.kind.isRemote, !rightPassword.isEmpty {
                try savePasswordIfNeeded(rightPassword, for: job.right.credentialID)
            }
            var updatedJobs = jobs
            if let index = updatedJobs.firstIndex(where: { $0.id == job.id }) { updatedJobs[index] = job }
            else { updatedJobs.append(job) }
            try repository.save(updatedJobs)
            jobs = updatedJobs

            if let previousJob {
                removeCredentialsNoLongerUsed(previousJob: previousJob, updatedJob: job)
            }
            if job.isEnabled, !wasEnabled { transferTotals.reset(jobID: job.id) }
            reschedule(job.id)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func updateFilter(jobID: UUID, preset: FilterPreset) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].filter.preset = preset
        persist()
    }

    func updateInterval(jobID: UUID, seconds: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].intervalSeconds = min(max(seconds, 2), 300)
        persist()
        reschedule(jobID)
    }

    func updateFileAge(jobID: UUID, recentHours: Int?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].filter.recentHours = recentHours
        if let recentHours,
           let cleanup = jobs[index].targetCleanup,
           cleanup.olderThanHours <= recentHours {
            jobs[index].targetCleanup?.olderThanHours = recentHours + 1
        }
        persist()
    }

    @discardableResult
    func saveMetadataAutomation(_ automation: MetadataAutomation, for jobID: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return false }
        var updatedJob = jobs[index]
        updatedJob.metadataAutomation = automation
        if let message = updatedJob.validationMessage {
            alertMessage = message
            return false
        }

        var updatedJobs = jobs
        updatedJobs[index] = updatedJob
        do {
            try repository.save(updatedJobs)
            jobs = updatedJobs
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
            try metadataPresetRepository.save(updatedPresets)
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
            try metadataPresetRepository.save(updatedPresets)
            metadataPresets = updatedPresets
            return true
        } catch {
            alertMessage = "The metadata preset could not be removed: \(error.localizedDescription)"
            return false
        }
    }

    func setEnabled(_ enabled: Bool, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if enabled, !jobs[index].isEnabled { transferTotals.reset(jobID: jobID) }
        jobs[index].isEnabled = enabled
        persist()
        reschedule(jobID)
    }

    func removeJob(_ jobID: UUID) {
        scheduleTasks[jobID]?.cancel()
        scheduleTasks[jobID] = nil
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        keychain.removePassword(for: job.left.credentialID)
        keychain.removePassword(for: job.right.credentialID)
        removeCachedPassword(for: job.left.credentialID)
        removeCachedPassword(for: job.right.credentialID)
        jobs.removeAll { $0.id == jobID }
        if selectedJobID == jobID { selectedJobID = jobs.last?.id }
        phases[jobID] = nil
        metadataReprocessPhases[jobID] = nil
        transferTotals.remove(jobID: jobID)
        persist()
    }

    func runNow(_ jobID: UUID) {
        Task { _ = await performSync(jobID) }
    }

    func reprocessExistingLocalFiles(_ jobID: UUID) {
        Task { await performMetadataReprocess(jobID) }
    }

    func isJobBusy(_ jobID: UUID) -> Bool {
        runningJobs.contains(jobID)
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
        for index in jobs.indices {
            if !jobs[index].isEnabled { transferTotals.reset(jobID: jobs[index].id) }
            jobs[index].isEnabled = true
        }
        persist()
        restartSchedules()
    }

    func stopAll() {
        for index in jobs.indices { jobs[index].isEnabled = false }
        persist()
        restartSchedules()
    }

    func password(for endpoint: Endpoint) -> String {
        guard endpoint.kind.isRemote else { return "" }
        return (try? cachedPassword(for: endpoint.credentialID)) ?? ""
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

    private func restartSchedules() {
        for task in scheduleTasks.values { task.cancel() }
        scheduleTasks.removeAll()
        for job in jobs where job.isEnabled { schedule(job.id) }
    }

    private func reschedule(_ jobID: UUID) {
        scheduleTasks[jobID]?.cancel()
        scheduleTasks[jobID] = nil
        if jobs.first(where: { $0.id == jobID })?.isEnabled == true { schedule(jobID) }
        else if !runningJobs.contains(jobID) { phases[jobID] = .stopped }
    }

    private func schedule(_ jobID: UUID) {
        scheduleTasks[jobID] = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                let attempt = await self.performSync(jobID)
                guard !Task.isCancelled,
                      let job = self.jobs.first(where: { $0.id == jobID }),
                      job.isEnabled else { break }

                let delay: Double
                switch attempt {
                case .succeeded:
                    consecutiveFailures = 0
                    delay = job.intervalSeconds
                case .failed:
                    consecutiveFailures += 1
                    delay = SyncRetryPolicy.delay(
                        baseInterval: job.intervalSeconds,
                        consecutiveFailures: consecutiveFailures
                    )
                case .skipped:
                    delay = job.intervalSeconds
                case .cancelled:
                    return
                }

                let next = Date().addingTimeInterval(delay)
                switch attempt {
                case .succeeded:
                    if case .succeeded(let date, let transferred, let deleted, let conflicts, _) = self.phases[jobID] {
                        self.phases[jobID] = .succeeded(
                            date,
                            transferred: transferred,
                            deleted: deleted,
                            conflicts: conflicts,
                            nextRun: next
                        )
                    }
                case .failed(let message):
                    self.phases[jobID] = .failed(message, retryAt: next)
                case .skipped:
                    break
                case .cancelled:
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch { break }
            }
        }
    }

    private func performSync(_ jobID: UUID) async -> SyncAttempt {
        guard !runningJobs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return .skipped }
        runningJobs.insert(jobID)
        phases[jobID] = .syncing
        defer { runningJobs.remove(jobID) }
        do {
            let leftPassword = job.left.kind.isRemote ? try cachedPassword(for: job.left.credentialID) : nil
            let rightPassword = job.right.kind.isRemote ? try cachedPassword(for: job.right.credentialID) : nil
            let result = try await engine.run(job: job, leftPassword: leftPassword, rightPassword: rightPassword)
            let completedAt = Date()
            transferTotals.record(jobID: jobID, fileCount: result.transferred)
            phases[jobID] = .succeeded(
                completedAt,
                transferred: result.transferred,
                deleted: result.deleted,
                conflicts: result.conflicts,
                nextRun: nil
            )
            return .succeeded
        } catch is CancellationError {
            phases[jobID] = .stopped
            return .cancelled
        } catch {
            let message = error.localizedDescription
            phases[jobID] = .failed(message, retryAt: nil)
            return .failed(message)
        }
    }

    private func performMetadataReprocess(_ jobID: UUID) async {
        guard !runningJobs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        runningJobs.insert(jobID)
        metadataReprocessPhases[jobID] = .running
        defer { runningJobs.remove(jobID) }

        do {
            let result = try await engine.reprocessExistingLocalFiles(job: job)
            metadataReprocessPhases[jobID] = .succeeded(Date(), result)
        } catch is CancellationError {
            metadataReprocessPhases[jobID] = .idle
        } catch {
            let message = error.localizedDescription
            metadataReprocessPhases[jobID] = .failed(message)
            alertMessage = message
        }
    }

    private func persist() {
        do { try repository.save(jobs) }
        catch { alertMessage = "Changes could not be saved: \(error.localizedDescription)" }
    }

    private func appendAlert(_ message: String) {
        if let alertMessage, !alertMessage.isEmpty {
            self.alertMessage = alertMessage + "\n\n" + message
        } else {
            alertMessage = message
        }
    }

    private func cachedPassword(for credentialID: String) throws -> String? {
        if loadedCredentialIDs.contains(credentialID) {
            return cachedPasswords[credentialID]
        }

        let password = try keychain.password(for: credentialID)
        loadedCredentialIDs.insert(credentialID)
        if let password { cachedPasswords[credentialID] = password }
        return password
    }

    private func cache(password: String, for credentialID: String) {
        cachedPasswords[credentialID] = password
        loadedCredentialIDs.insert(credentialID)
    }

    private func savePasswordIfNeeded(_ password: String, for credentialID: String) throws {
        if loadedCredentialIDs.contains(credentialID), cachedPasswords[credentialID] == password {
            return
        }
        try keychain.setPassword(password, for: credentialID)
        cache(password: password, for: credentialID)
    }

    private func removeCachedPassword(for credentialID: String) {
        cachedPasswords[credentialID] = nil
        loadedCredentialIDs.remove(credentialID)
    }

    private func removeCredentialsNoLongerUsed(previousJob: SyncJob, updatedJob: SyncJob) {
        let previousIDs = Set([previousJob.left, previousJob.right]
            .filter(\.kind.isRemote)
            .map(\.credentialID))
        let updatedIDs = Set([updatedJob.left, updatedJob.right]
            .filter(\.kind.isRemote)
            .map(\.credentialID))
        for credentialID in previousIDs.subtracting(updatedIDs) {
            keychain.removePassword(for: credentialID)
            removeCachedPassword(for: credentialID)
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

private enum SyncAttempt {
    case succeeded
    case failed(String)
    case cancelled
    case skipped
}
