import Foundation
import XCTest
@testable import AagedalFTPSync

@MainActor
final class SyncSchedulerTests: XCTestCase {
    func testDisabledRunNowStaysBusyUntilManualAttemptCompletesAndIgnoresDuplicateRequest() async {
        let scheduler = SyncScheduler()
        let delegate = SyncSchedulerDelegateSpy()
        delegate.blocksAttempts = true
        scheduler.delegate = delegate
        var job = SyncJob(name: "Manual")
        job.isEnabled = false

        scheduler.runNow(job)
        scheduler.runNow(job)

        XCTAssertTrue(scheduler.isBusy(job.id))
        let attemptStarted = await eventually { delegate.performCallCount == 1 }
        XCTAssertTrue(attemptStarted)
        XCTAssertEqual(delegate.performedJobIDs, [job.id])

        delegate.resumeBlockedAttempt(returning: .succeeded)

        let attemptFinished = await eventually { !scheduler.isBusy(job.id) }
        XCTAssertTrue(attemptFinished)
        XCTAssertFalse(scheduler.isRunning(job.id))
    }

    func testEnabledFailurePublishesRetryDateWithoutWaitingForRetryInterval() async throws {
        let scheduler = SyncScheduler()
        let delegate = SyncSchedulerDelegateSpy()
        scheduler.delegate = delegate
        var job = SyncJob(name: "Scheduled retry")
        job.isEnabled = true
        job.intervalSeconds = 2
        delegate.jobs[job.id] = job
        delegate.immediateAttempts = [.failed("Offline")]
        let startedAt = Date()

        scheduler.restart(with: [job])

        XCTAssertTrue(scheduler.isBusy(job.id))
        let retryWasScheduled = await eventually { delegate.nextRunEvents.count == 1 }
        XCTAssertTrue(retryWasScheduled)
        let event = try XCTUnwrap(delegate.nextRunEvents.first)
        XCTAssertEqual(event.jobID, job.id)
        guard case .failed(let message) = event.attempt else {
            return XCTFail("Expected a failed attempt to schedule the retry.")
        }
        XCTAssertEqual(message, "Offline")
        XCTAssertGreaterThanOrEqual(event.date.timeIntervalSince(startedAt), 1.8)
        XCTAssertLessThan(event.date.timeIntervalSince(startedAt), 2.5)
        XCTAssertEqual(delegate.performCallCount, 1)

        scheduler.cancel(job.id)

        XCTAssertFalse(scheduler.isBusy(job.id))
        XCTAssertEqual(delegate.performCallCount, 1)
    }

    func testRestartAndExplicitCancelReleaseScheduledBusyState() async {
        let scheduler = SyncScheduler()
        let delegate = SyncSchedulerDelegateSpy()
        delegate.blocksAttempts = true
        scheduler.delegate = delegate
        var job = SyncJob(name: "Restart cleanup")
        job.isEnabled = true
        delegate.jobs[job.id] = job

        scheduler.restart(with: [job])
        let firstAttemptStarted = await eventually { delegate.performCallCount == 1 }
        XCTAssertTrue(firstAttemptStarted)
        XCTAssertTrue(scheduler.isBusy(job.id))

        scheduler.restart(with: [])
        delegate.resumeBlockedAttempt(returning: .cancelled)

        let restartFinished = await eventually { !scheduler.isBusy(job.id) }
        XCTAssertTrue(restartFinished)

        scheduler.restart(with: [job])
        let secondAttemptStarted = await eventually { delegate.performCallCount == 2 }
        XCTAssertTrue(secondAttemptStarted)
        XCTAssertTrue(scheduler.isBusy(job.id))

        scheduler.cancel(job.id)

        XCTAssertFalse(scheduler.isBusy(job.id))
        delegate.resumeBlockedAttempt(returning: .cancelled)
        await Task.yield()
        XCTAssertFalse(scheduler.isBusy(job.id))
    }

    func testBeginRunningRejectsDuplicateOwnershipAndPreventsRunNow() async {
        let scheduler = SyncScheduler()
        let delegate = SyncSchedulerDelegateSpy()
        scheduler.delegate = delegate
        var job = SyncJob(name: "Already running")
        job.isEnabled = false

        XCTAssertTrue(scheduler.beginRunning(job.id))
        XCTAssertFalse(scheduler.beginRunning(job.id))
        XCTAssertTrue(scheduler.isRunning(job.id))
        XCTAssertTrue(scheduler.isBusy(job.id))

        scheduler.runNow(job)
        await Task.yield()

        XCTAssertEqual(delegate.performCallCount, 0)
        scheduler.endRunning(job.id)
        XCTAssertFalse(scheduler.isRunning(job.id))
        XCTAssertFalse(scheduler.isBusy(job.id))
    }

    func testCancellingManualRequestBeforeItStartsDoesNotInvokeDelegate() async {
        let scheduler = SyncScheduler()
        let delegate = SyncSchedulerDelegateSpy()
        scheduler.delegate = delegate
        var job = SyncJob(name: "Cancelled manual request")
        job.isEnabled = false

        scheduler.runNow(job)
        scheduler.cancel(job.id)
        await Task.yield()

        XCTAssertEqual(delegate.performCallCount, 0)
        XCTAssertFalse(scheduler.isBusy(job.id))
    }

