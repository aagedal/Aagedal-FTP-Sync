import Foundation
import XCTest
@testable import AagedalFTPSync

final class LocalSyncIntegrationTests: XCTestCase {
    func testOneWaySyncCopiesDataAndModificationDate() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("selects/NEWS_001.CR3")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("camera-data".utf8).write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)

        let result = try await SyncEngine().run(job: fixture.job(direction: .leftToRight), leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 1, deleted: 0))
        let destination = fixture.right.appendingPathComponent("selects/NEWS_001.CR3")
        XCTAssertEqual(try Data(contentsOf: destination), Data("camera-data".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 1)
    }

    func testOneWaySyncDoesNotTransferAnUnchangedFileAgain() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("NEWS_001.jpg")
        try Data("camera-data".utf8).write(to: source)
        let job = try fixture.job(direction: .leftToRight)

        let firstResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
        let secondResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(firstResult, SyncResult(transferred: 1, deleted: 0))
        XCTAssertEqual(secondResult, SyncResult(transferred: 0, deleted: 0))
    }

    func testTwoWaySyncCopiesUniqueFilesInBothDirections() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        try Data("left".utf8).write(to: fixture.left.appendingPathComponent("left.jpg"))
        try Data("right".utf8).write(to: fixture.right.appendingPathComponent("right.nef"))

        let result = try await SyncEngine().run(job: fixture.job(direction: .bidirectional), leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 2, deleted: 0))
        XCTAssertEqual(try Data(contentsOf: fixture.right.appendingPathComponent("left.jpg")), Data("left".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.left.appendingPathComponent("right.nef")), Data("right".utf8))
    }

    func testCleanupDeletesOnlyOldMatchingFilesFromTarget() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let now = Date()
        let oldDate = now.addingTimeInterval(-3 * 3_600)
        let recentDate = now.addingTimeInterval(-30 * 60)
        let oldSource = fixture.left.appendingPathComponent("source-old.jpg")
        let recentSource = fixture.left.appendingPathComponent("source-new.jpg")
        let oldTarget = fixture.right.appendingPathComponent("target-old.jpg")
        let oldNonMatchingTarget = fixture.right.appendingPathComponent("keep-old.txt")
        let recentTarget = fixture.right.appendingPathComponent("keep-new.jpg")

        for url in [oldSource, recentSource, oldTarget, oldNonMatchingTarget, recentTarget] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        for url in [oldSource, oldTarget, oldNonMatchingTarget] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        for url in [recentSource, recentTarget] {
            try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: url.path)
        }

        var job = try fixture.job(direction: .leftToRight)
        job.filter = FileFilter(preset: .photos, recentHours: 1)
        job.targetCleanup = TargetCleanup(olderThanHours: 2)
        let result = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 1, deleted: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSource.path), "Cleanup must never touch the source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.right.appendingPathComponent("source-new.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldNonMatchingTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentTarget.path))
    }
}

private final class LocalFixture {
    let root: URL
    let left: URL
    let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AagedalSyncTests-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    func job(direction: SyncDirection) throws -> SyncJob {
        let leftEndpoint = try endpoint(for: left)
        let rightEndpoint = try endpoint(for: right)
        return SyncJob(
            name: "Test",
            left: leftEndpoint,
            right: rightEndpoint,
            direction: direction,
            filter: FileFilter(preset: .photos),
            intervalSeconds: 5,
            isEnabled: false
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private func endpoint(for url: URL) throws -> Endpoint {
        let bookmark = try FolderBookmark.create(for: url)
        return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
    }
}
