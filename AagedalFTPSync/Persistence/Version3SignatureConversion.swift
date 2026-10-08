import Darwin
import Foundation
import SQLite3

/// Opt-in conversion of a frozen source-signature snapshot; no production startup
/// calls this helper. The driver must first quiesce related stores and obtain a
/// standalone `SourceSignatureRepository.snapshot` result. Copying arbitrary live
/// main-file bytes is not an equivalent input, even if they pass integrity checks.
/// This Data API cannot inspect the original path's companions; the driver owns
/// that admission. WAL-header input is always rejected, never recovered or ignored.
enum Version3SignatureConversion {
    enum Input: Sendable {
        case noLegacyStore
        case standaloneSnapshot(Data)
        /// The driver explicitly selected these bytes from a legacy v1 JSON
        /// source; this helper never looks up or silently selects a backup.
        case legacyJSON(Data, migratedAt: Date)
    }
    struct Limits: Sendable {
        var maximumBytes = 256 * 1024 * 1024
        var maximumRecords = 2_000_000
        var maximumTextBytes = 65_536
        var timeout: TimeInterval = 10
    }
    struct Output: Equatable, Sendable {
        let data: Data
        let recordCount: Int
        /// Historical jobs are legitimate; the driver must not require membership
        /// in today's live job set or drop those rows during conversion.
        let referencedJobIDs: Set<UUID>
    }
    enum Failure: Error, Equatable {
        case invalidLimits, unsafeTemporaryDirectory, inputLimit, outputLimit, recordLimit, textLimit
        case deadlineExceeded, notStandaloneSQLite, incompatibleSchema, invalidRow, integrityFailure
        case malformedLegacyJSON, invalidMigrationDate
        case wrongApplicationID(Int64), unsupportedVersion(Int64)
        case sqlite(Int32), fileSystem(Int32)
    }
    private final class Deadline: Sendable {
        let end: UInt64
        init(_ seconds: TimeInterval) { end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000) }
        var expired: Bool { DispatchTime.now().uptimeNanoseconds >= end }
        func check() throws {
            if expired { throw Failure.deadlineExceeded }
            try Task.checkCancellation()
        }
    }
    // Mirror the legacy repository's synthesized Codable/Hashable model exactly:
    // stored source fields are NOT normalized by constructing a fresh Endpoint.
    private struct LegacyJSONSource: Decodable, Hashable {
        let kind: EndpointKind
        let localPath: String
        let host: String
        let port: Int
        let username: String
        let remotePath: String
        var fields: [String] { [kind.rawValue, localPath, host, String(port), username, remotePath] }
        var databaseKey: String { fields.map { "\($0.utf8.count):\($0)" }.joined() }
    }
    private struct LegacyJSONKey: Hashable {
        let jobID: UUID
        let source: LegacyJSONSource
        let relativePath: String
    }
    private struct LegacyJSONRecord: Decodable {
        let jobID: UUID
        let source: LegacyJSONSource
        let relativePath: String
        let signature: SourceFileSignature
        var key: LegacyJSONKey { LegacyJSONKey(jobID: jobID, source: source, relativePath: relativePath) }
    }
    private struct JSONDecodeContext: Sendable {
        let limits: Limits
        let deadline: Deadline
    }
    private static let jsonContextKey = CodingUserInfoKey(rawValue: "Version3SignatureConversion.context")!
    private struct LegacyJSONBatch: Decodable {
        let records: [LegacyJSONRecord]
        init(from decoder: Decoder) throws {
            guard let context = decoder.userInfo[jsonContextKey] as? JSONDecodeContext else { throw Failure.invalidLimits }
            var array = try decoder.unkeyedContainer()
            if let count = array.count, count > context.limits.maximumRecords { throw Failure.recordLimit }
            var count = 0
            var unique: [LegacyJSONKey: LegacyJSONRecord] = [:]
            while !array.isAtEnd {
                try context.deadline.check()
                guard count < context.limits.maximumRecords else { throw Failure.recordLimit }
                let record = try array.decode(LegacyJSONRecord.self)
                // Bound and validate every present record before deduplication;
                // a discarded duplicate cannot hide invalid or oversized data.
                for value in record.source.fields + [record.relativePath] {
                    guard value.utf8.count <= context.limits.maximumTextBytes else { throw Failure.textLimit }
                    guard !value.utf8.contains(0) else { throw Failure.invalidRow }
                }
                let sourceKey = record.source.databaseKey
                guard sourceKey.utf8.count <= context.limits.maximumTextBytes else { throw Failure.textLimit }
                guard validSourceKey(sourceKey), PathSafety.isSafeRelativePath(record.relativePath),
                      record.signature.size >= 0, record.signature.modifiedAt.timeIntervalSince1970.isFinite else {
                    throw Failure.invalidRow
                }
                // Swift Hashable equality (including canonically equivalent
                // Unicode strings) and last occurrence wins match v1 migration.
                unique[record.key] = record
                count += 1
            }
            var comparisons = 0
            records = try unique.values.sorted {
                comparisons += 1
                if comparisons.isMultiple(of: 1024) { try context.deadline.check() }
                return ($0.jobID.uuidString, $0.source.databaseKey, $0.relativePath)
                    < ($1.jobID.uuidString, $1.source.databaseKey, $1.relativePath)
            }
            try context.deadline.check()
        }
    }

    private final class Connection {
        let pointer: OpaquePointer
        private var closed = false
        init(_ url: URL, readOnly: Bool, immutable: Bool = false, deadline: Deadline, limits: Limits) throws {
            var opened: OpaquePointer?
            let name = immutable ? url.absoluteString + "?immutable=1" : url.path
            let status = sqlite3_open_v2(name, &opened,
                (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
                    | (immutable ? SQLITE_OPEN_URI : 0), nil)
            guard status == SQLITE_OK, let opened else {
                if let opened { sqlite3_close_v2(opened) }
                throw Failure.sqlite(status)
            }
            pointer = opened
            sqlite3_busy_timeout(pointer, 0)
            sqlite3_limit(pointer, SQLITE_LIMIT_LENGTH, Int32(max(1_048_576, 3 * limits.maximumTextBytes + 256)))
            sqlite3_progress_handler(pointer, 1000, { context in
                guard let context else { return 1 }
                let deadline = Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue()
                return deadline.expired || Task<Never, Never>.isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(deadline).toOpaque())
        }
        func close() throws {
            guard !closed else { return }
            let status = sqlite3_close(pointer)
            guard status == SQLITE_OK else { throw Failure.sqlite(status) }
            closed = true
        }
        deinit { if !closed { sqlite3_close_v2(pointer) } }
    }

    /// The existing temporary directory and its ancestors must remain trusted and
    /// stable. Only a uniquely created private stage is cleaned up; unrelated files
    /// are untouched. Success returns closed, synchronized standalone v3 bytes.
    /// Deadline checks bound SQLite/row work, not a blocked kernel filesystem call
    /// or Foundation's initial JSON parse. Input bytes cap that parse; decoding and
    /// deduplication check deadlines per record. JSON dates use legacy milliseconds
    /// since Unix epoch; the caller supplies one frozen last-seen migration date.
    static func convert(_ input: Input, temporaryDirectory: URL, limits: Limits = Limits()) throws -> Output {
        try validateLimits(limits)
        let deadline = Deadline(limits.timeout)
        try deadline.check()
        if case .standaloneSnapshot(let data) = input {
            guard data.count <= limits.maximumBytes else { throw Failure.inputLimit }
            guard data.count >= 100, data.prefix(16) == Data("SQLite format 3\0".utf8),
                  data[data.index(data.startIndex, offsetBy: 18)] == 1, data[data.index(data.startIndex, offsetBy: 19)] == 1 else { throw Failure.notStandaloneSQLite }
        }
        var legacyRecords: [LegacyJSONRecord]?
        if case .legacyJSON(let data, let migratedAt) = input {
            guard data.count <= limits.maximumBytes else { throw Failure.inputLimit }
            guard migratedAt.timeIntervalSince1970.isFinite else { throw Failure.invalidMigrationDate }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            decoder.userInfo[jsonContextKey] = JSONDecodeContext(limits: limits, deadline: deadline)
            do { legacyRecords = try decoder.decode(LegacyJSONBatch.self, from: data).records }
            catch {
                try deadline.check()
                if let bounded = error as? Failure { throw bounded }
                throw Failure.malformedLegacyJSON
            }
            try deadline.check()
        }
        try validateDirectory(temporaryDirectory)
        let stage = temporaryDirectory.appendingPathComponent(".signature-conversion-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw Failure.fileSystem(errno) }
        defer { try? FileManager.default.removeItem(at: stage) }
        // All SQLite connections die before the callback's deadline context.
        defer { withExtendedLifetime(deadline) {} }
        do {
            let outputURL = stage.appendingPathComponent("version3.sqlite3")
            try writeExclusive(Data(), to: outputURL)
            let output = try Connection(outputURL, readOnly: false, deadline: deadline, limits: limits)
            try execute("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA page_size = 4096", in: output.pointer)
            try execute("PRAGMA max_page_count = \(max(1, limits.maximumBytes / 4096))", in: output.pointer)
            try execute(SourceSignatureRepository.version3InitializationSQL, in: output.pointer)
            var count = 0
            var jobs = Set<UUID>()
            if case .standaloneSnapshot(let data) = input {
                let inputURL = stage.appendingPathComponent("legacy.sqlite3")
                try writeExclusive(data, to: inputURL)
                let source = try Connection(inputURL, readOnly: true, deadline: deadline, limits: limits)
                try validate(source.pointer, version: 2, applicationID: 0)
                let pages = try integer("PRAGMA page_count", in: source.pointer)
                let size = try integer("PRAGMA page_size", in: source.pointer)
                guard pages > 0, size > 0, pages <= Int64(data.count) / size,
                      pages * size == data.count else { throw Failure.notStandaloneSQLite }
                let sourceCount = try integer("SELECT count(*) FROM source_signatures", in: source.pointer)
                guard sourceCount <= limits.maximumRecords else { throw Failure.recordLimit }
                try checkIntegrity(source.pointer)
                try deadline.check()
                try execute("BEGIN IMMEDIATE", in: output.pointer)
                let read = try prepare("SELECT job_id, source_key, relative_path, size, modified_at, last_seen_at FROM source_signatures ORDER BY job_id, source_key, relative_path", in: source.pointer)
                let insert: OpaquePointer
                do {
                    insert = try prepare("INSERT INTO source_signatures VALUES (?, ?, ?, ?, ?, ?)", in: output.pointer)
                } catch { sqlite3_finalize(read); throw error }
                do {
                    defer { sqlite3_finalize(read); sqlite3_finalize(insert) }
                    while true {
                        try deadline.check()
                        let step = sqlite3_step(read)
                        if step == SQLITE_DONE { break }
                        guard step == SQLITE_ROW else { throw Failure.sqlite(step) }
                        guard count < limits.maximumRecords else { throw Failure.recordLimit }
                        let jobID = try validateRow(read, limits: limits)
                        sqlite3_reset(insert)
                        sqlite3_clear_bindings(insert)
                        // Bind sqlite3_value directly: preserve exact text bytes,
                        // Int64 sizes and numeric timestamp values without Date or
                        // endpoint normalization or a text round-trip.
                        for column: Int32 in 0..<6 {
                            guard sqlite3_bind_value(insert, column + 1, sqlite3_column_value(read, column)) == SQLITE_OK else {
                                throw Failure.sqlite(sqlite3_errcode(output.pointer))
                            }
                        }
                        let written = sqlite3_step(insert)
                        guard written == SQLITE_DONE else { throw Failure.sqlite(written) }
                        count += 1
                        jobs.insert(jobID)
                    }
                }
                guard count == sourceCount else { throw Failure.invalidRow }
                try execute("COMMIT", in: output.pointer)
                try source.close()
            }
            if case .legacyJSON(_, let migratedAt) = input, let legacyRecords {
                try execute("BEGIN IMMEDIATE", in: output.pointer)
                let insert = try prepare("INSERT INTO source_signatures VALUES (?, ?, ?, ?, ?, ?)", in: output.pointer)
                do {
                    defer { sqlite3_finalize(insert) }
                    for record in legacyRecords {
                        try deadline.check()
                        sqlite3_reset(insert)
                        sqlite3_clear_bindings(insert)
                        for (index, value) in [record.jobID.uuidString, record.source.databaseKey, record.relativePath].enumerated() {
                            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                            let status = value.withCString { sqlite3_bind_text(insert, Int32(index + 1), $0, Int32(value.utf8.count), transient) }
                            guard status == SQLITE_OK else { throw Failure.sqlite(status) }
                        }
                        for status in [sqlite3_bind_int64(insert, 4, record.signature.size),
                                       sqlite3_bind_double(insert, 5, record.signature.modifiedAt.timeIntervalSince1970),
                                       sqlite3_bind_double(insert, 6, migratedAt.timeIntervalSince1970)] {
                            guard status == SQLITE_OK else { throw Failure.sqlite(status) }
                        }
                        let status = sqlite3_step(insert)
                        guard status == SQLITE_DONE else { throw Failure.sqlite(status) }
                        count += 1
                        jobs.insert(record.jobID)
                    }
                }
                try execute("COMMIT", in: output.pointer)
            }
            try validate(output.pointer, version: 3, applicationID: SourceSignatureRepository.version3ApplicationID)
            try checkIntegrity(output.pointer)
            guard try integer("SELECT count(*) FROM source_signatures", in: output.pointer) == count else { throw Failure.invalidRow }
            try output.close()
            try deadline.check()
            let fd = Darwin.open(outputURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.fileSystem(errno) }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Failure.fileSystem(errno) }
            guard info.st_size > 0, info.st_size <= limits.maximumBytes else { throw Failure.outputLimit }
            guard fsync(fd) == 0 else { throw Failure.fileSystem(errno) }
            let result = try Data(contentsOf: outputURL)
            guard result.count == info.st_size, result[18] == 1, result[19] == 1 else { throw Failure.notStandaloneSQLite }
            try deadline.check()
            return Output(data: result, recordCount: count, referencedJobIDs: jobs)
        } catch {
            try deadline.check()
            if case Failure.sqlite(SQLITE_FULL) = error { throw Failure.outputLimit }
            throw error
        }
    }

    /// Read-only validation of already acquired, complete v3 database bytes. The
    /// caller must exclude writers and establish that no WAL was omitted. A clean
    /// checkpointed main can retain WAL mode in its header; immutable SQLite opens
    /// only our private frozen copy, never the original store or its companions.
    /// Returns the exact input bytes, with validated row count and historical IDs.
    /// It never rewrites v3, repairs schema, or regenerates last-seen timestamps.
    static func validateVersion3Snapshot(_ data: Data, temporaryDirectory: URL,
                                         limits: Limits = Limits()) throws -> Output {
        try validateLimits(limits)
        let deadline = Deadline(limits.timeout)
        try deadline.check()
        guard data.count <= limits.maximumBytes else { throw Failure.inputLimit }
        guard data.count >= 100, data.prefix(16) == Data("SQLite format 3\0".utf8) else { throw Failure.notStandaloneSQLite }
        let readVersion = data[data.index(data.startIndex, offsetBy: 18)]
        let writeVersion = data[data.index(data.startIndex, offsetBy: 19)]
        guard [1, 2].contains(readVersion), readVersion == writeVersion else { throw Failure.notStandaloneSQLite }
        try validateDirectory(temporaryDirectory)
        let stage = temporaryDirectory.appendingPathComponent(".signature-conversion-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw Failure.fileSystem(errno) }
        defer { try? FileManager.default.removeItem(at: stage) }
        defer { withExtendedLifetime(deadline) {} }
        do {
            let url = stage.appendingPathComponent("validated-v3.sqlite3")
            try writeExclusive(data, to: url)
            let source = try Connection(url, readOnly: true, immutable: true, deadline: deadline, limits: limits)
            guard sqlite3_db_readonly(source.pointer, "main") == 1 else { throw Failure.incompatibleSchema }
            try validate(source.pointer, version: 3, applicationID: SourceSignatureRepository.version3ApplicationID)
            let pages = try integer("PRAGMA page_count", in: source.pointer)
            let pageSize = try integer("PRAGMA page_size", in: source.pointer)
            guard pages > 0, pageSize > 0, pages <= Int64(data.count) / pageSize,
                  pages * pageSize == data.count else { throw Failure.notStandaloneSQLite }
            let expectedCount = try integer("SELECT count(*) FROM source_signatures", in: source.pointer)
            guard expectedCount >= 0, expectedCount <= limits.maximumRecords else { throw Failure.recordLimit }
            try checkIntegrity(source.pointer)
            let read = try prepare("SELECT job_id, source_key, relative_path, size, modified_at, last_seen_at FROM source_signatures ORDER BY job_id, source_key, relative_path", in: source.pointer)
            var count = 0
            var jobs = Set<UUID>()
            do {
                defer { sqlite3_finalize(read) }
                while true {
                    try deadline.check()
                    let status = sqlite3_step(read)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw Failure.sqlite(status) }
                    guard count < limits.maximumRecords else { throw Failure.recordLimit }
                    jobs.insert(try validateRow(read, limits: limits))
                    count += 1
                }
            }
            guard count == expectedCount else { throw Failure.invalidRow }
            try source.close()
            try deadline.check()
            return Output(data: data, recordCount: count, referencedJobIDs: jobs)
        } catch {
            try deadline.check()
            throw error
        }
    }

    private static func validateLimits(_ limits: Limits) throws {
        guard (1...1_073_741_824).contains(limits.maximumBytes), (0...10_000_000).contains(limits.maximumRecords),
              (1...1_048_576).contains(limits.maximumTextBytes), limits.timeout.isFinite,
              limits.timeout > 0, limits.timeout <= 60 else { throw Failure.invalidLimits }
    }

    /// Shared by legacy SQLite conversion and current-v3 admission so malformed
    /// identities, paths, sizes or timestamps cannot pass only one of the routes.
    private static func validateRow(_ statement: OpaquePointer, limits: Limits) throws -> UUID {
        let jobText = try text(statement, column: 0, limits: limits)
        let sourceKey = try text(statement, column: 1, limits: limits)
        let path = try text(statement, column: 2, limits: limits)
        guard let jobID = UUID(uuidString: jobText), validSourceKey(sourceKey), PathSafety.isSafeRelativePath(path),
              sqlite3_column_type(statement, 3) == SQLITE_INTEGER, sqlite3_column_int64(statement, 3) >= 0 else {
            throw Failure.invalidRow
        }
        for column: Int32 in [4, 5] {
            guard [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, column)),
                  sqlite3_column_double(statement, column).isFinite else { throw Failure.invalidRow }
        }
        return jobID
    }

    private static func validate(_ database: OpaquePointer, version: Int64, applicationID: Int64) throws {
        let id = try integer("PRAGMA application_id", in: database)
        guard id == applicationID else { throw Failure.wrongApplicationID(id) }
        let foundVersion = try integer("PRAGMA user_version", in: database)
        guard foundVersion == version else { throw Failure.unsupportedVersion(foundVersion) }
        let schema = try prepare("SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name LIMIT 4", in: database)
        defer { sqlite3_finalize(schema) }
        for (type, name, sql) in [("table", "source_signatures", SourceSignatureRepository.version3TableSQL),
                                  ("index", "source_signatures_last_seen", SourceSignatureRepository.version3IndexSQL)] {
            guard sqlite3_step(schema) == SQLITE_ROW else { throw Failure.incompatibleSchema }
            var values: [String] = []
            for index: Int32 in 0..<4 {
                guard let bytes = sqlite3_column_text(schema, index) else { throw Failure.incompatibleSchema }
                values.append(String(cString: bytes))
            }
            guard values[0] == type, values[1] == name, values[2] == "source_signatures",
                  SourceSignatureRepository.canonicalSchemaTokens(values[3]) == SourceSignatureRepository.canonicalSchemaTokens(sql) else {
                throw Failure.incompatibleSchema
            }
        }
        let next = sqlite3_step(schema)
        if version == 2, next == SQLITE_ROW {
            // The existing legacy JSON→v2 migration runs PRAGMA optimize, which
            // can create sqlite_stat1. Its canonical derived statistics are safe
            // to discard while rebuilding the same index; never copy them into
            // the strict v3 schema. No arbitrary sqlite_* object is admitted.
            let expected = ["table", "sqlite_stat1", "sqlite_stat1", "CREATE TABLE sqlite_stat1(tbl,idx,stat)"]
            for index: Int32 in 0..<4 {
                guard let bytes = sqlite3_column_text(schema, index) else { throw Failure.incompatibleSchema }
                let value = String(cString: bytes)
                if index == 3 {
                    guard SourceSignatureRepository.canonicalSchemaTokens(value)
                        == SourceSignatureRepository.canonicalSchemaTokens(expected[Int(index)]) else { throw Failure.incompatibleSchema }
                } else if value != expected[Int(index)] { throw Failure.incompatibleSchema }
            }
            guard sqlite3_step(schema) == SQLITE_DONE else { throw Failure.incompatibleSchema }
        } else if next != SQLITE_DONE { throw Failure.incompatibleSchema }
    }
    private static func text(_ statement: OpaquePointer, column: Int32, limits: Limits) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { throw Failure.invalidRow }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= limits.maximumTextBytes else { throw Failure.textLimit }
        guard let bytes = sqlite3_column_text(statement, column) else { throw Failure.invalidRow }
        let data = Data(bytes: bytes, count: count)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw Failure.invalidRow }
        return text
    }
    private static func validSourceKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        var index = 0
        var fields: [String] = []
        for _ in 0..<6 {
            var length = 0
            var digits = 0
            while index < bytes.count, (48...57).contains(bytes[index]) {
                digits += 1
                guard digits <= 7 else { return false }
                length = length * 10 + Int(bytes[index] - 48)
                index += 1
            }
            guard digits > 0, index < bytes.count, bytes[index] == 58 else { return false }
            index += 1
            guard length <= bytes.count - index,
                  let field = String(bytes: bytes[index..<index + length], encoding: .utf8) else { return false }
            fields.append(field)
            index += length
        }
        guard index == bytes.count, let port = Int(fields[3]) else { return false }
        switch fields[0] {
        case "local": return fields[1].hasPrefix("/") && fields[2].isEmpty && port == 0 && fields[4].isEmpty && fields[5].isEmpty
        case "ftp", "ftps", "sftp": return fields[1].isEmpty && !fields[2].isEmpty && (1...65535).contains(port)
        default: return false
        }
    }
    private static func checkIntegrity(_ database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA integrity_check", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0),
              String(cString: value) == "ok", sqlite3_step(statement) == SQLITE_DONE else { throw Failure.integrityFailure }
    }
    private static func integer(_ sql: String, in database: OpaquePointer) throws -> Int64 {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw Failure.incompatibleSchema }
        let value = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.incompatibleSchema }
        return value
    }
    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw Failure.sqlite(status) }
        return statement
    }
    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw Failure.sqlite(status) }
    }
    private static func validateDirectory(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw Failure.unsafeTemporaryDirectory }
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeTemporaryDirectory }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }
    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Failure.fileSystem(errno) }
                offset += written
            }
        }
    }
}
