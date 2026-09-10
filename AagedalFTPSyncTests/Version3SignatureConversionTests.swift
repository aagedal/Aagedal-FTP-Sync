import Foundation
import SQLite3
import XCTest
@testable import AagedalFTPSync

final class Version3SignatureConversionTests: XCTestCase {
    private typealias Conversion = Version3SignatureConversion
    private struct Row: Equatable {
        let job: String, key: String, path: String
        let size: Int64
        let modified: Double, seen: Double
    }
    private var sample: Row {
        let fields = ["sftp", "", "fixture.invalid", "22", "Åse", "/incoming"]
        return Row(job: "AE5B40F5-6C9C-4FDC-89C8-B9D802DB20C1", key: fields.map { "\($0.utf8.count):\($0)" }.joined(),
                   path: "folder/東京\\photo.jpg", size: Int64.max - 1, modified: -123_456.125, seen: 1_700_000_000.875)
    }
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("signature-converter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func connection<T>(_ url: URL, _ action: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        return try action(database)
    }
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { XCTFail(String(cString: sqlite3_errmsg(database))); throw CocoaError(.fileWriteUnknown) }
    }
    private func legacy(in root: URL, rows: [Row]? = nil, alter: String? = nil) throws -> Data {
        let url = root.appendingPathComponent("legacy-\(UUID().uuidString).sqlite3")
        try connection(url) { database in
            try execute(SourceSignatureRepository.version3TableSQL + ";" + SourceSignatureRepository.version3IndexSQL
                + "; PRAGMA user_version = 2", in: database)
            for row in rows ?? [sample] {
                var statement: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO source_signatures VALUES (?,?,?,?,?,?)", -1, &statement, nil), SQLITE_OK)
                let insert = try XCTUnwrap(statement)
                defer { sqlite3_finalize(insert) }
                for (index, value) in [row.job, row.key, row.path].enumerated() {
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    value.withCString { pointer in
                        XCTAssertEqual(sqlite3_bind_text(insert, Int32(index + 1), pointer, Int32(value.utf8.count), transient), SQLITE_OK)
                    }
                }
                sqlite3_bind_int64(insert, 4, row.size)
                sqlite3_bind_double(insert, 5, row.modified)
                sqlite3_bind_double(insert, 6, row.seen)
                XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
            }
            if let alter { try execute(alter, in: database) }
        }
        return try Data(contentsOf: url)
    }
    private func rows(_ data: Data, in root: URL) throws -> [Row] {
        let url = root.appendingPathComponent("readback-\(UUID().uuidString).sqlite3")
        try data.write(to: url)
        return try connection(url) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT * FROM source_signatures ORDER BY job_id,source_key,relative_path", -1, &statement, nil), SQLITE_OK)
            let read = try XCTUnwrap(statement)
            defer { sqlite3_finalize(read) }
            var result: [Row] = []
            while sqlite3_step(read) == SQLITE_ROW {
                result.append(Row(job: String(cString: sqlite3_column_text(read, 0)), key: String(cString: sqlite3_column_text(read, 1)),
                    path: String(cString: sqlite3_column_text(read, 2)), size: sqlite3_column_int64(read, 3),
                    modified: sqlite3_column_double(read, 4), seen: sqlite3_column_double(read, 5)))
            }
            return result
        }
    }
    private func assertNoStages(_ root: URL) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".signature-conversion-") })
    }

    func testCanonicalConversionPreservesRowsOriginalInputAndHistoricalJobReferences() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try legacy(in: root)
        let original = input
        let output = try Conversion.convert(.standaloneSnapshot(input), temporaryDirectory: root)
        XCTAssertEqual(input, original)
        XCTAssertEqual(output.recordCount, 1)
        XCTAssertEqual(output.referencedJobIDs, [try XCTUnwrap(UUID(uuidString: sample.job))])
        XCTAssertEqual(try rows(output.data, in: root), [sample])
        let url = root.appendingPathComponent("canonical-v3.sqlite3")
        try output.data.write(to: url)
        let repository = SourceSignatureRepository(fileURL: url, storage: AppStorageLayout(root: root, storageFormat: .version3))
        let receipt = try await repository.snapshotAfterOpeningForConversionTest(jobID: UUID(uuidString: sample.job)!, to: root.appendingPathComponent("verified.sqlite3"))
        XCTAssertEqual(receipt.schemaVersion, 3)
        XCTAssertEqual(receipt.recordCount, 1)
        try assertNoStages(root)
    }

    private func jsonRecord(job: String = "AE5B40F5-6C9C-4FDC-89C8-B9D802DB20C1",
                            username: String = "Åse", path: String = "folder/東京\\photo.jpg",
                            size: Int64 = Int64.max - 1, milliseconds: Double = -123_456_125) -> [String: Any] {
        ["jobID": job,
         "source": ["kind": "sftp", "localPath": "", "host": " MiXeD.Example ", "port": 22,
                    "username": username, "remotePath": "/incoming//"],
         "relativePath": path,
         "signature": ["size": size, "modifiedAt": milliseconds]]
    }
    private func json(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    }

    func testLegacyJSONUsesStoredIdentityMillisecondsAndOneExplicitMigrationDate() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try json([jsonRecord()])
        let original = input
        let migratedAt = Date(timeIntervalSince1970: 1_700_000_999.25)
        let output = try Conversion.convert(.legacyJSON(input, migratedAt: migratedAt), temporaryDirectory: root)
        XCTAssertEqual(input, original)
        XCTAssertEqual(output.recordCount, 1)
        XCTAssertEqual(output.referencedJobIDs, [try XCTUnwrap(UUID(uuidString: sample.job))])
        let fields = ["sftp", "", " MiXeD.Example ", "22", "Åse", "/incoming//"]
        let expected = Row(job: sample.job, key: fields.map { "\($0.utf8.count):\($0)" }.joined(),
            path: sample.path, size: Int64.max - 1, modified: -123_456.125, seen: migratedAt.timeIntervalSince1970)
        XCTAssertEqual(try rows(output.data, in: root), [expected])
        let repeated = try Conversion.convert(.legacyJSON(input, migratedAt: migratedAt), temporaryDirectory: root)
        XCTAssertEqual(try rows(repeated.data, in: root), [expected])
        try assertNoStages(root)
    }

    func testLegacyJSONDuplicatesUseSwiftIdentityEqualityAndLastOccurrenceWins() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = jsonRecord(username: "Åse", path: "é.jpg", size: 1, milliseconds: 1000)
        let lastUsername = "A\u{030A}se"
        let lastPath = "e\u{0301}.jpg"
        let last = jsonRecord(job: sample.job.lowercased(), username: lastUsername, path: lastPath, size: 2, milliseconds: 2000)
        let other = jsonRecord(job: "264823A7-70A1-4F52-9836-EC36259F194F", size: 3, milliseconds: 3000)
        let output = try Conversion.convert(.legacyJSON(try json([first, other, last]), migratedAt: Date(timeIntervalSince1970: 40)), temporaryDirectory: root)
        XCTAssertEqual(output.recordCount, 2)
        XCTAssertEqual(output.referencedJobIDs.count, 2)
        let actual = try rows(output.data, in: root)
        let winning = try XCTUnwrap(actual.first { $0.job == sample.job })
        let fields = ["sftp", "", " MiXeD.Example ", "22", lastUsername, "/incoming//"]
        // Compare UTF-8 bytes: ordinary Swift String equality intentionally treats
        // these composed/decomposed spellings as equal, just like legacy keys.
        XCTAssertEqual(Array(winning.key.utf8), Array(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
        XCTAssertEqual(Array(winning.path.utf8), Array(lastPath.utf8))
        XCTAssertEqual(winning.size, 2)
        XCTAssertEqual(winning.modified, 2)
        XCTAssertEqual(winning.seen, 40)
    }

    func testMalformedLegacyJSONNeverBecomesAnEmptyStore() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var missing = jsonRecord(); missing.removeValue(forKey: "signature")
        var wrongType = jsonRecord(); wrongType["signature"] = ["size": "100", "modifiedAt": 1000]
        var invalidKind = jsonRecord()
        var source = invalidKind["source"] as! [String: Any]; source["kind"] = "future"; invalidKind["source"] = source
        for input in [Data(), Data("{}".utf8), Data("null".utf8), Data("[".utf8),
                      try json([missing]), try json([wrongType]), try json([invalidKind])] {
            XCTAssertThrowsError(try Conversion.convert(.legacyJSON(input, migratedAt: Date(timeIntervalSince1970: 0)), temporaryDirectory: root)) {
                XCTAssertEqual($0 as? Conversion.Failure, .malformedLegacyJSON)
            }
        }
        let empty = try Conversion.convert(.legacyJSON(Data("[]".utf8), migratedAt: Date(timeIntervalSince1970: 0)), temporaryDirectory: root)
        XCTAssertEqual(empty.recordCount, 0)
        XCTAssertTrue(empty.referencedJobIDs.isEmpty)
        try assertNoStages(root)
    }

    func testLegacyJSONValidatesEveryRecordBeforeDedupAndBoundsInput() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let migratedAt = Date(timeIntervalSince1970: 0)
        let valid = jsonRecord()
        let input = try json([valid, valid])
        for (limits, expected) in [(Conversion.Limits(maximumBytes: 1), Conversion.Failure.inputLimit),
                                   (Conversion.Limits(maximumRecords: 1), .recordLimit),
                                   (Conversion.Limits(maximumTextBytes: 2), .textLimit)] {
            XCTAssertThrowsError(try Conversion.convert(.legacyJSON(input, migratedAt: migratedAt), temporaryDirectory: root, limits: limits)) {
                XCTAssertEqual($0 as? Conversion.Failure, expected)
            }
        }
        // A semantically damaged earlier duplicate cannot be hidden by the later
        // valid record. Valid duplicates alone retain legacy last-wins behavior.
        let negative = jsonRecord(size: -1)
        let nul = jsonRecord(path: "bad\0path")
        let newline = jsonRecord(path: "bad\npath")
        for bad in [negative, nul, newline] {
            XCTAssertThrowsError(try Conversion.convert(.legacyJSON(try json([bad, valid]), migratedAt: migratedAt), temporaryDirectory: root)) {
                XCTAssertEqual($0 as? Conversion.Failure, .invalidRow)
            }
        }
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            XCTAssertThrowsError(try Conversion.convert(.legacyJSON(input, migratedAt: date), temporaryDirectory: root)) {
                XCTAssertEqual($0 as? Conversion.Failure, .invalidMigrationDate)
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testExplicitNoLegacyStoreCreatesValidEmptyVersion3Bytes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try Conversion.convert(.noLegacyStore, temporaryDirectory: root)
        XCTAssertEqual(output.recordCount, 0)
        XCTAssertTrue(output.referencedJobIDs.isEmpty)
        XCTAssertEqual(try rows(output.data, in: root), [])
        XCTAssertEqual(output.data[18], 1)
        XCTAssertEqual(output.data[19], 1)
        try assertNoStages(root)
    }

    func testFutureWrongIdentityExtraSchemaAndWeakColumnTypesAreRejected() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for (sql, expected) in [("PRAGMA user_version = 99", Conversion.Failure.unsupportedVersion(99)),
                                ("PRAGMA application_id = 123", .wrongApplicationID(123)),
                                ("CREATE INDEX extra ON source_signatures(size)", .incompatibleSchema),
                                ("ALTER TABLE source_signatures ADD COLUMN extra TEXT", .incompatibleSchema)] {
            let input = try legacy(in: root, alter: sql)
            XCTAssertThrowsError(try Conversion.convert(.standaloneSnapshot(input), temporaryDirectory: root)) {
                XCTAssertEqual($0 as? Conversion.Failure, expected)
            }
        }
        try assertNoStages(root)
    }

    func testLegacyOptimizerStatisticsAreValidatedAndOmittedFromCanonicalOutput() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        // Legacy migration uses optimize; ANALYZE makes this fixture independent
        // of the OS SQLite version's optimize heuristic for very small tables.
        let input = try legacy(in: root, alter: "PRAGMA optimize; ANALYZE")
        let original = input
        let output = try Conversion.convert(.standaloneSnapshot(input), temporaryDirectory: root)
        XCTAssertEqual(input, original)
        XCTAssertEqual(try rows(output.data, in: root), [sample])
        let file = root.appendingPathComponent("statistics-check.sqlite3")
        try output.data.write(to: file)
        try connection(file) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_schema", -1, &statement, nil), SQLITE_OK)
            let query = try XCTUnwrap(statement)
            defer { sqlite3_finalize(query) }
            XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(query, 0), 2, "Only the canonical table and index belong in v3")
        }
        try assertNoStages(root)
    }

    func testWALHeaderTruncatedTrailingAndNonSQLiteInputsAreRejected() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try legacy(in: root)
        var wal = valid; wal[18] = 2; wal[19] = 2
        for input in [Data(), Data("[]".utf8), Data(valid.prefix(99)), wal, valid + Data([1]), Data(valid.dropLast())] {
            XCTAssertThrowsError(try Conversion.convert(.standaloneSnapshot(input), temporaryDirectory: root))
        }
        try assertNoStages(root)
    }

    func testInvalidRowsAndUnsafePathsFailWithoutReinterpretingValues() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for sql in ["UPDATE source_signatures SET job_id = 'bad'", "UPDATE source_signatures SET source_key = 'bad'",
                    "UPDATE source_signatures SET size = -1", "UPDATE source_signatures SET size = 1.5",
                    "UPDATE source_signatures SET modified_at = 1e999", "UPDATE source_signatures SET last_seen_at = 'text'",
                    "UPDATE source_signatures SET relative_path = '../escape'", "UPDATE source_signatures SET relative_path = char(10) || 'photo.jpg'",
                    "UPDATE source_signatures SET relative_path = CAST(x'ff' AS TEXT)", "UPDATE source_signatures SET relative_path = 'a' || char(0) || 'b'"] {
            let input = try legacy(in: root, alter: sql)
            XCTAssertThrowsError(try Conversion.convert(.standaloneSnapshot(input), temporaryDirectory: root)) {
                XCTAssertEqual($0 as? Conversion.Failure, .invalidRow, sql)
            }
        }
        try assertNoStages(root)
    }

    func testBoundsAndCancellationLeaveOnlyUnrelatedFiles() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try legacy(in: root)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for (limits, expected) in [
            (Conversion.Limits(maximumBytes: 1), Conversion.Failure.inputLimit),
            (Conversion.Limits(maximumRecords: 0), .recordLimit),
            (Conversion.Limits(maximumTextBytes: 1), .textLimit),
            (Conversion.Limits(timeout: .leastNonzeroMagnitude), .deadlineExceeded)
        ] {
            XCTAssertThrowsError(try Conversion.convert(.standaloneSnapshot(input), temporaryDirectory: root, limits: limits)) {
                XCTAssertEqual($0 as? Conversion.Failure, expected)
            }
        }
        XCTAssertThrowsError(try Conversion.convert(.noLegacyStore, temporaryDirectory: root, limits: .init(maximumBytes: 4096))) {
            XCTAssertEqual($0 as? Conversion.Failure, .outputLimit)
        }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try Conversion.convert(.standaloneSnapshot(input), temporaryDirectory: root)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testNonzeroDataStartIndexAndEmptyLegacySnapshotAreAccepted() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try legacy(in: root, rows: [])
        let prefixed = Data([0, 1, 2]) + bytes
        let slice = prefixed.dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0)
        let output = try Conversion.convert(.standaloneSnapshot(slice), temporaryDirectory: root)
        XCTAssertEqual(output.recordCount, 0)
    }

    func testUnsafeTemporaryRootsAndInvalidLimitsNeverCreateStages() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try Conversion.convert(.noLegacyStore, temporaryDirectory: link)) {
            XCTAssertEqual($0 as? Conversion.Failure, .unsafeTemporaryDirectory)
        }
        for limits in [Conversion.Limits(maximumBytes: 0), .init(maximumRecords: -1), .init(maximumTextBytes: 0),
                       .init(timeout: .nan), .init(timeout: .infinity), .init(timeout: 61)] {
            XCTAssertThrowsError(try Conversion.convert(.noLegacyStore, temporaryDirectory: root, limits: limits)) {
                XCTAssertEqual($0 as? Conversion.Failure, .invalidLimits)
            }
        }
        try assertNoStages(root)
    }
}

private extension SourceSignatureRepository {
    func snapshotAfterOpeningForConversionTest(jobID: UUID, to url: URL) throws -> SnapshotReceipt {
        _ = try signature(jobID: jobID, sourceEndpoint: Endpoint(kind: .ftp, host: "not-the-historical-source.invalid"), relativePath: "missing")
        return try snapshot(to: url)
    }
}
