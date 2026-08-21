import AppKit
import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var jobs: [SyncJob]
    @Published private(set) var phases: [UUID: JobPhase] = [:]
    @Published var alertMessage: String?

    private let repository: JobRepository
    private let keychain: KeychainStore
    private let engine = SyncEngine()
    private var scheduleTasks: [UUID: Task<Void, Never>] = [:]
    private var runningJobs: Set<UUID> = []

    init(repository: JobRepository = JobRepository(), keychain: KeychainStore = KeychainStore()) {
        self.repository = repository
        self.keychain = keychain
        do {
            jobs = try repository.load()
        } catch {
            jobs = []
            alertMessage = "Saved jobs could not be loaded: \(error.localizedDescription)"
        }
        for job in jobs { phases[job.id] = .stopped }
        Task { [weak self] in self?.restartSchedules() }
    }

    deinit {
        for task in scheduleTasks.values { task.cancel() }
    }

    func addJob() -> SyncJob {
        let job = SyncJob(name: uniqueName())
        jobs.append(job)
        phases[job.id] = .stopped
        persist()
        return job
    }

    func saveJob(_ job: SyncJob, leftPassword: String, rightPassword: String) {
        if let message = job.validationMessage {
            alertMessage = message
            return
        }
        do {
            if job.left.kind.isRemote, !leftPassword.isEmpty {
                try keychain.setPassword(leftPassword, for: job.left.credentialID)
            }
            if job.right.kind.isRemote, !rightPassword.isEmpty {
                try keychain.setPassword(rightPassword, for: job.right.credentialID)
            }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
            else { jobs.append(job) }
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

    func setEnabled(_ enabled: Bool, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
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
        jobs.removeAll { $0.id == jobID }
        phases[jobID] = nil
        persist()
    }

    func runNow(_ jobID: UUID) {
        Task { await performSync(jobID) }
    }

    func startAll() {
        for index in jobs.indices { jobs[index].isEnabled = true }
        persist()
        restartSchedules()
    }

    func stopAll() {
        for index in jobs.indices { jobs[index].isEnabled = false }
        persist()
        restartSchedules()
    }

    func password(for endpoint: Endpoint) -> String {
        (try? keychain.password(for: endpoint.credentialID)) ?? ""
    }

    var activeCount: Int { jobs.filter(\.isEnabled).count }
    var isSyncing: Bool { phases.values.contains(.syncing) }

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
            let leftPassword = job.left.kind.isRemote ? try keychain.password(for: job.left.credentialID) : nil
            let rightPassword = job.right.kind.isRemote ? try keychain.password(for: job.right.credentialID) : nil
            let count = try await engine.run(job: job, leftPassword: leftPassword, rightPassword: rightPassword)
            phases[jobID] = .succeeded(Date(), transferred: count)
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
