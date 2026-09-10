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
        case wrongApplicationID(Int64), unsupportedVersion(Int64)
        case sqlite(Int32), fileSystem(Int32)
    }
    private final class Deadline {
        let end: UInt64
        init(_ seconds: TimeInterval) { end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000) }
        var expired: Bool { DispatchTime.now().uptimeNanoseconds >= end }
        func check() throws {
            if expired { throw Failure.deadlineExceeded }
            try Task.checkCancellation()
        }
    }
    private final class Connection {
        let pointer: OpaquePointer
        private var closed = false
        init(_ url: URL, readOnly: Bool, deadline: Deadline, limits: Limits) throws {
            var opened: OpaquePointer?
            let status = sqlite3_open_v2(url.path, &opened,
                (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
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
    /// Deadline checks bound SQLite/row work, not a blocked kernel filesystem call.
    static func convert(_ input: Input, temporaryDirectory: URL, limits: Limits = Limits()) throws -> Output {
        guard (1...1_073_741_824).contains(limits.maximumBytes), (0...10_000_000).contains(limits.maximumRecords),
              (1...1_048_576).contains(limits.maximumTextBytes), limits.timeout.isFinite,
              limits.timeout > 0, limits.timeout <= 60 else { throw Failure.invalidLimits }
        let deadline = Deadline(limits.timeout)
        try deadline.check()
        if case .standaloneSnapshot(let data) = input {
            guard data.count <= limits.maximumBytes else { throw Failure.inputLimit }
            guard data.count >= 100, data.prefix(16) == Data("SQLite format 3\0".utf8),
                  data[data.index(data.startIndex, offsetBy: 18)] == 1, data[data.index(data.startIndex, offsetBy: 19)] == 1 else { throw Failure.notStandaloneSQLite }
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
                        let jobText = try text(read, column: 0, limits: limits)
                        let sourceKey = try text(read, column: 1, limits: limits)
                        let path = try text(read, column: 2, limits: limits)
                        guard let jobID = UUID(uuidString: jobText), validSourceKey(sourceKey), PathSafety.isSafeRelativePath(path),
                              sqlite3_column_type(read, 3) == SQLITE_INTEGER, sqlite3_column_int64(read, 3) >= 0 else {
                            throw Failure.invalidRow
                        }
                        for column: Int32 in [4, 5] {
                            guard [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(read, column)),
                                  sqlite3_column_double(read, column).isFinite else { throw Failure.invalidRow }
                        }
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
