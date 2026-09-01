import Foundation
import XCTest
@testable import AagedalFTPSync

final class JobRepositoryTests: XCTestCase {
    @MainActor
    func testScheduledJobsUseTheSharedGlobalConcurrencyLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-concurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let jobs = ["first", "second"].map { label in
            var job = SyncJob(name: label)
            job.left = Endpoint(
                kind: .local,
                localPath: "/\(label)/left",
                bookmark: Data("left".utf8)
            )
            job.right = Endpoint(
                kind: .local,
                localPath: "/\(label)/right",
                bookmark: Data("right".utf8)
            )
            job.direction = .leftToRight
            job.intervalSeconds = 300
            job.isEnabled = true
            job.startsOnAppLaunch = true
            return job
        }
        try repository.save(jobs)

        let probe = ScheduledConcurrencyProbe()
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ in
            ProbeEndpointSession(
                jobLabel: endpoint.localPath.split(separator: "/").first.map(String.init) ?? "unknown",
                probe: probe
            )
        })
        let controller = SyncConcurrencyController(
            policy: SyncConcurrencyPolicy(globalLimit: 1, perHostLimit: nil)
        )
        let store = AppStore(
            repository: repository,
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            photographerProfileRepository: PhotographerProfileRepository(fileURL: root.appendingPathComponent("photographers.json")),
            metadataAuditRepository: MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json")),
            syncFailureRepository: SyncFailureRepository(fileURL: root.appendingPathComponent("failures.json")),
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.json")),
            engine: engine,
            syncConcurrencyController: controller
        )

        let firstStarted = try await probe.waitForStartedJobCount(1)
        XCTAssertEqual(firstStarted.count, 1)
        try await Task.sleep(for: .milliseconds(30))
        let stillOnlyFirstStarted = await probe.startedJobs()
        XCTAssertEqual(stillOnlyFirstStarted, firstStarted)

        await probe.release(job: try XCTUnwrap(firstStarted.first))
        let bothStarted = try await probe.waitForStartedJobCount(2)
        XCTAssertEqual(bothStarted, Set(["first", "second"]))

        store.stopAll()
        await probe.releaseAll()
        for _ in 0..<100 where store.jobs.contains(where: { store.isJobBusy($0.id) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.jobs.contains(where: { store.isJobBusy($0.id) }))
    }

    @MainActor
    func testRemoveJobRefusesWhileManualSyncTaskIsActive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("busy-job-removal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        var job = SyncJob(name: "Busy")
        job.left = Endpoint(kind: .local, localPath: "/mock-left", bookmark: Data("left".utf8))
        job.right = Endpoint(kind: .local, localPath: "/mock-right", bookmark: Data("right".utf8))
        job.direction = .leftToRight
        job.isEnabled = false
        job.startsOnAppLaunch = false
        try repository.save([job])
        let session = BlockingEndpointSession()
        let engine = SyncEngine(sessionFactory: { _, _, _ in session })
        let store = AppStore(
            repository: repository,
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            photographerProfileRepository: PhotographerProfileRepository(fileURL: root.appendingPathComponent("photographers.json")),
            metadataAuditRepository: MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json")),
            syncFailureRepository: SyncFailureRepository(fileURL: root.appendingPathComponent("failures.json")),
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.json")),
            engine: engine
        )
        let storedJobID = try XCTUnwrap(store.jobs.first?.id)

        store.runNow(storedJobID)
        XCTAssertTrue(store.isJobBusy(storedJobID))
        store.removeJob(storedJobID)

        XCTAssertTrue(store.jobs.contains(where: { $0.id == storedJobID }))
        XCTAssertTrue(store.alertMessage?.contains("current operation") == true)
        await session.release()
        while store.isJobBusy(storedJobID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.jobs.contains(where: { $0.id == storedJobID }))
    }

    @MainActor
    func testRemoveJobRefusesWhileScheduledSyncTaskIsActive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("busy-scheduled-removal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        var job = SyncJob(name: "Scheduled busy")
        job.left = Endpoint(kind: .local, localPath: "/mock-left", bookmark: Data("left".utf8))
        job.right = Endpoint(kind: .local, localPath: "/mock-right", bookmark: Data("right".utf8))
        job.direction = .leftToRight
        job.isEnabled = true
        job.startsOnAppLaunch = true
        try repository.save([job])
        let session = BlockingEndpointSession()
        let engine = SyncEngine(sessionFactory: { _, _, _ in session })
        let store = AppStore(
            repository: repository,
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            photographerProfileRepository: PhotographerProfileRepository(fileURL: root.appendingPathComponent("photographers.json")),
            metadataAuditRepository: MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json")),
            syncFailureRepository: SyncFailureRepository(fileURL: root.appendingPathComponent("failures.json")),
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.json")),
            engine: engine
        )
        let storedJobID = try XCTUnwrap(store.jobs.first?.id)

        XCTAssertTrue(store.isJobBusy(storedJobID))
        store.removeJob(storedJobID)
        XCTAssertTrue(store.jobs.contains(where: { $0.id == storedJobID }))

        await session.release()
        while store.isJobBusy(storedJobID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.setEnabled(false, for: storedJobID)
        XCTAssertTrue(store.jobs.contains(where: { $0.id == storedJobID }))
    }

    func testRoundTripsMultipleJobs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = JobRepository(fileURL: url)
        var first = SyncJob(name: "Desk one")
        first.isEnabled = false
        first.startsOnAppLaunch = false
        var second = SyncJob(name: "Desk two")
        second.filter.preset = .raw

        try repository.save([first, second])

        let loaded = try repository.load()
        XCTAssertEqual(loaded, [first, second])
    }

    func testLegacyJobInheritsItsPreviousEnabledStateAtLaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = JobRepository(fileURL: url)
        var job = SyncJob(name: "Legacy paused job")
        job.isEnabled = false

        try repository.save([job])
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        json[0]["startOnAppLaunch"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        let loaded = try XCTUnwrap(repository.load().first)
        XCTAssertFalse(loaded.startsOnAppLaunch)
    }

    func testLegacyJobUsesCumulativeTransferCount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-count-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = JobRepository(fileURL: url)

        try repository.save([SyncJob(name: "Legacy count job")])
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        json[0]["latestSessionTransferCountOnly"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        let loaded = try XCTUnwrap(repository.load().first)
        XCTAssertFalse(loaded.showsLatestSessionTransferCountOnly)
    }

    func testLegacyProcessedFolderDefaultsToCustomFolderWithoutPhotographerSorting() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-processed-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = JobRepository(fileURL: url)
        var job = SyncJob(name: "Legacy processed folder")
        job.processedFolder = Endpoint(
            kind: .local,
            localPath: "/Users/example/Processed",
            bookmark: Data([1])
        )

        try repository.save([job])
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        json[0]["processedFilesLocation"] = nil
        json[0]["sortProcessedFilesByPhotographer"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        let loaded = try XCTUnwrap(repository.load().first)
        XCTAssertTrue(loaded.movesProcessedFiles)
        XCTAssertEqual(loaded.effectiveProcessedFilesLocation, .customFolder)
        XCTAssertFalse(loaded.sortsProcessedFilesByPhotographer)
    }

    func testLegacyEndpointWithoutHostKeyFingerprintStillLoadsForReview() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-host-key-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = JobRepository(fileURL: url)
        var job = SyncJob(name: "Legacy SFTP job")
        job.left = Endpoint(kind: .sftp, host: "photos.example.com", username: "desk")

        try repository.save([job])
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var left = try XCTUnwrap(json[0]["left"] as? [String: Any])
        left["hostKeyFingerprint"] = nil
        json[0]["left"] = left
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        let loaded = try XCTUnwrap(repository.load().first)
        XCTAssertEqual(loaded.left.hostKeyFingerprint, "")
        XCTAssertNotNil(loaded.left.validationMessage)
    }

    func testRecoversFromBackupWhenPrimaryFileIsCorrupt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recover-jobs-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
        }
        let repository = JobRepository(fileURL: url)
        let recoverableJob = SyncJob(name: "Recover me")

        try repository.save([recoverableJob])
        try repository.save([SyncJob(name: "Newer state")])
        try Data("not valid JSON".utf8).write(to: url, options: .atomic)

        let result = try repository.loadResult()
        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.jobs, [recoverableJob])
    }
}

