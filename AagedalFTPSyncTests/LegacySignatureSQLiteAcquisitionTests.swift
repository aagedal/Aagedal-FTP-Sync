import Foundation
import SQLite3
import XCTest
@testable import AagedalFTPSync

final class LegacySignatureSQLiteAcquisitionTests: XCTestCase {
    private typealias Acquisition = LegacySignatureSQLiteAcquisition
    private final class Connection {
        let handle: OpaquePointer
        init(_ url: URL) throws {
            var pointer: OpaquePointer?
            let code = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            guard code == SQLITE_OK, let pointer else { throw CocoaError(.fileWriteUnknown) }
            handle = pointer
        }
        deinit { sqlite3_close(handle) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("signature-acquisition-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func fixture(_ url: URL, wal: Bool = false, altered: String = "") throws -> Connection {
        let connection = try Connection(url)
        try connection.execute(SourceSignatureRepository.version3TableSQL + ";" + SourceSignatureRepository.version3IndexSQL + ";PRAGMA user_version = 2")
        if wal { try connection.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0") }
        try connection.execute("INSERT INTO source_signatures VALUES ('AE5B40F5-6C9C-4FDC-89C8-B9D802DB20C1','5:local8:/fixture0:1:00:0:','東京\\photo.jpg',9223372036854775806,-123456.125,1700000000.875)")
        if !altered.isEmpty { try connection.execute(altered) }
        return connection
    }
    private func allBytes(_ url: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: path.path) { files[suffix] = try Data(contentsOf: path) }
        }
        return files
    }
    private func noStages(_ root: URL) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".signature-acquisition-") })
    }
    func testCommittedWALOnlyRowCapturedAndEveryOriginalByteUnchanged() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.sqlite3")
        let connection = try fixture(url, wal: true)
        defer { withExtendedLifetime(connection) {} }
        let original = try allBytes(url)
        XCTAssertNotNil(original["-wal"]); XCTAssertNotNil(original["-shm"])
        // The retained main alone has zero rows; this proves the row is WAL-only.
        let mainOnly = root.appendingPathComponent("main-only.sqlite3")
        try XCTUnwrap(original[""]).write(to: mainOnly)
        let alone = try Acquisition.acquire(sourceURL: mainOnly, temporaryDirectory: root)
        XCTAssertEqual(alone.recordCount, 0)
        let output = try Acquisition.acquire(sourceURL: url, temporaryDirectory: root)
        XCTAssertEqual(output.recordCount, 1)
        XCTAssertEqual(output.main.data, original[""])
        XCTAssertEqual(output.wal?.data, original["-wal"])
        XCTAssertEqual(output.shm?.data, original["-shm"])
        XCTAssertEqual(output.main.identity.sha256.count, 64)
        XCTAssertEqual(output.data[18], 1); XCTAssertEqual(output.data[19], 1)
        let converted = try Version3SignatureConversion.convert(.standaloneSnapshot(output.data), temporaryDirectory: root)
        XCTAssertEqual(converted.recordCount, 1)
        XCTAssertEqual(converted.referencedJobIDs, [UUID(uuidString: "AE5B40F5-6C9C-4FDC-89C8-B9D802DB20C1")!])
        XCTAssertEqual(try allBytes(url), original)
        try noStages(root)
    }
    func testWALWithoutSHMRebuildsOnlyPrivateCoordination() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("fixture.sqlite3")
        let connection = try fixture(originalURL, wal: true)
        defer { withExtendedLifetime(connection) {} }
        let bytes = try allBytes(originalURL)
        let source = root.appendingPathComponent("closed-crash-copy.sqlite3")
        try XCTUnwrap(bytes[""]).write(to: source)
        try XCTUnwrap(bytes["-wal"]).write(to: URL(fileURLWithPath: source.path + "-wal"))
        let before = try allBytes(source)
        let output = try Acquisition.acquire(sourceURL: source, temporaryDirectory: root)
        XCTAssertEqual(output.recordCount, 1); XCTAssertNil(output.shm)
        XCTAssertEqual(try allBytes(source), before)
        try noStages(root)
    }
    func testStandaloneAndEngineStatisticsRemainValid() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.sqlite3")
        do { let connection = try fixture(url, altered: "ANALYZE"); withExtendedLifetime(connection) {} }
        let original = try allBytes(url)
        let output = try Acquisition.acquire(sourceURL: url, temporaryDirectory: root)
        XCTAssertEqual(output.recordCount, 1); XCTAssertNil(output.wal)
        XCTAssertEqual(try allBytes(url), original)
        XCTAssertEqual(try Version3SignatureConversion.convert(.standaloneSnapshot(output.data), temporaryDirectory: root).recordCount, 1)
    }
    func testFutureWrongIdentityAndAdditionalSchemaRejectWithoutOriginalChanges() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for sql in ["PRAGMA user_version = 4", "PRAGMA application_id = 77", "CREATE TABLE surprise(value)"] {
            let url = root.appendingPathComponent("source-\(UUID().uuidString).sqlite3")
            let connection = try fixture(url, wal: true, altered: sql)
            let before = try allBytes(url)
            XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root))
            XCTAssertEqual(try allBytes(url), before)
            withExtendedLifetime(connection) {}
        }
        try noStages(root)
    }
    func testJournalUnsafeCompanionsAndSymlinkPathsReject() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.sqlite3")
        do { let connection = try fixture(url); withExtendedLifetime(connection) {} }
        let journal = URL(fileURLWithPath: url.path + "-journal")
        try Data([0xd9, 0xd5, 0x05, 0xf9]).write(to: journal)
        let before = try allBytes(url)
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root)) { XCTAssertEqual($0 as? Acquisition.Failure, .unsupportedCompanions) }
        XCTAssertEqual(try allBytes(url), before)
        try FileManager.default.removeItem(at: journal)
        let link = root.appendingPathComponent("link.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: link, temporaryDirectory: root))
        let directoryLink = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: directoryLink.appendingPathComponent("source.sqlite3"), temporaryDirectory: root))
        try FileManager.default.createSymbolicLink(atPath: url.path + "-wal", withDestinationPath: url.path)
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root))
        try noStages(root)
    }
    func testCorruptAndPartialWALCannotSilentlyLoseCommittedEvidence() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.sqlite3")
        let connection = try fixture(url, wal: true)
        defer { withExtendedLifetime(connection) {} }
        let original = try allBytes(url)
        let wal = try XCTUnwrap(original["-wal"])
        var corrupt = wal; corrupt[corrupt.count - 1] ^= 1
        for invalid in [Data(wal.dropLast()), corrupt, Data([1, 2, 3])] {
            let source = root.appendingPathComponent("invalid-\(UUID().uuidString).sqlite3")
            try XCTUnwrap(original[""]).write(to: source)
            try invalid.write(to: URL(fileURLWithPath: source.path + "-wal"))
            let before = try allBytes(source)
            XCTAssertThrowsError(try Acquisition.acquire(sourceURL: source, temporaryDirectory: root)) { XCTAssertEqual($0 as? Acquisition.Failure, .invalidWAL) }
            XCTAssertEqual(try allBytes(source), before)
        }
        try noStages(root)
    }
    func testMissingMalformedLimitsRecordsAndDeadlineCleanOnlyOwnStage() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.sqlite3")
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root)) { XCTAssertEqual($0 as? Acquisition.Failure, .missingSource) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        do { let connection = try fixture(url); withExtendedLifetime(connection) {} }
        let original = try allBytes(url)
        var limits = Acquisition.Limits(); limits.maximumRecords = 0
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root, limits: limits)) { XCTAssertEqual($0 as? Acquisition.Failure, .recordLimit) }
        limits = Acquisition.Limits(); limits.maximumBytes = 4096
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root, limits: limits)) { XCTAssertEqual($0 as? Acquisition.Failure, .byteLimit) }
        limits = Acquisition.Limits(); limits.timeout = .leastNonzeroMagnitude
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root, limits: limits)) { XCTAssertEqual($0 as? Acquisition.Failure, .deadlineExceeded) }
        limits.timeout = .infinity
        XCTAssertThrowsError(try Acquisition.acquire(sourceURL: url, temporaryDirectory: root, limits: limits)) { XCTAssertEqual($0 as? Acquisition.Failure, .invalidLimits) }
        XCTAssertEqual(try allBytes(url), original)
        try noStages(root)
    }
    func testAlreadyCancelledTaskLeavesOriginalAndDirectoryUntouched() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.sqlite3")
        do { let connection = try fixture(url); withExtendedLifetime(connection) {} }
        let original = try allBytes(url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Acquisition.acquire(sourceURL: url, temporaryDirectory: root)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try allBytes(url), original)
        try noStages(root)
    }
}
