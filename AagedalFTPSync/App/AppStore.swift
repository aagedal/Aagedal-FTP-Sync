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

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var jobs: [SyncJob]
    @Published private(set) var phases: [UUID: JobPhase] = [:]
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published var selectedJobID: UUID?
    @Published var alertMessage: String?

    private let repository: JobRepository
    private let keychain: KeychainStore
    private let engine = SyncEngine()
    private var scheduleTasks: [UUID: Task<Void, Never>] = [:]
    private var runningJobs: Set<UUID> = []
    private var transferTotals = JobTransferTotals()
    private var cachedPasswords: [String: String] = [:]
    private var loadedCredentialIDs = Set<String>()

    init(repository: JobRepository = JobRepository(), keychain: KeychainStore = KeychainStore()) {
        self.repository = repository
        self.keychain = keychain
        do {
            jobs = try repository.load()
        } catch {
            jobs = []
            alertMessage = "Saved jobs could not be loaded: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
        selectedJobID = jobs.last?.id
        for index in jobs.indices {
            let shouldStart = jobs[index].startsOnAppLaunch
            jobs[index].startOnAppLaunch = shouldStart
            jobs[index].isEnabled = shouldStart
            phases[jobs[index].id] = .stopped
        }
        Task { [weak self] in self?.restartSchedules() }
    }

    deinit {
        for task in scheduleTasks.values { task.cancel() }
    }

    func addJob() -> SyncJob {
        let job = SyncJob(name: uniqueName())
        jobs.append(job)
        selectedJobID = job.id
        phases[job.id] = .stopped
        persist()
        return job
    }

    func saveJob(_ job: SyncJob, leftPassword: String, rightPassword: String) {
        if let message = job.validationMessage {
            alertMessage = message
            return
        }
        let wasEnabled = jobs.first(where: { $0.id == job.id })?.isEnabled ?? false
        do {
            if job.left.kind.isRemote, !leftPassword.isEmpty {
                try savePasswordIfNeeded(leftPassword, for: job.left.credentialID)
            }
            if job.right.kind.isRemote, !rightPassword.isEmpty {
                try savePasswordIfNeeded(rightPassword, for: job.right.credentialID)
            }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
            else { jobs.append(job) }
            if job.isEnabled, !wasEnabled { transferTotals.reset(jobID: job.id) }
            persist()
            reschedule(job.id)
        } catch {
            alertMessage = error.localizedDescription
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
        if job.left.kind.isRemote { keychain.removePassword(for: job.left.credentialID) }
        if job.right.kind.isRemote { keychain.removePassword(for: job.right.credentialID) }
        removeCachedPassword(for: job.left.credentialID)
        removeCachedPassword(for: job.right.credentialID)
        jobs.removeAll { $0.id == jobID }
        if selectedJobID == jobID { selectedJobID = jobs.last?.id }
        phases[jobID] = nil
        transferTotals.remove(jobID: jobID)
        persist()
    }

    func runNow(_ jobID: UUID) {
        Task { await performSync(jobID) }
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
            while !Task.isCancelled {
                await self.performSync(jobID)
                guard !Task.isCancelled,
                      let job = self.jobs.first(where: { $0.id == jobID }),
                      job.isEnabled else { break }
                let next = Date().addingTimeInterval(job.intervalSeconds)
                self.phases[jobID] = .waiting(next)
                do {
                    try await Task.sleep(for: .seconds(job.intervalSeconds))
                } catch { break }
            }
        }
    }

    private func performSync(_ jobID: UUID) async {
        guard !runningJobs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return }
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
                deleted: result.deleted
            )
        } catch is CancellationError {
            phases[jobID] = .stopped
        } catch {
            phases[jobID] = .failed(error.localizedDescription)
        }
    }

    private func persist() {
        do { try repository.save(jobs) }
        catch { alertMessage = "Changes could not be saved: \(error.localizedDescription)" }
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
