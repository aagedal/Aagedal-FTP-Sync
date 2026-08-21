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
        var second = SyncJob(name: "Desk two")
        second.filter.preset = .raw

        try repository.save([first, second])

        let loaded = try repository.load()
        XCTAssertEqual(loaded, [first, second])
    }
}
