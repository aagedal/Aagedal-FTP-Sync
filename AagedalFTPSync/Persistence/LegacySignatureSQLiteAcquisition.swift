import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Explicit pre-constructor acquisition. The caller must exclude all writers and
/// older processes throughout acquisition and subsequent cross-store migration.
/// Source directories must remain trusted/stable; inode/hash checks detect ordinary
/// changes, not hostile filesystem replacement. No repository initialization occurs.
enum LegacySignatureSQLiteAcquisition {
    struct Limits: Sendable {
        var maximumBytes = 256 * 1024 * 1024
        var maximumRecords = 2_000_000
        var timeout: TimeInterval = 10
    }
    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let sha256: String
    }
    struct Output: Equatable, Sendable {
        let data: Data
        let recordCount: Int
        let main: CapturedFile
        let wal: CapturedFile?
        let shm: CapturedFile?
    }
    struct CapturedFile: Equatable, Sendable {
        let identity: FileIdentity
        let data: Data
    }
    enum Failure: Error, Equatable {
        case invalidLimits, unsafePath, missingSource, unsupportedCompanions, sourceChanged
        case byteLimit, recordLimit, deadlineExceeded, incompatibleSchema, integrityFailure, invalidWAL
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
    private struct Files: Equatable {
        let main: CapturedFile
        let wal: CapturedFile?
        let shm: CapturedFile?
    }
    private struct Node: Equatable {
        let device: UInt64, inode: UInt64
        let size: Int64
        let seconds: Int64, nanoseconds: Int64
        init(_ info: stat) {
            device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = info.st_size
            seconds = Int64(info.st_mtimespec.tv_sec); nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }
    }
    private final class Connection {
        let pointer: OpaquePointer
        private var closed = false
        init(_ url: URL, readOnly: Bool, immutable: Bool = false, deadline: Deadline) throws {
            var handle: OpaquePointer?
            let name = immutable ? url.absoluteString + "?immutable=1" : url.path
            let code = sqlite3_open_v2(name, &handle,
                (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX | (immutable ? SQLITE_OPEN_URI : 0), nil)
            guard code == SQLITE_OK, let handle else {
                if let handle { sqlite3_close_v2(handle) }
                throw Failure.sqlite(code)
            }
            pointer = handle
            sqlite3_busy_timeout(handle, 0)
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 4 * 1024 * 1024)
            sqlite3_progress_handler(handle, 1000, { context in
                guard let context else { return 1 }
                let deadline = Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue()
                return deadline.expired || Task<Never, Never>.isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(deadline).toOpaque())
        }
        func close() throws {
            guard !closed else { return }
            let code = sqlite3_close(pointer)
            guard code == SQLITE_OK else { throw Failure.sqlite(code) }
            closed = true
        }
        deinit { if !closed { sqlite3_close_v2(pointer) } }
    }

    /// Captures original main/WAL/optional SHM bytes using read-only descriptors;
    /// copies main and WAL together into a private stage before SQLite opens them.
    /// SQLite reads committed WAL frames from that copy and may rebuild SHM only
    /// inside the stage. Original files are never opened by SQLite, repaired,
    /// checkpointed or written; every original byte and companion presence is
    /// rechecked. Any rollback journal is rejected without recovery. Captured
    /// original bytes are returned for retention, separately from the standalone
    /// v2 snapshot. The caller must retain them under its migration protocol.
    /// Deadlines bound user-space hashing/SQLite work, not blocked kernel IO calls.
    /// Schema/integrity-checked output still requires converter row validation.
    /// Only our uniquely created private temporary stage is removed.
    static func acquire(sourceURL: URL, temporaryDirectory: URL, limits: Limits = Limits()) throws -> Output {
        guard (4096...1_073_741_824).contains(limits.maximumBytes), (0...10_000_000).contains(limits.maximumRecords),
              limits.timeout.isFinite, limits.timeout > 0, limits.timeout <= 60 else { throw Failure.invalidLimits }
        let deadline = Deadline(limits.timeout)
        try deadline.check()
        try directory(temporaryDirectory)
        try path(sourceURL)
        try directory(sourceURL.deletingLastPathComponent())
        let before = try files(sourceURL, limits: limits, deadline: deadline)
        let stage = temporaryDirectory.appendingPathComponent(".signature-acquisition-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw Failure.fileSystem(errno) }
        defer { try? FileManager.default.removeItem(at: stage) }
        defer { withExtendedLifetime(deadline) {} }
        do {
            let copiedSource = stage.appendingPathComponent("source.sqlite3")
            try writeExclusive(before.main.data, to: copiedSource, deadline: deadline)
            if let wal = before.wal {
                try writeExclusive(wal.data, to: URL(fileURLWithPath: copiedSource.path + "-wal"), deadline: deadline)
            }
            // A clean WAL-mode main may have no WAL after normal checkpoint/close.
            // Immutable is safe ONLY for this private frozen copy with no WAL;
            // otherwise it would silently omit committed WAL frames.
            let source = try Connection(copiedSource, readOnly: true, immutable: before.wal == nil, deadline: deadline)
            guard sqlite3_db_readonly(source.pointer, "main") == 1 else { throw Failure.unsafePath }
            try execute("BEGIN", in: source.pointer)
            var transaction = true
            defer { if transaction { try? execute("ROLLBACK", in: source.pointer) } }
            // First read pins the logical source, including all committed WAL pages.
            try schema(source.pointer)
            let pageSize = try integer("PRAGMA page_size", in: source.pointer)
            let pages = try integer("PRAGMA page_count", in: source.pointer)
            guard pageSize > 0, pages > 0, pages <= Int64(limits.maximumBytes) / pageSize else { throw Failure.byteLimit }
            guard Int64(before.main.data.count) % pageSize == 0,
                  before.wal != nil || pages * pageSize == before.main.data.count else { throw Failure.integrityFailure }
            let count = try integer("SELECT count(*) FROM source_signatures", in: source.pointer)
            guard count >= 0, count <= limits.maximumRecords else { throw Failure.recordLimit }
            try deadline.check()
            let destinationURL = stage.appendingPathComponent("snapshot.sqlite3")
            let descriptor = Darwin.open(destinationURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.fileSystem(errno) }
            defer { Darwin.close(descriptor) }
            let destination = try Connection(destinationURL, readOnly: false, deadline: deadline)
            try execute("PRAGMA page_size = \(pageSize); PRAGMA max_page_count = \(limits.maximumBytes / Int(pageSize))", in: destination.pointer)
            guard let backup = sqlite3_backup_init(destination.pointer, "main", source.pointer, "main") else {
                throw Failure.sqlite(sqlite3_errcode(destination.pointer))
            }
            var finished = false
            defer { if !finished { sqlite3_backup_finish(backup) } }
            while true {
                try deadline.check()
                let code = sqlite3_backup_step(backup, 128)
                guard Int64(sqlite3_backup_pagecount(backup)) <= Int64(limits.maximumBytes) / pageSize else { throw Failure.byteLimit }
                if code == SQLITE_DONE { break }
                guard code == SQLITE_OK else { throw Failure.sqlite(code) }
            }
            let finish = sqlite3_backup_finish(backup)
            finished = true
            guard finish == SQLITE_OK else { throw Failure.sqlite(finish) }
            try execute("ROLLBACK", in: source.pointer)
            transaction = false
            try source.close()
            // All mutations below apply solely to the disposable destination.
            try execute("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL", in: destination.pointer)
            try schema(destination.pointer)
            try integrity(destination.pointer)
            guard try integer("SELECT count(*) FROM source_signatures", in: destination.pointer) == count else { throw Failure.integrityFailure }
            try destination.close()
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Failure.fileSystem(errno) }
            guard info.st_size > 0, info.st_size <= limits.maximumBytes else { throw Failure.byteLimit }
            guard fsync(descriptor) == 0 else { throw Failure.fileSystem(errno) }
            let data = try Data(contentsOf: destinationURL)
            guard data.count == info.st_size, data.count >= 100, data[18] == 1, data[19] == 1 else { throw Failure.integrityFailure }
            let after = try files(sourceURL, limits: limits, deadline: deadline)
            guard before == after else { throw Failure.sourceChanged }
            try deadline.check()
            return Output(data: data, recordCount: Int(count), main: before.main, wal: before.wal, shm: before.shm)
        } catch {
            try deadline.check()
            if case Failure.sqlite(SQLITE_FULL) = error { throw Failure.byteLimit }
            throw error
        }
    }

    private static func files(_ url: URL, limits: Limits, deadline: Deadline) throws -> Files {
        guard let mainNode = try node(url) else { throw Failure.missingSource }
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        guard try node(URL(fileURLWithPath: url.path + "-journal")) == nil else { throw Failure.unsupportedCompanions }
        let walNode = try node(walURL), shmNode = try node(shmURL)
        guard shmNode == nil || (walNode != nil && shmNode!.size >= 32768 && shmNode!.size <= 16 * 1024 * 1024) else {
            throw Failure.unsupportedCompanions
        }
        guard mainNode.size >= 100, mainNode.size <= limits.maximumBytes,
              (walNode?.size ?? 0) <= Int64(limits.maximumBytes) - mainNode.size,
              (shmNode?.size ?? 0) <= Int64(limits.maximumBytes) - mainNode.size - (walNode?.size ?? 0) else { throw Failure.byteLimit }
        let main = try identity(url, expected: mainNode, deadline: deadline)
        let wal = try walNode.map { try identity(walURL, expected: $0, deadline: deadline) }
        let shm = try shmNode.map { try identity(shmURL, expected: $0, deadline: deadline) }
        guard main.data.prefix(16) == Data("SQLite format 3\0".utf8),
              [1, 2].contains(main.data[18]), main.data[18] == main.data[19],
              wal == nil || main.data[18] == 2 else { throw Failure.incompatibleSchema }
        if let wal { try validateWAL(wal.data, main: main.data, deadline: deadline) }
        return Files(main: main, wal: wal, shm: shm)
    }
    /// Fail closed on incomplete/corrupt/stale WAL tails rather than letting
    /// SQLite silently ignore evidence. Explicit recovery may later reconcile
    /// such a retained source; this helper never truncates or repairs its bytes.
    private static func validateWAL(_ data: Data, main: Data, deadline: Deadline) throws {
        if data.isEmpty { return }
        guard data.count >= 32 else { throw Failure.invalidWAL }
        func word(_ offset: Int, little: Bool = false) -> UInt32 {
            let bytes = data[offset..<offset + 4]
            return little ? bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
                          : bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let magic = word(0)
        guard magic == 0x377f0682 || magic == 0x377f0683, word(4) == 3_007_000 else { throw Failure.invalidWAL }
        let pageSize = Int(word(8))
        let encodedSize = Int(main[16]) * 256 + Int(main[17])
        let mainPageSize = encodedSize == 1 ? 65_536 : encodedSize
        guard pageSize == mainPageSize, (512...65_536).contains(pageSize), pageSize.nonzeroBitCount == 1,
              (data.count - 32) % (24 + pageSize) == 0 else { throw Failure.invalidWAL }
        let little = magic == 0x377f0682
        var first: UInt32 = 0, second: UInt32 = 0
        func checksum(_ range: Range<Int>) {
            for index in stride(from: range.lowerBound, to: range.upperBound, by: 8) {
                first = first &+ word(index, little: little) &+ second
                second = second &+ word(index + 4, little: little) &+ first
            }
        }
        checksum(0..<24)
        guard first == word(24), second == word(28) else { throw Failure.invalidWAL }
        for offset in stride(from: 32, to: data.count, by: 24 + pageSize) {
            try deadline.check()
            guard word(offset) > 0, word(offset + 8) == word(16), word(offset + 12) == word(20) else { throw Failure.invalidWAL }
            checksum(offset..<offset + 8)
            checksum(offset + 24..<offset + 24 + pageSize)
            guard first == word(offset + 16), second == word(offset + 20) else { throw Failure.invalidWAL }
        }
    }
    private static func identity(_ url: URL, expected: Node, deadline: Deadline) throws -> CapturedFile {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Node(info) == expected else { throw Failure.sourceChanged }
        var hash = SHA256()
        var data = Data()
        data.reserveCapacity(Int(expected.size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var remaining = expected.size
        while remaining > 0 {
            try deadline.check()
            let count = Darwin.read(fd, &buffer, min(buffer.count, Int(remaining)))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure.sourceChanged }
            hash.update(data: buffer.prefix(count))
            data.append(contentsOf: buffer.prefix(count))
            remaining -= Int64(count)
        }
        guard fstat(fd, &info) == 0, Node(info) == expected, try node(url) == expected else { throw Failure.sourceChanged }
        return CapturedFile(identity: FileIdentity(device: expected.device, inode: expected.inode, byteCount: expected.size,
                            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()), data: data)
    }
    private static func writeExclusive(_ data: Data, to url: URL, deadline: Deadline) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try deadline.check()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.fileSystem(errno) }
                offset += count
            }
        }
    }
    private static func node(_ url: URL) throws -> Node? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.fileSystem(errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else { throw Failure.unsafePath }
        return Node(info)
    }
    private static func path(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw Failure.unsafePath }
    }
    private static func directory(_ url: URL) throws {
        try path(url)
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
            if current.path == "/" { return }
            current.deleteLastPathComponent()
        }
    }
    private static func schema(_ database: OpaquePointer) throws {
        let id = try integer("PRAGMA application_id", in: database)
        guard id == 0 else { throw Failure.wrongApplicationID(id) }
        let version = try integer("PRAGMA user_version", in: database)
        guard version == 2 else { throw Failure.unsupportedVersion(version) }
        let statement = try prepare("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY name LIMIT 4", in: database)
        defer { sqlite3_finalize(statement) }
        let expected = [["table", "source_signatures", "source_signatures", SourceSignatureRepository.version3TableSQL],
                        ["index", "source_signatures_last_seen", "source_signatures", SourceSignatureRepository.version3IndexSQL]]
        func match(_ row: [String]) throws {
            for index: Int32 in 0..<4 {
                guard sqlite3_column_type(statement, index) == SQLITE_TEXT else { throw Failure.incompatibleSchema }
                let count = Int(sqlite3_column_bytes(statement, index))
                guard count <= 16_384, let bytes = sqlite3_column_text(statement, index),
                      let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8), !text.utf8.contains(0) else { throw Failure.incompatibleSchema }
                if index == 3 {
                    guard let actual = SourceSignatureRepository.canonicalSchemaTokens(text),
                          actual == SourceSignatureRepository.canonicalSchemaTokens(row[Int(index)]) else { throw Failure.incompatibleSchema }
                } else if text != row[Int(index)] { throw Failure.incompatibleSchema }
            }
        }
        for row in expected {
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.incompatibleSchema }
            try match(row)
        }
        let next = sqlite3_step(statement)
        if next == SQLITE_ROW {
            try match(["table", "sqlite_stat1", "sqlite_stat1", "CREATE TABLE sqlite_stat1(tbl,idx,stat)"])
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.incompatibleSchema }
        } else if next != SQLITE_DONE { throw Failure.incompatibleSchema }
    }
    private static func integrity(_ database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA integrity_check", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok", sqlite3_step(statement) == SQLITE_DONE else { throw Failure.integrityFailure }
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
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw Failure.sqlite(code) }
        return statement
    }
    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw Failure.sqlite(code) }
    }
}
