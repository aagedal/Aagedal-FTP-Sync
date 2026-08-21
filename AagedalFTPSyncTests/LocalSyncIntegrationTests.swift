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

        let transferred = try await SyncEngine().run(job: fixture.job(direction: .leftToRight), leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(transferred, 1)
        let destination = fixture.right.appendingPathComponent("selects/NEWS_001.CR3")
        XCTAssertEqual(try Data(contentsOf: destination), Data("camera-data".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 1)
    }

    func testTwoWaySyncCopiesUniqueFilesInBothDirections() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        try Data("left".utf8).write(to: fixture.left.appendingPathComponent("left.jpg"))
        try Data("right".utf8).write(to: fixture.right.appendingPathComponent("right.nef"))

        let transferred = try await SyncEngine().run(job: fixture.job(direction: .bidirectional), leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(transferred, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.right.appendingPathComponent("left.jpg")), Data("left".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.left.appendingPathComponent("right.nef")), Data("right".utf8))
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
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return Endpoint(kind: .local, localPath: url.path, bookmark: bookmark)
    }
}
