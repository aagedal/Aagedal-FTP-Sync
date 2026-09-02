import Foundation
import UserNotifications

struct SyncFailureNotification: Equatable, Sendable {
    let jobID: UUID
    let jobName: String

    var identifier: String {
        "sync-failure-\(jobID.uuidString.lowercased())"
    }
}

@MainActor
protocol SyncFailureNotificationDelivering: AnyObject {
    func deliver(_ notification: SyncFailureNotification)
}

@MainActor
final class SystemSyncFailureNotificationDelivery: SyncFailureNotificationDelivering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func deliver(_ notification: SyncFailureNotification) {
        Task { [center] in
            let settings = await center.notificationSettings()
            let isAuthorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                isAuthorized = true
            case .notDetermined:
                isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            case .denied:
                isAuthorized = false
            @unknown default:
                isAuthorized = false
            }
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Sync job needs attention"
            content.subtitle = notification.jobName
            content.body = "Open Aagedal FTP Sync to review the error and retry the job."
            content.sound = .default
            content.userInfo = ["jobID": notification.jobID.uuidString]
            let request = UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

/// Converts run results into privacy-safe, per-job notifications without
/// repeating the same failure on every scheduled retry.
@MainActor
final class SyncFailureNotificationCoordinator {
    private struct FailureState {
        var message: String
        var lastNotificationAt: Date
    }

    private let delivery: any SyncFailureNotificationDelivering
    private let minimumNotificationInterval: TimeInterval
    private let now: @MainActor () -> Date
    private var failureStates: [UUID: FailureState] = [:]

    init(
        delivery: any SyncFailureNotificationDelivering = SystemSyncFailureNotificationDelivery(),
        minimumNotificationInterval: TimeInterval = 15 * 60,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        precondition(minimumNotificationInterval >= 0)
        self.delivery = delivery
        self.minimumNotificationInterval = minimumNotificationInterval
        self.now = now
    }

    func recordFailure(jobID: UUID, jobName: String, message: String) {
        let timestamp = now()
        if let state = failureStates[jobID] {
            guard state.message != message,
                  timestamp.timeIntervalSince(state.lastNotificationAt) >= minimumNotificationInterval else {
                return
            }
        }

        failureStates[jobID] = FailureState(message: message, lastNotificationAt: timestamp)
        let normalizedName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        delivery.deliver(SyncFailureNotification(
            jobID: jobID,
            jobName: normalizedName.isEmpty ? "Unnamed job" : normalizedName
        ))
    }

    func recordSuccess(jobID: UUID) {
        failureStates[jobID] = nil
    }

    func removeJob(_ jobID: UUID) {
        failureStates[jobID] = nil
    }
}

enum SyncAttempt {
    case succeeded
    case failed(String)
    case cancelled
    case skipped
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
protocol SyncSchedulerDelegate: AnyObject {
    func syncSchedulerJob(_ jobID: UUID) -> SyncJob?
    func syncSchedulerPerformSync(_ jobID: UUID) async -> SyncAttempt
    func syncSchedulerDidStop(_ jobID: UUID)
    func syncScheduler(
        _ jobID: UUID,
        scheduledNextRunAt date: Date,
        after attempt: SyncAttempt
    )
}

@MainActor
final class SyncScheduler {
    weak var delegate: (any SyncSchedulerDelegate)?

    private var scheduleTasks: [UUID: Task<Void, Never>] = [:]
    private var manualSyncTasks: [UUID: Task<Void, Never>] = [:]
    private var scheduledSyncTasks: [UUID: Task<SyncAttempt, Never>] = [:]
    private var pendingScheduledSyncJobs: Set<UUID> = []
    private var runningJobs: Set<UUID> = []
    private var manualRequestIDs: [UUID: UUID] = [:]
    private var scheduleRequestIDs: [UUID: UUID] = [:]

    func restart(with jobs: [SyncJob]) {
        for task in scheduleTasks.values { task.cancel() }
        for task in scheduledSyncTasks.values { task.cancel() }
        scheduleTasks.removeAll()
        scheduledSyncTasks.removeAll()
        pendingScheduledSyncJobs.removeAll()
        scheduleRequestIDs.removeAll()
        for job in jobs where job.isEnabled {
            schedule(job.id)
        }
    }