    private func eventually(
        attempts: Int = 100,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

@MainActor
final class SyncFailureNotificationCoordinatorTests: XCTestCase {
    func testFirstFailureNotifiesAndIdenticalRetriesStayQuiet() {
        let delivery = SyncFailureNotificationDeliverySpy()
        let clock = SyncFailureNotificationClock()
        let coordinator = SyncFailureNotificationCoordinator(
            delivery: delivery,
            minimumNotificationInterval: 15 * 60,
            now: { clock.now }
        )
        let jobID = UUID()

        coordinator.recordFailure(jobID: jobID, jobName: "  Newsroom  ", message: "Offline")
        clock.now = clock.now.addingTimeInterval(60 * 60)
        coordinator.recordFailure(jobID: jobID, jobName: "Newsroom", message: "Offline")

        XCTAssertEqual(delivery.notifications, [
            SyncFailureNotification(jobID: jobID, jobName: "Newsroom")
        ])
    }

    func testChangedFailureIsThrottledUntilMinimumIntervalPasses() {
        let delivery = SyncFailureNotificationDeliverySpy()
        let clock = SyncFailureNotificationClock()
        let coordinator = SyncFailureNotificationCoordinator(
            delivery: delivery,
            minimumNotificationInterval: 15 * 60,
            now: { clock.now }
        )
        let jobID = UUID()

        coordinator.recordFailure(jobID: jobID, jobName: "Wire", message: "Offline")
        clock.now = clock.now.addingTimeInterval(14 * 60)
        coordinator.recordFailure(jobID: jobID, jobName: "Wire", message: "Login failed")
        clock.now = clock.now.addingTimeInterval(60)
        coordinator.recordFailure(jobID: jobID, jobName: "Wire", message: "Login failed")

        XCTAssertEqual(delivery.notifications.count, 2)
    }

    func testSuccessRearmsFailureTransition() {
        let delivery = SyncFailureNotificationDeliverySpy()
        let clock = SyncFailureNotificationClock()
        let coordinator = SyncFailureNotificationCoordinator(
            delivery: delivery,
            minimumNotificationInterval: 15 * 60,
            now: { clock.now }
        )
        let jobID = UUID()

        coordinator.recordFailure(jobID: jobID, jobName: "Archive", message: "Offline")
        coordinator.recordSuccess(jobID: jobID)
        coordinator.recordFailure(jobID: jobID, jobName: "Archive", message: "Offline")

        XCTAssertEqual(delivery.notifications.count, 2)
    }

    func testFailuresAreThrottledIndependentlyPerJobAndBlankNamesAreSafe() {
        let delivery = SyncFailureNotificationDeliverySpy()
        let coordinator = SyncFailureNotificationCoordinator(delivery: delivery)
        let firstJobID = UUID()
        let secondJobID = UUID()

        coordinator.recordFailure(jobID: firstJobID, jobName: "First", message: "Offline")
        coordinator.recordFailure(jobID: secondJobID, jobName: "   ", message: "Offline")

        XCTAssertEqual(delivery.notifications, [
            SyncFailureNotification(jobID: firstJobID, jobName: "First"),
            SyncFailureNotification(jobID: secondJobID, jobName: "Unnamed job"),
        ])
        XCTAssertTrue(delivery.notifications.allSatisfy { !$0.identifier.contains("Offline") })
    }
}

@MainActor
private final class SyncSchedulerDelegateSpy: SyncSchedulerDelegate {
    struct NextRunEvent {
        let jobID: UUID
        let date: Date
        let attempt: SyncAttempt
    }

    var jobs: [UUID: SyncJob] = [:]
    var immediateAttempts: [SyncAttempt] = []
    var blocksAttempts = false
    private(set) var performedJobIDs: [UUID] = []
    private(set) var stoppedJobIDs: [UUID] = []
    private(set) var nextRunEvents: [NextRunEvent] = []
    private var blockedContinuation: CheckedContinuation<SyncAttempt, Never>?

    var performCallCount: Int { performedJobIDs.count }

    func syncSchedulerJob(_ jobID: UUID) -> SyncJob? {
        jobs[jobID]
    }

    func syncSchedulerPerformSync(_ jobID: UUID) async -> SyncAttempt {
        performedJobIDs.append(jobID)
        if !immediateAttempts.isEmpty {
            return immediateAttempts.removeFirst()
        }
        guard blocksAttempts else { return .skipped }
        return await withCheckedContinuation { continuation in
            precondition(blockedContinuation == nil, "Only one blocked scheduler attempt is expected at a time.")
            blockedContinuation = continuation
        }
    }

    func syncSchedulerDidStop(_ jobID: UUID) {
        stoppedJobIDs.append(jobID)
    }

    func syncScheduler(
        _ jobID: UUID,
        scheduledNextRunAt date: Date,
        after attempt: SyncAttempt
    ) {
        nextRunEvents.append(NextRunEvent(jobID: jobID, date: date, attempt: attempt))
    }

    func resumeBlockedAttempt(returning attempt: SyncAttempt) {
        let continuation = blockedContinuation
        blockedContinuation = nil
        continuation?.resume(returning: attempt)
    }
}

@MainActor
private final class SyncFailureNotificationDeliverySpy: SyncFailureNotificationDelivering {
    private(set) var notifications: [SyncFailureNotification] = []

    func deliver(_ notification: SyncFailureNotification) {
        notifications.append(notification)
    }
}

@MainActor
private final class SyncFailureNotificationClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}
