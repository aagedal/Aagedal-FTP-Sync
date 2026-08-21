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
}

final class JobTransferTotalsTests: XCTestCase {
    func testCountsTransfersPerJobAndAcrossJobs() {
        let firstJob = UUID()
        let secondJob = UUID()
        var totals = JobTransferTotals()

        totals.record(jobID: firstJob, fileCount: 2)
        totals.record(jobID: firstJob, fileCount: 3)
        totals.record(jobID: secondJob, fileCount: 4)

        XCTAssertEqual(totals.fileCount(jobID: firstJob), 5)
        XCTAssertEqual(totals.fileCount(jobID: secondJob), 4)
        XCTAssertEqual(totals.fileCount(), 9)
    }

    func testResetStartsANewJobSession() {
        let jobID = UUID()
        var totals = JobTransferTotals()

        totals.record(jobID: jobID, fileCount: 5)
        totals.reset(jobID: jobID)

        XCTAssertEqual(totals.fileCount(jobID: jobID), 0)
        XCTAssertEqual(totals.fileCount(), 0)
    }
}
