import Foundation
import SQLite3
import XCTest
@testable import AagedalFTPSync

final class SourceSignatureSnapshotTests: XCTestCase {
    private let endpoint = Endpoint(kind: .ftp, host: "snapshot.invalid", username: "fixture")
    private let file = SyncFile(relativePath: "image.jpg", size: 123, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("signature-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            XCTFail(String(cString: sqlite3_errmsg(connection)))
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func scalar(_ sql: String, at url: URL) throws -> String {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(query, 0)))
    }

    private func assertNoStages(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".source-signature-snapshot-") }, file: file, line: line)
    }

    func testSnapshotIncludesCommittedWALAndLeavesSourceBytesAndFutureWritesIntact() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        let output = root.appendingPathComponent("snapshot.sqlite3")
        let repository = SourceSignatureRepository(fileURL: source)
        let jobID = UUID()
        try await repository.record(file, jobID: jobID, sourceEndpoint: endpoint)
        // Commit through a separate connection while the actor-owned handle stays
        // open. The backup must include these WAL records without a checkpoint.
        try execute("UPDATE source_signatures SET size = 456", at: source)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let sourceBefore = try Data(contentsOf: source)
        let walBefore = try Data(contentsOf: wal)
        XCTAssertFalse(walBefore.isEmpty)
        let receipt = try await repository.snapshot(to: output)
        XCTAssertEqual(receipt.schemaVersion, 2)
        XCTAssertEqual(receipt.recordCount, 1)
        XCTAssertEqual(receipt.byteCount, Int64(try Data(contentsOf: output).count))
        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        XCTAssertEqual(try scalar("SELECT size FROM source_signatures", at: output), "456")
        XCTAssertEqual(try scalar("PRAGMA integrity_check", at: output), "ok")
        XCTAssertEqual(try scalar("PRAGMA journal_mode", at: output), "delete")
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + suffix))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try await repository.record(file, jobID: jobID, sourceEndpoint: endpoint)
        let restored = try await repository.signature(jobID: jobID, sourceEndpoint: endpoint, relativePath: file.relativePath)
        XCTAssertEqual(restored?.size, 123)
        XCTAssertEqual(try scalar("SELECT size FROM source_signatures", at: output), "456")
        try assertNoStages(in: root)
    }

    func testClosedRepositoryDoesNotOpenCreateOrMigrateLegacyData() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.json")
        let original = Data("[]".utf8)
        try original.write(to: source)
        let repository = SourceSignatureRepository(fileURL: source)
        do {
            _ = try await repository.snapshot(to: root.appendingPathComponent("snapshot.sqlite3"))
            XCTFail("Must not implicitly migrate legacy storage")
        } catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .databaseNotOpen) }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["legacy.json"])
    }

    func testExistingFileSourceHardLinkAndCompanionsAreNeverOverwritten() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        let repository = SourceSignatureRepository(fileURL: source)
        try await repository.record(file, jobID: UUID(), sourceEndpoint: endpoint)
        let sentinel = root.appendingPathComponent("sentinel.sqlite3")
        let bytes = Data("must survive".utf8)
        try bytes.write(to: sentinel)
        let hardLink = root.appendingPathComponent("hard.sqlite3")
        try FileManager.default.linkItem(at: source, to: hardLink)
        let output = root.appendingPathComponent("snapshot.sqlite3")
        let companion = URL(fileURLWithPath: output.path + "-journal")
        try bytes.write(to: companion)
        for target in [source, sentinel, hardLink, output] {
            do { _ = try await repository.snapshot(to: target); XCTFail("Existing path must fail") }
            catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .destinationExists) }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try Data(contentsOf: companion), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStages(in: root)
    }

    func testSymlinkParentsAndFilesAndNonFileURLsAreRejected() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SourceSignatureRepository(fileURL: root.appendingPathComponent("source.sqlite3"))
        try await repository.record(file, jobID: UUID(), sourceEndpoint: endpoint)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let brokenLink = root.appendingPathComponent("broken.sqlite3")
        try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: root.appendingPathComponent("absent"))
        let targets: [(URL, SourceSignatureRepository.SnapshotError)] = [
            (link.appendingPathComponent("out.sqlite3"), .unsafeDestination),
            (brokenLink, .destinationExists),
            (try XCTUnwrap(URL(string: "https://snapshot.invalid/database")), .unsafeDestination),
            (root.appendingPathComponent("missing/out.sqlite3"), .unsafeDestination)
        ]
        for (target, expected) in targets {
            do { _ = try await repository.snapshot(to: target); XCTFail("Unsafe path must fail") }
            catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, expected) }
        }
        try assertNoStages(in: root)
    }

    func testByteLimitAndDeadlineFailuresCleanOnlyOwnedStageAndLeaveRepositoryUsable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SourceSignatureRepository(fileURL: root.appendingPathComponent("source.sqlite3"))
        let jobID = UUID()
        try await repository.record(file, jobID: jobID, sourceEndpoint: endpoint)
        let unrelated = root.appendingPathComponent(".source-signature-snapshot-unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let sentinel = unrelated.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let output = root.appendingPathComponent("snapshot.sqlite3")
        do { _ = try await repository.snapshot(to: output, maximumBytes: 1); XCTFail("Byte cap must fail") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .sizeLimitExceeded) }
        do { _ = try await repository.snapshot(to: output, timeout: .leastNonzeroMagnitude); XCTFail("Deadline must fail") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .deadlineExceeded) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".source-signature-snapshot-") }, [unrelated.lastPathComponent])
        let restored = try await repository.signature(jobID: jobID, sourceEndpoint: endpoint, relativePath: file.relativePath)
        XCTAssertEqual(restored, SourceFileSignature(file: file))
        _ = try await repository.snapshot(to: output)
    }

    func testCancelledTaskDoesNotPublishAndRepositoryRemainsUsable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SourceSignatureRepository(fileURL: root.appendingPathComponent("source.sqlite3"))
        let jobID = UUID()
        try await repository.record(file, jobID: jobID, sourceEndpoint: endpoint)
        let output = root.appendingPathComponent("snapshot.sqlite3")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await repository.snapshot(to: output)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStages(in: root)
        let receipt = try await repository.snapshot(to: output)
        XCTAssertEqual(receipt.recordCount, 1)
        try await repository.record(file, jobID: jobID, sourceEndpoint: endpoint)
    }

    func testEmptyInitializedRepositoryProducesValidStandaloneSnapshot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SourceSignatureRepository(fileURL: root.appendingPathComponent("source.sqlite3"))
        let missing = try await repository.signature(jobID: UUID(), sourceEndpoint: endpoint, relativePath: file.relativePath)
        XCTAssertNil(missing)
        let output = root.appendingPathComponent("snapshot.sqlite3")
        let receipt = try await repository.snapshot(to: output)
        XCTAssertEqual(receipt.recordCount, 0)
        XCTAssertEqual(try scalar("PRAGMA integrity_check", at: output), "ok")
    }

    func testInvalidOptionsAreRejectedWithoutArtifacts() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SourceSignatureRepository(fileURL: root.appendingPathComponent("source.sqlite3"))
        for timeout: TimeInterval in [0, -1, .nan, .infinity, 61] {
            do { _ = try await repository.snapshot(to: root.appendingPathComponent("out"), timeout: timeout); XCTFail() }
            catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .invalidOptions) }
        }
        do { _ = try await repository.snapshot(to: root.appendingPathComponent("out"), maximumBytes: 0); XCTFail() }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .invalidOptions) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testFutureVersionAndWrongColumnSchemaFailWithoutPublishing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        let repository = SourceSignatureRepository(fileURL: source)
        try await repository.record(file, jobID: UUID(), sourceEndpoint: endpoint)
        let output = root.appendingPathComponent("snapshot.sqlite3")
        try execute("PRAGMA user_version = 99", at: source)
        do { _ = try await repository.snapshot(to: output); XCTFail("Future schema must fail") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .invalidSnapshot) }
        XCTAssertEqual(try scalar("PRAGMA user_version", at: source), "99")
        try execute("PRAGMA user_version = 2; ALTER TABLE source_signatures ADD COLUMN future TEXT", at: source)
        do { _ = try await repository.snapshot(to: output); XCTFail("Unknown columns must fail") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.SnapshotError, .invalidSnapshot) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStages(in: root)
    }
}
