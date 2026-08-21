import Foundation
import XCTest
@testable import AagedalFTPSync

final class SyncJobValidationTests: XCTestCase {
    func testCleanupAcceptsOneWayLocalTargetWithLongerRetention() {
        var job = validJob(direction: .leftToRight)
        job.filter.recentHours = 1
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertNil(job.validationMessage)
    }

    func testCleanupRejectsTwoWayJobs() {
        var job = validJob(direction: .bidirectional)
        job.filter.recentHours = 1
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Automatic cleanup is only available for one-way jobs.")
    }

    func testCleanupRequiresLocalTarget() {
        var job = validJob(direction: .rightToLeft)
        job.filter.recentHours = 1
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Automatic cleanup is only available when the target is a local folder.")
    }

    func testCleanupRequiresSourceAgeWindow() {
        var job = validJob(direction: .leftToRight)
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Choose a source file-age window before enabling automatic cleanup.")
    }

    func testCleanupMustBeOlderThanSourceWindow() {
        var job = validJob(direction: .leftToRight)
        job.filter.recentHours = 2
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "The cleanup age must be greater than the source file-age window.")
    }

    func testCleanupRejectsOverlappingLocalFolders() {
        let bookmark = Data([1])
        var job = SyncJob(
            name: "Test",
            left: Endpoint(kind: .local, localPath: "/Pictures", bookmark: bookmark),
            right: Endpoint(kind: .local, localPath: "/Pictures/target", bookmark: bookmark),
            direction: .leftToRight,
            filter: FileFilter(preset: .photos, recentHours: 1),
            intervalSeconds: 5,
            isEnabled: false
        )
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Source and target folders must not overlap when cleanup is enabled.")
    }

    private func validJob(direction: SyncDirection) -> SyncJob {
        let remote = Endpoint(
            kind: .sftp,
            host: "photos.example.com",
            username: "desk",
            remotePath: "/incoming"
        )
        let local = Endpoint(
            kind: .local,
            localPath: "/Users/example/Pictures",
            bookmark: Data([1])
        )
        return SyncJob(
            name: "Test",
            left: remote,
            right: local,
            direction: direction,
            intervalSeconds: 5,
            isEnabled: false
        )
    }
}
