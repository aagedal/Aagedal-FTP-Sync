import Foundation
import SQLite3
import XCTest
@testable import AagedalFTPSync

final class SourceSignatureVersion3Tests: XCTestCase {
    private let endpoint = Endpoint(kind: .ftp, host: "fixture.invalid", username: "fixture")
    private let file = SyncFile(relativePath: "image.jpg", size: 123, modifiedAt: Date(timeIntervalSince1970: 100))

    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ url: URL) throws {
            var value: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &value, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            guard result == SQLITE_OK, let value else {
                if let value { sqlite3_close(value) }
                throw CocoaError(.fileWriteUnknown)
            }
            pointer = value
        }
        deinit { sqlite3_close(pointer) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else {
                XCTFail(String(cString: sqlite3_errmsg(pointer)))
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
    private func fixture() throws -> AppStorageLayout {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("signature-v3-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return AppStorageLayout(root: root, storageFormat: .version3)
    }
    private func initialize(_ layout: AppStorageLayout, sql: String = SourceSignatureRepository.version3InitializationSQL) throws {
        let connection = try Connection(layout.sourceSignatures)
        try connection.execute(sql)
    }
    private func lookup(_ repository: SourceSignatureRepository) async throws {
        _ = try await repository.signature(jobID: UUID(), sourceEndpoint: endpoint, relativePath: file.relativePath)
    }
    private func scalar(_ sql: String, at url: URL) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return sqlite3_column_int64(query, 0)
    }
    private func assertRejected(_ layout: AppStorageLayout, expected: SourceSignatureRepository.Version3OpenError) async throws {
        let before = try Data(contentsOf: layout.sourceSignatures)
        do { try await lookup(SourceSignatureRepository(storage: layout)); XCTFail("Must reject incompatible v3 store") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, expected) }
        XCTAssertEqual(try Data(contentsOf: layout.sourceSignatures), before)
    }

    func testMissingV3DatabaseNeverCreatesParentOrUsesLegacyBackups() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let legacy = Data("[]".utf8)
        try legacy.write(to: layout.legacySourceSignatures)
        try legacy.write(to: layout.sourceSignatures.appendingPathExtension("pre-sqlite-backup"))
        let before = try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted()
        do { try await lookup(SourceSignatureRepository(storage: layout)); XCTFail("Must not migrate") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .missingDatabase) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted(), before)
        let absentRoot = AppStorageLayout(root: layout.root.appendingPathComponent("absent"), storageFormat: .version3)
        do { try await lookup(SourceSignatureRepository(storage: absentRoot)); XCTFail("Must not initialize") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .missingDatabase) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentRoot.root.path))
    }

    func testEmptyOperationsStillRejectMissingVersion3Store() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let repository = SourceSignatureRepository(storage: layout)
        do { try await repository.record([], jobID: UUID(), sourceEndpoint: endpoint); XCTFail("Empty write still requires admission") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .missingDatabase) }
        do {
            _ = try await repository.signatures(jobID: UUID(), sourceEndpoint: endpoint, relativePaths: [String]())
            XCTFail("Empty lookup still requires admission")
        } catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .missingDatabase) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).isEmpty)
    }

    func testJSONAndCorruptDatabaseNeverMigrateOrReplaceInVersion3Mode() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        for bytes in [Data("[]".utf8), Data("broken sqlite".utf8), Data()] {
            try bytes.write(to: layout.sourceSignatures)
            do { try await lookup(SourceSignatureRepository(storage: layout)); XCTFail("Must not repair") }
            catch { XCTAssertNotNil(error as? SourceSignatureRepository.Version3OpenError) }
            XCTAssertEqual(try Data(contentsOf: layout.sourceSignatures), bytes)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.root.path), [layout.sourceSignatures.lastPathComponent])
    }

    func testIdentityAndFutureSchemaRejectWithoutMutation() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try initialize(layout)
        do {
            let connection = try Connection(layout.sourceSignatures)
            try connection.execute("PRAGMA user_version = 99")
        }
        try await assertRejected(layout, expected: .unsupportedSchemaVersion(99))
        XCTAssertEqual(try scalar("PRAGMA user_version", at: layout.sourceSignatures), 99)
        do {
            let connection = try Connection(layout.sourceSignatures)
            try connection.execute("PRAGMA user_version = 3; PRAGMA application_id = 0")
        }
        try await assertRejected(layout, expected: .applicationIDMismatch(0))
    }

    func testVersion2RequiresExplicitConversionAndKeepsHeader() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let legacy = SourceSignatureRepository(fileURL: layout.sourceSignatures)
        try await legacy.record(file, jobID: UUID(), sourceEndpoint: endpoint)
        let before = try Data(contentsOf: layout.sourceSignatures)
        let wal = URL(fileURLWithPath: layout.sourceSignatures.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        do { try await lookup(SourceSignatureRepository(storage: layout)); XCTFail("Must not mark v2 as v3") }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .applicationIDMismatch(0)) }
        XCTAssertEqual(try Data(contentsOf: layout.sourceSignatures), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        XCTAssertEqual(try scalar("PRAGMA user_version", at: layout.sourceSignatures), 2)
        withExtendedLifetime(legacy) {}
    }

    func testFutureSchemaCommittedOnlyInWALIsRejectedAndWALPreserved() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try initialize(layout)
        let connection = try Connection(layout.sourceSignatures)
        try connection.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; PRAGMA user_version = 99")
        let mainBefore = try Data(contentsOf: layout.sourceSignatures)
        let wal = URL(fileURLWithPath: layout.sourceSignatures.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        XCTAssertFalse(walBefore.isEmpty)
        try await assertRejected(layout, expected: .unsupportedSchemaVersion(99))
        XCTAssertEqual(try Data(contentsOf: layout.sourceSignatures), mainBefore)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        withExtendedLifetime(connection) {}
    }

    func testIncompatibleSchemaCommittedInWALRetainsMainAndWALBytes() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try initialize(layout)
        let connection = try Connection(layout.sourceSignatures)
        try connection.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; CREATE INDEX extra ON source_signatures(size)")
        let wal = URL(fileURLWithPath: layout.sourceSignatures.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        XCTAssertFalse(walBefore.isEmpty)
        try await assertRejected(layout, expected: .incompatibleSchema)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        withExtendedLifetime(connection) {}
    }

    func testExtraColumnsTriggersTablesAndIndexesAreRejected() async throws {
        for alteration in ["ALTER TABLE source_signatures ADD COLUMN future TEXT",
                           "CREATE TABLE unrelated(value TEXT)",
                           "CREATE INDEX extra ON source_signatures(size)",
                           "CREATE TRIGGER changed AFTER INSERT ON source_signatures BEGIN DELETE FROM source_signatures; END"] {
            let layout = try fixture()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            try initialize(layout)
            do { let connection = try Connection(layout.sourceSignatures); try connection.execute(alteration) }
            try await assertRejected(layout, expected: .incompatibleSchema)
        }
    }

    func testWrongColumnOrderCollationPrimaryKeyAndIndexDefinitionsAreRejected() async throws {
        let canonical = SourceSignatureRepository.version3InitializationSQL
        for sql in [
            canonical.replacingOccurrences(of: "size INTEGER NOT NULL", with: "size INTEGERNOTNULL"),
            canonical.replacingOccurrences(of: "size INTEGER NOT NULL", with: "size INTEGER\u{00A0}NOT NULL"),
            canonical.replacingOccurrences(of: "job_id TEXT NOT NULL", with: "job_id TEXT COLLATE NOCASE NOT NULL"),
            canonical.replacingOccurrences(of: "PRIMARY KEY (job_id, source_key, relative_path)", with: "PRIMARY KEY (relative_path, source_key, job_id)"),
            canonical.replacingOccurrences(of: " WITHOUT ROWID", with: ""),
            canonical.replacingOccurrences(of: "ON source_signatures (job_id, source_key, last_seen_at)", with: "ON source_signatures (job_id, last_seen_at, source_key)"),
            canonical.replacingOccurrences(of: "CREATE INDEX source_signatures_last_seen", with: "CREATE UNIQUE INDEX source_signatures_last_seen"),
            canonical.replacingOccurrences(of: "ON source_signatures (job_id, source_key, last_seen_at)", with: "ON source_signatures (job_id, source_key, last_seen_at) WHERE size > 0")
        ] {
            let layout = try fixture()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            try initialize(layout, sql: sql)
            try await assertRejected(layout, expected: .incompatibleSchema)
        }
    }

    func testSupportedStoreReopensWritesAndSnapshotsWithVersion3Identity() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try initialize(layout)
        let repository = SourceSignatureRepository(storage: layout)
        let jobID = UUID()
        try await repository.record(file, jobID: jobID, sourceEndpoint: endpoint)
        let reopened = SourceSignatureRepository(storage: layout)
        let actual = try await reopened.signature(jobID: jobID, sourceEndpoint: endpoint, relativePath: file.relativePath)
        XCTAssertEqual(actual, SourceFileSignature(file: file))
        let destination = layout.root.appendingPathComponent("frozen.sqlite3")
        let receipt = try await reopened.snapshot(to: destination)
        XCTAssertEqual(receipt.schemaVersion, 3)
        XCTAssertEqual(receipt.recordCount, 1)
        XCTAssertEqual(try scalar("PRAGMA user_version", at: destination), 3)
        XCTAssertEqual(try scalar("PRAGMA application_id", at: destination), SourceSignatureRepository.version3ApplicationID)
        let snapshotRepository = SourceSignatureRepository(fileURL: destination, storage: layout)
        let frozen = try await snapshotRepository.signature(jobID: jobID, sourceEndpoint: endpoint, relativePath: file.relativePath)
        XCTAssertEqual(frozen, actual)
        try await reopened.removeSignatures(jobID: jobID)
        let removed = try await reopened.signature(jobID: jobID, sourceEndpoint: endpoint, relativePath: file.relativePath)
        XCTAssertNil(removed)
    }

    func testSymlinkAndHardLinkedDatabaseOrCompanionRejectedBeforeOpen() async throws {
        let layout = try fixture()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try initialize(layout)
        let alias = layout.root.appendingPathComponent("alias.sqlite3")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: layout.sourceSignatures)
        do { try await lookup(SourceSignatureRepository(fileURL: alias, storage: layout)); XCTFail() }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .unsafeDatabase) }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.linkItem(at: layout.sourceSignatures, to: alias)
        do { try await lookup(SourceSignatureRepository(storage: layout)); XCTFail() }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .unsafeDatabase) }
        try FileManager.default.removeItem(at: alias)
        let companion = URL(fileURLWithPath: layout.sourceSignatures.path + "-wal")
        try FileManager.default.createSymbolicLink(at: companion, withDestinationURL: layout.sourceSignatures)
        do { try await lookup(SourceSignatureRepository(storage: layout)); XCTFail() }
        catch { XCTAssertEqual(error as? SourceSignatureRepository.Version3OpenError, .unsafeDatabase) }
    }
}