    func reschedule(_ jobID: UUID, job: SyncJob?) {
        scheduleTasks[jobID]?.cancel()
        scheduleTasks[jobID] = nil
        scheduledSyncTasks[jobID]?.cancel()
        scheduledSyncTasks[jobID] = nil
        pendingScheduledSyncJobs.remove(jobID)
        scheduleRequestIDs[jobID] = nil
        if job?.isEnabled == true {
            schedule(jobID)
        } else if !runningJobs.contains(jobID) {
            delegate?.syncSchedulerDidStop(jobID)
        }
    }

    func runNow(_ job: SyncJob) {
        guard !isBusy(job.id) else { return }
        if job.isEnabled {
            scheduleTasks[job.id]?.cancel()
            scheduleTasks[job.id] = nil
            schedule(job.id)
        } else {
            let requestID = UUID()
            manualRequestIDs[job.id] = requestID
            manualSyncTasks[job.id] = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled,
                      manualRequestIDs[job.id] == requestID else { return }
                _ = await delegate?.syncSchedulerPerformSync(job.id)
                guard manualRequestIDs[job.id] == requestID else { return }
                manualSyncTasks[job.id] = nil
                manualRequestIDs[job.id] = nil
            }
        }
    }

    func cancel(_ jobID: UUID) {
        scheduleTasks[jobID]?.cancel()
        scheduleTasks[jobID] = nil
        manualSyncTasks[jobID]?.cancel()
        manualSyncTasks[jobID] = nil
        scheduledSyncTasks[jobID]?.cancel()
        scheduledSyncTasks[jobID] = nil
        pendingScheduledSyncJobs.remove(jobID)
        manualRequestIDs[jobID] = nil
        scheduleRequestIDs[jobID] = nil
    }

    func cancelAll() {
        for task in scheduleTasks.values { task.cancel() }
        for task in manualSyncTasks.values { task.cancel() }
        for task in scheduledSyncTasks.values { task.cancel() }
        scheduleTasks.removeAll()
        manualSyncTasks.removeAll()
        scheduledSyncTasks.removeAll()
        pendingScheduledSyncJobs.removeAll()
        manualRequestIDs.removeAll()
        scheduleRequestIDs.removeAll()
    }

    func isBusy(_ jobID: UUID) -> Bool {
        runningJobs.contains(jobID)
            || manualSyncTasks[jobID] != nil
            || scheduledSyncTasks[jobID] != nil
            || pendingScheduledSyncJobs.contains(jobID)
    }

    func isRunning(_ jobID: UUID) -> Bool {
        runningJobs.contains(jobID)
    }

    @discardableResult
    func beginRunning(_ jobID: UUID) -> Bool {
        runningJobs.insert(jobID).inserted
    }

    func endRunning(_ jobID: UUID) {
        runningJobs.remove(jobID)
    }

    private func schedule(_ jobID: UUID) {
        let requestID = UUID()
        scheduleRequestIDs[jobID] = requestID
        pendingScheduledSyncJobs.insert(jobID)
        scheduleTasks[jobID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard scheduleRequestIDs[jobID] == requestID,
                      let delegate else { return }
                let operation = Task { @MainActor in
                    await delegate.syncSchedulerPerformSync(jobID)
                }
                scheduledSyncTasks[jobID] = operation
                pendingScheduledSyncJobs.remove(jobID)
                let attempt = await withTaskCancellationHandler {
                    await operation.value
                } onCancel: {
                    operation.cancel()
                }
                guard scheduleRequestIDs[jobID] == requestID else { return }
                scheduledSyncTasks[jobID] = nil

                guard !Task.isCancelled,
                      let job = delegate.syncSchedulerJob(jobID),
                      job.isEnabled else {
                    break
                }

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

                delegate.syncScheduler(
                    jobID,
                    scheduledNextRunAt: Date().addingTimeInterval(delay),
                    after: attempt
                )
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }
        }
    }
}