private actor BlockingEndpointSession: EndpointSession {
    private var isReleased = false

    func release() { isReleased = true }

    func listFiles() async throws -> [String: SyncFile] {
        while !isReleased {
            try Task.checkCancellation()
            await Task.yield()
        }
        return [:]
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {}

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {}
}

private actor ScheduledConcurrencyProbe {
    private var started: Set<String> = []
    private var released: Set<String> = []

    func begin(job: String) async throws {
        started.insert(job)
        while !released.contains(job) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func startedJobs() -> Set<String> { started }

    func release(job: String) {
        released.insert(job)
    }

    func releaseAll() {
        released.formUnion(started)
    }

    func waitForStartedJobCount(_ expectedCount: Int) async throws -> Set<String> {
        for _ in 0..<100 {
            if started.count == expectedCount { return started }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.transferFailed("Timed out waiting for \(expectedCount) scheduled jobs to start.")
    }
}

private struct ProbeEndpointSession: EndpointSession {
    let jobLabel: String
    let probe: ScheduledConcurrencyProbe

    func listFiles() async throws -> [String: SyncFile] {
        try await probe.begin(job: jobLabel)
        return [:]
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {}

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {}
}

final class JobTransferTotalsTests: XCTestCase {
    func testCountsTransfersPerJobAndAcrossJobs() {
        let firstJob = UUID()
        let secondJob = UUID()
        var totals = JobTransferTotals()

        totals.record(jobID: firstJob, fileCount: 2)
        totals.record(jobID: firstJob, fileCount: 3)
        totals.record(jobID: secondJob, fileCount: 4)

        XCTAssertEqual(totals.fileCount(jobID: firstJob, latestSessionOnly: false), 5)
        XCTAssertEqual(totals.fileCount(jobID: secondJob, latestSessionOnly: false), 4)
        XCTAssertEqual(totals.fileCount(jobID: firstJob, latestSessionOnly: true), 3)
        XCTAssertEqual(totals.fileCount(jobID: secondJob, latestSessionOnly: true), 4)
    }

    func testResetStartsANewJobSession() {
        let jobID = UUID()
        var totals = JobTransferTotals()

        totals.record(jobID: jobID, fileCount: 5)
        totals.reset(jobID: jobID)

        XCTAssertEqual(totals.fileCount(jobID: jobID, latestSessionOnly: false), 0)
        XCTAssertEqual(totals.fileCount(jobID: jobID, latestSessionOnly: true), 0)
    }

    func testLatestSessionCountCanReturnToZero() {
        let jobID = UUID()
        var totals = JobTransferTotals()

        totals.record(jobID: jobID, fileCount: 5)
        totals.record(jobID: jobID, fileCount: 0)

        XCTAssertEqual(totals.fileCount(jobID: jobID, latestSessionOnly: false), 5)
        XCTAssertEqual(totals.fileCount(jobID: jobID, latestSessionOnly: true), 0)
    }
}

final class SyncRetryPolicyTests: XCTestCase {
    func testRetryDelayUsesExponentialBackoffWithFiveMinuteCap() {
        XCTAssertEqual(SyncRetryPolicy.delay(baseInterval: 2, consecutiveFailures: 1), 2)
        XCTAssertEqual(SyncRetryPolicy.delay(baseInterval: 2, consecutiveFailures: 2), 4)
        XCTAssertEqual(SyncRetryPolicy.delay(baseInterval: 2, consecutiveFailures: 3), 8)
        XCTAssertEqual(SyncRetryPolicy.delay(baseInterval: 60, consecutiveFailures: 5), 300)
        XCTAssertEqual(SyncRetryPolicy.delay(baseInterval: 300, consecutiveFailures: 10), 300)
    }
}

final class SyncConcurrencyControllerTests: XCTestCase {
    func testGlobalLimitQueuesUntilAnActiveLeaseIsReleased() async throws {
        let controller = SyncConcurrencyController(
            policy: SyncConcurrencyPolicy(globalLimit: 1, perHostLimit: nil)
        )
        let firstLease = try await controller.acquire(hosts: [])
        let waitingTask = Task { try await controller.acquire(hosts: []) }

        try await waitForSnapshot(
            SyncConcurrencySnapshot(activeCount: 1, pendingCount: 1),
            from: controller
        )
        await controller.release(firstLease)
        let secondLease = try await waitingTask.value
        let admittedSnapshot = await controller.snapshot()
        XCTAssertEqual(admittedSnapshot, SyncConcurrencySnapshot(activeCount: 1, pendingCount: 0))
        await controller.release(secondLease)
    }

    func testPerHostLimitDoesNotBlockAnotherHost() async throws {
        let controller = SyncConcurrencyController(
            policy: SyncConcurrencyPolicy(globalLimit: 2, perHostLimit: 1)
        )
        let oslo = try XCTUnwrap(SyncRemoteHost(endpoint: Endpoint(
            kind: .sftp,
            host: " Photos.Example.com ",
            port: 22
        )))
        let normalizedOslo = try XCTUnwrap(SyncRemoteHost(endpoint: Endpoint(
            kind: .sftp,
            host: "photos.example.com",
            port: 22
        )))
        let bergen = try XCTUnwrap(SyncRemoteHost(endpoint: Endpoint(
            kind: .sftp,
            host: "bergen.example.com",
            port: 22
        )))
        XCTAssertEqual(oslo, normalizedOslo)

        let firstLease = try await controller.acquire(hosts: [oslo])
        let sameHostTask = Task { try await controller.acquire(hosts: [normalizedOslo]) }
        try await waitForSnapshot(
            SyncConcurrencySnapshot(activeCount: 1, pendingCount: 1),
            from: controller
        )

        let otherHostLease = try await controller.acquire(hosts: [bergen])
        let otherHostSnapshot = await controller.snapshot()
        XCTAssertEqual(otherHostSnapshot, SyncConcurrencySnapshot(activeCount: 2, pendingCount: 1))

        await controller.release(firstLease)
        let sameHostLease = try await sameHostTask.value
        await controller.release(otherHostLease)
        await controller.release(sameHostLease)
    }

    func testDisabledPerHostLimitAllowsParallelRunsForTheSameHost() async throws {
        let controller = SyncConcurrencyController(
            policy: SyncConcurrencyPolicy(globalLimit: 2, perHostLimit: nil)
        )
        let host = try XCTUnwrap(SyncRemoteHost(endpoint: Endpoint(
            kind: .ftp,
            host: "photos.example.com",
            port: 21
        )))

        let firstLease = try await controller.acquire(hosts: [host])
        let secondLease = try await controller.acquire(hosts: [host])
        let parallelSnapshot = await controller.snapshot()
        XCTAssertEqual(parallelSnapshot, SyncConcurrencySnapshot(activeCount: 2, pendingCount: 0))
        await controller.release(firstLease)
        await controller.release(secondLease)
    }

    func testCancellingAWaiterRemovesItFromTheQueue() async throws {
        let controller = SyncConcurrencyController(
            policy: SyncConcurrencyPolicy(globalLimit: 1, perHostLimit: nil)
        )
        let lease = try await controller.acquire(hosts: [])
        let waitingTask = Task { try await controller.acquire(hosts: []) }
        try await waitForSnapshot(
            SyncConcurrencySnapshot(activeCount: 1, pendingCount: 1),
            from: controller
        )

        waitingTask.cancel()
        do {
            _ = try await waitingTask.value
            XCTFail("A cancelled concurrency waiter should not receive a lease.")
        } catch is CancellationError {}
        let cancelledSnapshot = await controller.snapshot()
        XCTAssertEqual(cancelledSnapshot, SyncConcurrencySnapshot(activeCount: 1, pendingCount: 0))
        await controller.release(lease)
    }

    private func waitForSnapshot(
        _ expected: SyncConcurrencySnapshot,
        from controller: SyncConcurrencyController
    ) async throws {
        for _ in 0..<100 {
            if await controller.snapshot() == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for concurrency state \(expected).")
    }
}

final class SyncFailureRepositoryTests: XCTestCase {
    func testPersistsBoundsAndRemovesPerJobFailureHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-failures-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
        }
        let repository = SyncFailureRepository(fileURL: url, maximumEntries: 2)
        let firstJobID = UUID()
        let secondJobID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        try repository.append(SyncFailureRecord(
            jobID: firstJobID,
            occurredAt: baseDate,
            message: "First"
        ))
        try repository.append(SyncFailureRecord(
            jobID: firstJobID,
            occurredAt: baseDate.addingTimeInterval(1),
            message: "Second"
        ))
        try repository.append(SyncFailureRecord(
            jobID: secondJobID,
            occurredAt: baseDate.addingTimeInterval(2),
            message: "Third"
        ))

        XCTAssertEqual(try repository.loadResult().entries.map(\.message), ["Second", "Third"])
        XCTAssertEqual(try repository.remove(jobID: firstJobID).map(\.message), ["Third"])
    }
}

@MainActor
final class AppStorePersistenceTests: XCTestCase {
    func testFailedAddDoesNotPublishTheNewJob() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-add-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(
            repository: JobRepository(fileURL: URL(fileURLWithPath: "/dev/null/jobs.json")),
            root: root
        )

        _ = store.addJob()

        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertNil(store.selectedJobID)
        XCTAssertNotNil(store.alertMessage)
    }

    func testFailedSaveDoesNotPublishTheDraftJob() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = JobRepository(fileURL: URL(fileURLWithPath: "/dev/null/jobs.json"))
        let store = makeStore(repository: repository, root: root)
        let bookmark = Data([1])
        let job = SyncJob(
            name: "Unsaved",
            left: Endpoint(kind: .local, localPath: "/source", bookmark: bookmark),
            right: Endpoint(kind: .local, localPath: "/target", bookmark: bookmark),
            direction: .leftToRight,
            intervalSeconds: 5,
            isEnabled: false
        )

        XCTAssertFalse(store.saveJob(job, leftPassword: "", rightPassword: ""))
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertNotNil(store.alertMessage)
    }

    func testPasswordReadFailureIsReturnedToTheEditor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("password-read-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let endpoint = Endpoint(kind: .ftps, host: "photos.example.com", username: "desk")
        let keychain = KeychainStore(
            passwordReader: { _ in throw AppError.transferFailed("Injected Keychain read failure.") },
            passwordWriter: { _, _ in },
            passwordRemover: { _ in }
        )
        let store = makeStore(repository: repository, root: root, keychain: keychain)

        XCTAssertThrowsError(try store.password(for: endpoint)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Injected Keychain read failure"))
        }
    }

    func testFailedEnableDoesNotPublishOrScheduleTheChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-enable-\(UUID().uuidString)", isDirectory: true)
        let persistenceDirectory = root.appendingPathComponent("store", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: persistenceDirectory, withIntermediateDirectories: true)
        let repository = JobRepository(fileURL: persistenceDirectory.appendingPathComponent("jobs.json"))
        var job = SyncJob(name: "Stay disabled")
        job.isEnabled = false
        job.startsOnAppLaunch = false
        try repository.save([job])
        let store = makeStore(repository: repository, root: root)
        let jobID = try XCTUnwrap(store.jobs.first?.id)
        try FileManager.default.removeItem(at: persistenceDirectory)
        try Data("blocks directory recreation".utf8).write(to: persistenceDirectory)

        store.setEnabled(true, for: jobID)

        XCTAssertFalse(try XCTUnwrap(store.jobs.first).isEnabled)
        XCTAssertFalse(store.isJobBusy(jobID))
        XCTAssertNotNil(store.alertMessage)
    }

    func testFailedDeleteKeepsTheJobPublished() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-delete-\(UUID().uuidString)", isDirectory: true)
        let persistenceDirectory = root.appendingPathComponent("store", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: persistenceDirectory, withIntermediateDirectories: true)
        let repository = JobRepository(fileURL: persistenceDirectory.appendingPathComponent("jobs.json"))
        var job = SyncJob(name: "Must survive")
        job.isEnabled = false
        job.startsOnAppLaunch = false
        try repository.save([job])
        let store = makeStore(repository: repository, root: root)
        let jobID = try XCTUnwrap(store.jobs.first?.id)
        try FileManager.default.removeItem(at: persistenceDirectory)
        try Data("blocks directory recreation".utf8).write(to: persistenceDirectory)

        store.removeJob(jobID)

        XCTAssertEqual(store.jobs.map(\.id), [jobID])
        XCTAssertEqual(store.selectedJobID, jobID)
        XCTAssertTrue(store.alertMessage?.contains("could not be deleted") == true)
    }

    func testRecoveredJobsRemainPausedForReview() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("store-recovery-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
        }
        let repository = JobRepository(fileURL: url)
        var recoverableJob = SyncJob(name: "Recovered")
        recoverableJob.startsOnAppLaunch = true
        recoverableJob.isEnabled = true
        try repository.save([recoverableJob])
        try repository.save([SyncJob(name: "Newer state")])
        try Data("not valid JSON".utf8).write(to: url, options: .atomic)

        let store = AppStore(repository: repository)

        XCTAssertEqual(store.jobs.map(\.name), ["Recovered"])
        XCTAssertFalse(try XCTUnwrap(store.jobs.first).isEnabled)
        XCTAssertNotNil(store.alertMessage)
    }

    func testMetadataPresetsPersistAcrossAppStoreInstances() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let presetRepository = MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json"))
        let preset = MetadataPreset(
            name: "  Election  ",
            fields: ScheduledMetadataFields(keywords: [" politics ", "POLITICS", "Oslo"])
        )

        let firstStore = AppStore(
            repository: jobRepository,
            metadataPresetRepository: presetRepository
        )
        XCTAssertTrue(firstStore.saveMetadataPreset(preset))

        let secondStore = AppStore(
            repository: jobRepository,
            metadataPresetRepository: presetRepository
        )
        XCTAssertEqual(secondStore.metadataPresets.count, 1)
        XCTAssertEqual(secondStore.metadataPresets[0].name, "Election")
        XCTAssertEqual(secondStore.metadataPresets[0].fields.keywords, ["politics", "Oslo"])
    }

    func testFailedPresetSaveDoesNotPublishTheDraft() {
        let jobURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-failure-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jobURL) }
        let store = AppStore(
            repository: JobRepository(fileURL: jobURL),
            metadataPresetRepository: MetadataPresetRepository(
                fileURL: URL(fileURLWithPath: "/dev/null/presets.json")
            )
        )

        XCTAssertFalse(store.saveMetadataPreset(MetadataPreset(name: "Unsaved")))
        XCTAssertTrue(store.metadataPresets.isEmpty)
        XCTAssertNotNil(store.alertMessage)
    }

    private func makeStore(
        repository: JobRepository,
        root: URL,
        keychain: KeychainStore = KeychainStore()
    ) -> AppStore {
        AppStore(
            repository: repository,
            metadataPresetRepository: MetadataPresetRepository(
                fileURL: root.appendingPathComponent("presets.json")
            ),
            photographerProfileRepository: PhotographerProfileRepository(
                fileURL: root.appendingPathComponent("photographers.json")
            ),
            metadataAuditRepository: MetadataAuditRepository(
                fileURL: root.appendingPathComponent("audit.json")
            ),
            syncFailureRepository: SyncFailureRepository(
                fileURL: root.appendingPathComponent("failures.json")
            ),
            sourceSignatureRepository: SourceSignatureRepository(
                fileURL: root.appendingPathComponent("signatures.json")
            ),
            keychain: keychain
        )
    }
}
