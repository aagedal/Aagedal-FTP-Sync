import Foundation
import XCTest
@testable import AagedalFTPSync

final class JobRepositoryTests: XCTestCase {
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

@MainActor
final class AppStorePersistenceTests: XCTestCase {
    func testFailedSaveDoesNotPublishTheDraftJob() {
        let repository = JobRepository(fileURL: URL(fileURLWithPath: "/dev/null/jobs.json"))
        let store = AppStore(repository: repository)
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
}
