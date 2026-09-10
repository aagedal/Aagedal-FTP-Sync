import Foundation
import SQLite3
import Darwin

struct SourceFileSignature: Codable, Equatable, Sendable {
    let size: Int64
    let modifiedAt: Date

    init(size: Int64, modifiedAt: Date) {
        self.size = size
        self.modifiedAt = modifiedAt
    }

    init(file: SyncFile) {
        self.init(size: file.size, modifiedAt: file.modifiedAt)
    }

    func matches(_ file: SyncFile, timestampTolerance: TimeInterval = 1.5) -> Bool {
        size == file.size
            && abs(modifiedAt.timeIntervalSince(file.modifiedAt)) <= timestampTolerance
    }
}

private struct SourceSignatureDatabaseError: LocalizedError {
    let operation: String
    let message: String

    var errorDescription: String? {
        "Could not \(operation) saved source signatures: \(message)"
    }
}

actor SourceSignatureRepository {
    private final class DatabaseHandle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit {
            sqlite3_close_v2(pointer)
        }
    }

    private struct SourceIdentity: Codable, Hashable, Sendable {
        let kind: EndpointKind
        let localPath: String
        let host: String
        let port: Int
        let username: String
        let remotePath: String

        init(endpoint: Endpoint) {
            kind = endpoint.kind
            switch endpoint.kind {
            case .local:
                localPath = URL(fileURLWithPath: endpoint.localPath).standardizedFileURL.path
                host = ""
                port = 0
                username = ""
                remotePath = ""
            case .ftp, .ftps, .sftp:
                localPath = ""
                host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                port = endpoint.port
                username = endpoint.username
                let trimmedPath = endpoint.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
                remotePath = trimmedPath.count > 1 && trimmedPath.hasSuffix("/")
                    ? String(trimmedPath.dropLast())
                    : trimmedPath
            }
        }

        /// A length-prefixed representation avoids delimiter and embedded-NUL ambiguity.
        var databaseKey: String {
            [kind.rawValue, localPath, host, String(port), username, remotePath]
                .map { "\($0.utf8.count):\($0)" }
                .joined()
        }
    }

    private struct LegacyKey: Hashable, Sendable {
        let jobID: UUID
        let source: SourceIdentity
        let relativePath: String
    }

    private struct LegacyRecord: Codable, Sendable {
        let jobID: UUID
        let source: SourceIdentity
        let relativePath: String
        let signature: SourceFileSignature

        var key: LegacyKey {
            LegacyKey(jobID: jobID, source: source, relativePath: relativePath)
        }
    }

    /// A missing source is retained long enough for normal server outages and ingest
    /// workflows. If it returns after expiry, the lack of a signature deliberately
    /// takes the existing safe bootstrap-transfer path instead of trusting a rewritten
    /// destination's size.
    static let missingSourceRetention: TimeInterval = 90 * 24 * 60 * 60

    private let databaseURL: URL
    private let legacyFileURL: URL
    private let storageFormat: AppStorageFormat
    private var databaseHandle: DatabaseHandle?

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL? = nil, storage: AppStorageLayout = .legacy) {
        storageFormat = storage.storageFormat
        if let fileURL {
            // A supplied URL remains the store location so test and portable app
            // environments do not need a second configuration value. If it contains
            // v1 JSON in legacy mode, it is atomically replaced with SQLite on
            // first use. Explicit version3 mode never migrates or creates it.
            databaseURL = fileURL
            legacyFileURL = fileURL
        } else {
            databaseURL = storage.sourceSignatures
            legacyFileURL = storage.legacySourceSignatures
        }
    }

    func signature(
        jobID: UUID,
        sourceEndpoint: Endpoint,
        relativePath: String
    ) throws -> SourceFileSignature? {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare(
            """
            SELECT size, modified_at
            FROM source_signatures
            WHERE job_id = ? AND source_key = ? AND relative_path = ?
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(jobID.uuidString, at: 1, to: statement, operation: "look up")
        try bind(SourceIdentity(endpoint: sourceEndpoint).databaseKey, at: 2, to: statement, operation: "look up")
        try bind(relativePath, at: 3, to: statement, operation: "look up")
        return try readSignatureRow(from: statement, operation: "look up")
    }

    /// Returns every signature for maintenance and focused diagnostics. Runtime sync
    /// uses the path-limited overload below so historical records do not determine its
    /// memory use.
    func signatures(jobID: UUID, sourceEndpoint: Endpoint) throws -> [String: SourceFileSignature] {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare(
            """
            SELECT relative_path, size, modified_at
            FROM source_signatures
            WHERE job_id = ? AND source_key = ?
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(jobID.uuidString, at: 1, to: statement, operation: "load")
        try bind(SourceIdentity(endpoint: sourceEndpoint).databaseKey, at: 2, to: statement, operation: "load")
        return try readSignatureRows(from: statement, operation: "load")
    }

    func signatures(
        jobID: UUID,
        sourceEndpoint: Endpoint,
        relativePaths: some Collection<String>
    ) throws -> [String: SourceFileSignature] {
        if storageFormat == .version3 { _ = try openDatabaseIfNeeded() }
        guard !relativePaths.isEmpty else { return [:] }
        let database = try openDatabaseIfNeeded()
        return try inTransaction(database, operation: "load") {
            try replaceTemporaryPaths(
                table: "requested_signature_paths",
                paths: relativePaths,
                database: database,
                operation: "load"
            )
            let statement = try prepare(
                """
                SELECT signatures.relative_path, signatures.size, signatures.modified_at
                FROM source_signatures AS signatures
                INNER JOIN requested_signature_paths AS requested
                    ON requested.relative_path = signatures.relative_path
                WHERE signatures.job_id = ? AND signatures.source_key = ?
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(jobID.uuidString, at: 1, to: statement, operation: "load")
            try bind(SourceIdentity(endpoint: sourceEndpoint).databaseKey, at: 2, to: statement, operation: "load")
            return try readSignatureRows(from: statement, operation: "load")
        }
    }

    func record(_ file: SyncFile, jobID: UUID, sourceEndpoint: Endpoint) throws {
        try record([file], jobID: jobID, sourceEndpoint: sourceEndpoint)
    }

    func record(_ files: [SyncFile], jobID: UUID, sourceEndpoint: Endpoint) throws {
        if storageFormat == .version3 { _ = try openDatabaseIfNeeded() }
        guard !files.isEmpty else { return }
        let database = try openDatabaseIfNeeded()
        let sourceKey = SourceIdentity(endpoint: sourceEndpoint).databaseKey
        let observedAt = Date().timeIntervalSince1970
        try inTransaction(database, operation: "save") {
            let statement = try prepare(
                """
                INSERT INTO source_signatures (
                    job_id, source_key, relative_path, size, modified_at, last_seen_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id, source_key, relative_path) DO UPDATE SET
                    size = excluded.size,
                    modified_at = excluded.modified_at,
                    last_seen_at = MAX(source_signatures.last_seen_at, excluded.last_seen_at)
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }
            for file in files {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(jobID.uuidString, at: 1, to: statement, operation: "save")
                try bind(sourceKey, at: 2, to: statement, operation: "save")
                try bind(file.relativePath, at: 3, to: statement, operation: "save")
                try bind(file.size, at: 4, to: statement, operation: "save")
                try bind(file.modifiedAt.timeIntervalSince1970, at: 5, to: statement, operation: "save")
                try bind(observedAt, at: 6, to: statement, operation: "save")
                try stepToCompletion(statement, in: database, operation: "save")
            }
        }
    }

    /// Reconciles persisted history only after both endpoint listings are authoritative.
    /// Records absent from both sides are immediately irrelevant. A record whose source
    /// is absent but whose transformed destination remains is retained for the grace
    /// period; expiry falls back to a safe bootstrap transfer if that source later returns.
    func reconcile(
        jobID: UUID,
        sourceEndpoint: Endpoint,
        sourceRelativePaths: some Collection<String>,
        destinationRelativePaths: some Collection<String>,
        observedAt: Date = Date()
    ) throws {
        let database = try openDatabaseIfNeeded()
        let sourceKey = SourceIdentity(endpoint: sourceEndpoint).databaseKey
        try inTransaction(database, operation: "reconcile") {
            try replaceTemporaryPaths(
                table: "current_source_paths",
                paths: sourceRelativePaths,
                database: database,
                operation: "reconcile"
            )
            try replaceTemporaryPaths(
                table: "current_destination_paths",
                paths: destinationRelativePaths,
                database: database,
                operation: "reconcile"
            )

            let update = try prepare(
                """
                UPDATE source_signatures
                SET last_seen_at = ?
                WHERE job_id = ? AND source_key = ?
                  AND relative_path IN (SELECT relative_path FROM current_source_paths)
                """,
                in: database
            )
            defer { sqlite3_finalize(update) }
            try bind(observedAt.timeIntervalSince1970, at: 1, to: update, operation: "reconcile")
            try bind(jobID.uuidString, at: 2, to: update, operation: "reconcile")
            try bind(sourceKey, at: 3, to: update, operation: "reconcile")
            try stepToCompletion(update, in: database, operation: "reconcile")

            let removeIrrelevant = try prepare(
                """
                DELETE FROM source_signatures
                WHERE job_id = ? AND source_key = ?
                  AND relative_path NOT IN (SELECT relative_path FROM current_source_paths)
                  AND relative_path NOT IN (SELECT relative_path FROM current_destination_paths)
                """,
                in: database
            )
            defer { sqlite3_finalize(removeIrrelevant) }
            try bind(jobID.uuidString, at: 1, to: removeIrrelevant, operation: "reconcile")
            try bind(sourceKey, at: 2, to: removeIrrelevant, operation: "reconcile")
            try stepToCompletion(removeIrrelevant, in: database, operation: "reconcile")

            let removeExpired = try prepare(
                """
                DELETE FROM source_signatures
                WHERE job_id = ? AND source_key = ? AND last_seen_at < ?
                  AND relative_path NOT IN (SELECT relative_path FROM current_source_paths)
                """,
                in: database
            )
            defer { sqlite3_finalize(removeExpired) }
            try bind(jobID.uuidString, at: 1, to: removeExpired, operation: "reconcile")
            try bind(sourceKey, at: 2, to: removeExpired, operation: "reconcile")
            try bind(
                observedAt.timeIntervalSince1970 - Self.missingSourceRetention,
                at: 3,
                to: removeExpired,
                operation: "reconcile"
            )
            try stepToCompletion(removeExpired, in: database, operation: "reconcile")
        }
    }

    func pruneSignatures(jobID: UUID, retainingSourceEndpoints sourceEndpoints: [Endpoint]) throws {
        let database = try openDatabaseIfNeeded()
        let retainedKeys = sourceEndpoints.map { SourceIdentity(endpoint: $0).databaseKey }
        try inTransaction(database, operation: "clean up") {
            try replaceTemporaryValues(
                table: "retained_source_keys",
                column: "source_key",
                values: retainedKeys,
                database: database,
                operation: "clean up"
            )
            let statement = try prepare(
                """
                DELETE FROM source_signatures
                WHERE job_id = ?
                  AND source_key NOT IN (SELECT source_key FROM retained_source_keys)
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(jobID.uuidString, at: 1, to: statement, operation: "clean up")
            try stepToCompletion(statement, in: database, operation: "clean up")
        }
    }

    func removeSignatures(jobID: UUID) throws {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare(
            "DELETE FROM source_signatures WHERE job_id = ?",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(jobID.uuidString, at: 1, to: statement, operation: "remove")
        try stepToCompletion(statement, in: database, operation: "remove")
    }

    enum SnapshotError: Error, Equatable {
        case databaseNotOpen, invalidOptions, unsafeDestination, destinationExists
        case deadlineExceeded, sizeLimitExceeded, invalidSnapshot
        case fileSystem(Int32)
    }

    struct SnapshotReceipt: Equatable, Sendable {
        let schemaVersion: Int
        let recordCount: Int64
        let byteCount: Int64
    }

    private final class SnapshotDeadline {
        let expires: UInt64
        init(timeout: TimeInterval) {
            expires = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        }
        var expired: Bool { DispatchTime.now().uptimeNanoseconds >= expires }
        func check() throws {
            if expired { throw SnapshotError.deadlineExceeded }
            try Task.checkCancellation()
        }
    }

    /// Exports the already-open repository's committed read snapshot, including WAL
    /// records, without checkpointing, reopening or migrating the source. The caller
    /// must first reconcile legacy storage normally and exclude ALL app writers for
    /// a consistent multi-store migration; actor exclusion covers this repository only.
    ///
    /// The destination must be absent in an existing trusted, stable, non-symlinked
    /// directory (including its ancestors). This does not defend against a malicious
    /// same-user process renaming those ancestors concurrently. A private stage is
    /// validated, closed and synchronized before exclusive publication. Never replace
    /// an existing destination or companions. No normal startup path calls this API.
    ///
    /// The deadline bounds SQLite work/retries, with checks between filesystem calls;
    /// it cannot interrupt a kernel filesystem operation. A failure after publication
    /// (e.g. parent fsync) can leave the complete destination; it is never erased.
    func snapshot(
        to destinationURL: URL,
        timeout: TimeInterval = 5,
        maximumBytes: Int64 = 256 * 1024 * 1024
    ) throws -> SnapshotReceipt {
        guard timeout.isFinite, timeout > 0, timeout <= 60, maximumBytes > 0 else {
            throw SnapshotError.invalidOptions
        }
        guard let source = databaseHandle?.pointer else { throw SnapshotError.databaseNotOpen }
        let deadline = SnapshotDeadline(timeout: timeout)
        try deadline.check()
        try validateSnapshotDestination(destinationURL)
        let parent = destinationURL.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".source-signature-snapshot-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw SnapshotError.fileSystem(errno) }
        defer { try? FileManager.default.removeItem(at: stage) }
        let stagedURL = stage.appendingPathComponent("snapshot.sqlite3")
        let descriptor = Darwin.open(stagedURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotError.fileSystem(errno) }
        defer { Darwin.close(descriptor) }

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(stagedURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let destination = opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw SnapshotError.invalidSnapshot
        }
        var destinationClosed = false
        defer { if !destinationClosed { sqlite3_close_v2(destination) } }
        let context = Unmanaged.passUnretained(deadline).toOpaque()
        for connection in [source, destination] {
            sqlite3_busy_timeout(connection, 0)
            sqlite3_progress_handler(connection, 1000, { context in
                guard let context else { return 1 }
                return Unmanaged<SnapshotDeadline>.fromOpaque(context).takeUnretainedValue().expired
                    || Task<Never, Never>.isCancelled ? 1 : 0
            }, context)
        }
        defer {
            sqlite3_progress_handler(source, 0, nil, nil)
            sqlite3_busy_timeout(source, 5000)
            if !destinationClosed { sqlite3_progress_handler(destination, 0, nil, nil) }
            // Keep the callback context alive until both handlers have been removed.
            withExtendedLifetime(deadline) {}
        }
        do {
            try execute("BEGIN", in: source, operation: "begin snapshot of")
            defer {
                // The read transaction never changes source data. Disable timeout
                // interruption before releasing it even on cancellation/failure.
                sqlite3_progress_handler(source, 0, nil, nil)
                try? execute("ROLLBACK", in: source, operation: "finish snapshot of")
            }
            // The first read pins the WAL snapshot before backup steps; outside
            // writers cannot make the incremental backup restart indefinitely.
            guard try snapshotInteger("PRAGMA user_version", in: source) == expectedSchemaVersion else {
                throw SnapshotError.invalidSnapshot
            }
            let pages = try snapshotInteger("PRAGMA page_count", in: source)
            let pageSize = try snapshotInteger("PRAGMA page_size", in: source)
            guard pages > 0, pageSize > 0, pages <= maximumBytes / pageSize else {
                throw SnapshotError.sizeLimitExceeded
            }
            try deadline.check()
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
                throw sqliteError(operation: "snapshot", database: destination)
            }
            var backupFinished = false
            defer { if !backupFinished { sqlite3_backup_finish(backup) } }
            while true {
                try deadline.check()
                let step = sqlite3_backup_step(backup, 128)
                guard Int64(sqlite3_backup_pagecount(backup)) <= maximumBytes / pageSize else {
                    throw SnapshotError.sizeLimitExceeded
                }
                if step == SQLITE_DONE { break }
                guard step == SQLITE_OK || step == SQLITE_BUSY || step == SQLITE_LOCKED else {
                    throw sqliteError(operation: "snapshot", database: destination)
                }
                if step != SQLITE_OK { sqlite3_sleep(10) }
            }
            let finish = sqlite3_backup_finish(backup)
            backupFinished = true
            guard finish == SQLITE_OK else { throw sqliteError(operation: "snapshot", database: destination) }
            try deadline.check()
            try execute("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL", in: destination, operation: "seal snapshot of")
            let count = try validateSignatureSnapshot(destination)
            try deadline.check()
            sqlite3_progress_handler(destination, 0, nil, nil)
            guard sqlite3_close(destination) == SQLITE_OK else {
                throw sqliteError(operation: "close snapshot of", database: destination)
            }
            destinationClosed = true
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw SnapshotError.fileSystem(errno) }
            guard info.st_size > 0, info.st_size <= maximumBytes else { throw SnapshotError.sizeLimitExceeded }
            guard fsync(descriptor) == 0 else { throw SnapshotError.fileSystem(errno) }
            try deadline.check()
            try validateSnapshotDestination(destinationURL)
            guard renamex_np(stagedURL.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw SnapshotError.destinationExists }
                throw SnapshotError.fileSystem(errno)
            }
            // Synchronize both sides of the rename before deleting our empty stage.
            for directory in [stage, parent] {
                let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw SnapshotError.fileSystem(errno) }
                let syncResult = fsync(fd)
                let failure = errno
                Darwin.close(fd)
                guard syncResult == 0 else { throw SnapshotError.fileSystem(failure) }
            }
            return SnapshotReceipt(schemaVersion: Int(expectedSchemaVersion), recordCount: count, byteCount: info.st_size)
        } catch {
            try deadline.check()
            throw error
        }
    }

    private func validateSnapshotDestination(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0),
              !url.lastPathComponent.isEmpty, url.lastPathComponent != "/",
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw SnapshotError.unsafeDestination
        }
        var ancestor = url.deletingLastPathComponent()
        while true {
            var info = stat()
            guard lstat(ancestor.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else { throw SnapshotError.unsafeDestination }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
        for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"] {
            var info = stat()
            if lstat(path, &info) == 0 { throw SnapshotError.destinationExists }
            guard errno == ENOENT else { throw SnapshotError.fileSystem(errno) }
        }
    }

    private func snapshotInteger(_ sql: String, in database: OpaquePointer) throws -> Int64 {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw SnapshotError.invalidSnapshot }
        let result = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SnapshotError.invalidSnapshot }
        return result
    }

    private var expectedSchemaVersion: Int64 { storageFormat == .version3 ? 3 : 2 }

    private func validateSignatureSnapshot(_ database: OpaquePointer) throws -> Int64 {
        if storageFormat == .version3 { try validateVersion3Schema(database) }
        guard try snapshotInteger("PRAGMA user_version", in: database) == expectedSchemaVersion else {
            throw SnapshotError.invalidSnapshot
        }
        let integrity = try prepare("PRAGMA integrity_check", in: database)
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_step(integrity) == SQLITE_ROW,
              let bytes = sqlite3_column_text(integrity, 0), String(cString: bytes) == "ok",
              sqlite3_step(integrity) == SQLITE_DONE else { throw SnapshotError.invalidSnapshot }
        let columns = try prepare("PRAGMA table_info(source_signatures)", in: database)
        defer { sqlite3_finalize(columns) }
        let expected = [("job_id", "TEXT", 1), ("source_key", "TEXT", 2), ("relative_path", "TEXT", 3),
                        ("size", "INTEGER", 0), ("modified_at", "REAL", 0), ("last_seen_at", "REAL", 0)]
        for (name, type, primaryKey) in expected {
            guard sqlite3_step(columns) == SQLITE_ROW,
                  let nameBytes = sqlite3_column_text(columns, 1), String(cString: nameBytes) == name,
                  let typeBytes = sqlite3_column_text(columns, 2), String(cString: typeBytes) == type,
                  sqlite3_column_int(columns, 3) == 1,
                  sqlite3_column_int(columns, 5) == primaryKey else { throw SnapshotError.invalidSnapshot }
        }
        guard sqlite3_step(columns) == SQLITE_DONE else { throw SnapshotError.invalidSnapshot }
        return try snapshotInteger("SELECT count(*) FROM source_signatures", in: database)
    }

    private func openDatabaseIfNeeded() throws -> OpaquePointer {
        if let databaseHandle { return databaseHandle.pointer }
        if storageFormat == .version3 { return try openVersion3Database() }
        try prepareStorageIfNeeded()
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the database."
            if let database { sqlite3_close_v2(database) }
            throw SourceSignatureDatabaseError(operation: "open", message: message)
        }
        do {
            try execute("PRAGMA journal_mode = WAL", in: database, operation: "configure")
            try execute("PRAGMA synchronous = FULL", in: database, operation: "configure")
            try execute("PRAGMA busy_timeout = 5000", in: database, operation: "configure")
            try createSchema(in: database)
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
        databaseHandle = DatabaseHandle(database)
        return database
    }

    enum Version3OpenError: Error, Equatable {
        case missingDatabase, unsafeDatabase, invalidDatabase, incompatibleSchema, inspectionTimedOut
        case applicationIDMismatch(Int64), unsupportedSchemaVersion(Int64)
    }

    static let version3ApplicationID: Int64 = 0x41465333 // "AFS3", source-signature store in the v3 boundary.
    static let version3TableSQL = """
        CREATE TABLE source_signatures (
            job_id TEXT NOT NULL,
            source_key TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            PRIMARY KEY (job_id, source_key, relative_path)
        ) WITHOUT ROWID
        """
    static let version3IndexSQL = "CREATE INDEX source_signatures_last_seen ON source_signatures (job_id, source_key, last_seen_at)"

    /// Converter contract, not an automatic initializer: execute only in a newly
    /// created, empty disposable migration stage whose ownership was established
    /// separately. Then insert validated legacy records and validate/close/fsync
    /// that stage before installation. Existing v2 files require an explicit
    /// converter; changing their marker in place is not a supported upgrade.
    static let version3InitializationSQL = """
        \(version3TableSQL);
        \(version3IndexSQL);
        PRAGMA application_id = \(version3ApplicationID);
        PRAGMA user_version = 3;
        """

    /// Strict admission is opt-in. Its directory/ancestors and companion files must
    /// be trusted and stable; callers must exclude other app processes/migrations
    /// for the repository lifetime. Admission validates newly opened handles, not
    /// external replacement/schema changes while the cached live handle is open.
    /// Read-only inspection sees committed WAL contents and never checkpoints or
    /// runs legacy repair. SQLite may maintain its shared-memory coordination file;
    /// the database and WAL records remain read-only during rejected admission.
    private func openVersion3Database() throws -> OpaquePointer {
        try validateVersion3Paths()
        let inspection = try openExistingVersion3Connection(readOnly: true)
        do {
            try inspectVersion3Schema(inspection)
        } catch {
            sqlite3_close_v2(inspection)
            throw error
        }
        sqlite3_close_v2(inspection)
        // Revalidate using the actual writable handle before write PRAGMAs. This
        // catches observed replacement, but is not a cross-process writer lock.
        try validateVersion3Paths()
        let database = try openExistingVersion3Connection(readOnly: false)
        do {
            try inspectVersion3Schema(database)
            try execute("PRAGMA journal_mode = WAL", in: database, operation: "configure")
            try execute("PRAGMA synchronous = FULL", in: database, operation: "configure")
            try execute("PRAGMA busy_timeout = 5000", in: database, operation: "configure")
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
        databaseHandle = DatabaseHandle(database)
        return database
    }

    private func openExistingVersion3Connection(readOnly: Bool) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &connection,
            (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw Version3OpenError.invalidDatabase
        }
        return connection
    }

    private func inspectVersion3Schema(_ database: OpaquePointer) throws {
        // Schema inspection has no busy retries and bounds both metadata size and
        // VM work. A locked/oversized/unreadable store fails rather than being fixed.
        let deadline = SnapshotDeadline(timeout: 5)
        let priorLength = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_048_576)
        defer { sqlite3_limit(database, SQLITE_LIMIT_LENGTH, priorLength) }
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<SnapshotDeadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            try? execute("ROLLBACK", in: database, operation: "finish inspection of")
            withExtendedLifetime(deadline) {}
        }
        do {
            try execute("BEGIN", in: database, operation: "inspect")
            try validateVersion3Schema(database)
        } catch {
            if deadline.expired { throw Version3OpenError.inspectionTimedOut }
            if let typed = error as? Version3OpenError { throw typed }
            throw Version3OpenError.invalidDatabase
        }
    }

    private func validateVersion3Schema(_ database: OpaquePointer) throws {
        let applicationID = try snapshotInteger("PRAGMA application_id", in: database)
        guard applicationID == Self.version3ApplicationID else { throw Version3OpenError.applicationIDMismatch(applicationID) }
        let version = try snapshotInteger("PRAGMA user_version", in: database)
        guard version == 3 else { throw Version3OpenError.unsupportedSchemaVersion(version) }
        let statement = try prepare("SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name LIMIT 3", in: database)
        defer { sqlite3_finalize(statement) }
        let expected = [("table", "source_signatures", Self.version3TableSQL),
                        ("index", "source_signatures_last_seen", Self.version3IndexSQL)]
        for (type, name, sql) in expected {
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Version3OpenError.incompatibleSchema }
            var columns: [String] = []
            for index: Int32 in 0..<4 {
                guard let value = sqlite3_column_text(statement, index) else { throw Version3OpenError.incompatibleSchema }
                columns.append(String(cString: value))
            }
            // Deliberately require the converter's exact schema (ignoring only
            // casing/whitespace/statement terminators), including primary/index
            // column order, affinity, collation, constraints and WITHOUT ROWID.
            guard columns[0] == type, columns[1] == name, columns[2] == "source_signatures",
                  Self.canonicalSchemaTokens(columns[3]) == Self.canonicalSchemaTokens(sql) else { throw Version3OpenError.incompatibleSchema }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Version3OpenError.incompatibleSchema }
    }

    static func canonicalSchemaTokens(_ sql: String) -> [String]? {
        // The converter schema is ASCII. Unicode "whitespace" can be an
        // SQLite identifier character, so it must never disappear here.
        guard sql.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        var tokens: [String] = []
        var word = ""
        for scalar in sql.lowercased().unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar == "_" {
                word.unicodeScalars.append(scalar)
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { tokens.append(String(scalar)) }
            }
        }
        if !word.isEmpty { tokens.append(word) }
        if tokens.last == ";" { tokens.removeLast() }
        return tokens
    }

    private func validateVersion3Paths() throws {
        guard databaseURL.isFileURL, !databaseURL.path.utf8.contains(0),
              databaseURL.host == nil || databaseURL.host == "" || databaseURL.host == "localhost",
              databaseURL.query == nil, databaseURL.fragment == nil,
              !databaseURL.pathComponents.contains(".."), !databaseURL.pathComponents.contains(".") else {
            throw Version3OpenError.unsafeDatabase
        }
        var info = stat()
        guard lstat(databaseURL.path, &info) == 0 else {
            if errno == ENOENT { throw Version3OpenError.missingDatabase }
            throw Version3OpenError.unsafeDatabase
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Version3OpenError.unsafeDatabase }
        var directory = databaseURL.deletingLastPathComponent()
        while true {
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Version3OpenError.unsafeDatabase }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            if lstat(databaseURL.path + suffix, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Version3OpenError.unsafeDatabase }
            } else if errno != ENOENT { throw Version3OpenError.unsafeDatabase }
        }
    }

    private func createSchema(in database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS source_signatures (
                job_id TEXT NOT NULL,
                source_key TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                PRIMARY KEY (job_id, source_key, relative_path)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS source_signatures_last_seen
                ON source_signatures (job_id, source_key, last_seen_at);
            PRAGMA user_version = 2;
            """,
            in: database,
            operation: "prepare"
        )
    }

    private func prepareStorageIfNeeded() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: databaseURL.path) {
            guard !(try hasSQLiteHeader(at: databaseURL)) else { return }
            try migrateLegacyJSON(from: databaseURL)
            return
        }

        if fileManager.fileExists(atPath: legacyFileURL.path) {
            try migrateLegacyJSON(from: legacyFileURL)
            return
        }

        let interruptedBackup = databaseURL.appendingPathExtension("pre-sqlite-backup")
        if fileManager.fileExists(atPath: interruptedBackup.path) {
            try migrateLegacyJSON(from: interruptedBackup)
        }
    }

    private func hasSQLiteHeader(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        return header == Data("SQLite format 3\0".utf8)
    }

    private func migrateLegacyJSON(from sourceURL: URL) throws {
        let records: [LegacyRecord]
        do {
            records = try decodeLegacyRecords(at: sourceURL)
        } catch let primaryError {
            let backup = sourceURL.appendingPathExtension("backup")
            guard FileManager.default.fileExists(atPath: backup.path) else { throw primaryError }
            do {
                records = try decodeLegacyRecords(at: backup)
            } catch {
                throw primaryError
            }
        }

        let uniqueRecords = Dictionary(
            records.map { ($0.key, $0) },
            uniquingKeysWith: { _, newest in newest }
        ).values
        let fileManager = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = databaseURL.appendingPathExtension("migration-in-progress")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        var migrationDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            temporaryURL.path,
            &migrationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let migrationDatabase else {
            let message = migrationDatabase.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite could not create the migration database."
            if let migrationDatabase { sqlite3_close_v2(migrationDatabase) }
            throw SourceSignatureDatabaseError(operation: "migrate", message: message)
        }

        do {
            try execute("PRAGMA journal_mode = DELETE", in: migrationDatabase, operation: "migrate")
            try execute("PRAGMA synchronous = FULL", in: migrationDatabase, operation: "migrate")
            try createSchema(in: migrationDatabase)
            let migratedAt = Date().timeIntervalSince1970
            try inTransaction(migrationDatabase, operation: "migrate") {
                let statement = try prepare(
                    """
                    INSERT OR REPLACE INTO source_signatures (
                        job_id, source_key, relative_path, size, modified_at, last_seen_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    in: migrationDatabase
                )
                defer { sqlite3_finalize(statement) }
                for record in uniqueRecords {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(record.jobID.uuidString, at: 1, to: statement, operation: "migrate")
                    try bind(record.source.databaseKey, at: 2, to: statement, operation: "migrate")
                    try bind(record.relativePath, at: 3, to: statement, operation: "migrate")
                    try bind(record.signature.size, at: 4, to: statement, operation: "migrate")
                    try bind(record.signature.modifiedAt.timeIntervalSince1970, at: 5, to: statement, operation: "migrate")
                    try bind(migratedAt, at: 6, to: statement, operation: "migrate")
                    try stepToCompletion(statement, in: migrationDatabase, operation: "migrate")
                }
            }
            try execute("PRAGMA optimize", in: migrationDatabase, operation: "migrate")
        } catch {
            sqlite3_close_v2(migrationDatabase)
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        guard sqlite3_close_v2(migrationDatabase) == SQLITE_OK else {
            try? fileManager.removeItem(at: temporaryURL)
            throw SourceSignatureDatabaseError(operation: "migrate", message: "SQLite could not finalize the migrated database.")
        }

        do {
            if sourceURL.standardizedFileURL == databaseURL.standardizedFileURL {
                let backupURL = databaseURL.appendingPathExtension("pre-sqlite-backup")
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                _ = try fileManager.replaceItemAt(
                    databaseURL,
                    withItemAt: temporaryURL,
                    backupItemName: backupURL.lastPathComponent,
                    options: .withoutDeletingBackupItem
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: databaseURL)
                let backupURL = sourceURL.appendingPathExtension("migrated-backup")
                if !fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.moveItem(at: sourceURL, to: backupURL)
                }
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func decodeLegacyRecords(at url: URL) throws -> [LegacyRecord] {
        let data = try Data(contentsOf: url)
        return try Self.legacyDecoder.decode([LegacyRecord].self, from: data)
    }

    private func replaceTemporaryPaths(
        table: String,
        paths: some Collection<String>,
        database: OpaquePointer,
        operation: String
    ) throws {
        try replaceTemporaryValues(
            table: table,
            column: "relative_path",
            values: paths,
            database: database,
            operation: operation
        )
    }

    private func replaceTemporaryValues(
        table: String,
        column: String,
        values: some Collection<String>,
        database: OpaquePointer,
        operation: String
    ) throws {
        // Table and column names are private constants from call sites, never input.
        try execute(
            "CREATE TEMP TABLE IF NOT EXISTS \(table) (\(column) TEXT PRIMARY KEY) WITHOUT ROWID",
            in: database,
            operation: operation
        )
        try execute("DELETE FROM \(table)", in: database, operation: operation)
        let statement = try prepare(
            "INSERT OR IGNORE INTO \(table) (\(column)) VALUES (?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        for value in values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(value, at: 1, to: statement, operation: operation)
            try stepToCompletion(statement, in: database, operation: operation)
        }
    }

    private func readSignatureRow(
        from statement: OpaquePointer,
        operation: String
    ) throws -> SourceFileSignature? {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return SourceFileSignature(
                size: sqlite3_column_int64(statement, 0),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            )
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError(operation: operation, database: sqlite3_db_handle(statement))
        }
    }

    private func readSignatureRows(
        from statement: OpaquePointer,
        operation: String
    ) throws -> [String: SourceFileSignature] {
        var signatures: [String: SourceFileSignature] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return signatures }
            guard result == SQLITE_ROW, let pathBytes = sqlite3_column_text(statement, 0) else {
                throw sqliteError(operation: operation, database: sqlite3_db_handle(statement))
            }
            signatures[String(cString: pathBytes)] = SourceFileSignature(
                size: sqlite3_column_int64(statement, 1),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        }
    }

    private func inTransaction<T>(
        _ database: OpaquePointer,
        operation: String,
        body: () throws -> T
    ) throws -> T {
        try execute("BEGIN IMMEDIATE", in: database, operation: operation)
        do {
            let result = try body()
            try execute("COMMIT", in: database, operation: operation)
            return result
        } catch {
            try? execute("ROLLBACK", in: database, operation: operation)
            throw error
        }
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(operation: "prepare", database: database)
        }
        return statement
    }

    private func execute(_ sql: String, in database: OpaquePointer, operation: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SourceSignatureDatabaseError(operation: operation, message: message)
        }
    }

    private func stepToCompletion(
        _ statement: OpaquePointer,
        in database: OpaquePointer,
        operation: String
    ) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(operation: operation, database: database)
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer, operation: String) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw sqliteError(operation: operation, database: sqlite3_db_handle(statement))
        }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer, operation: String) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw sqliteError(operation: operation, database: sqlite3_db_handle(statement))
        }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer, operation: String) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw sqliteError(operation: operation, database: sqlite3_db_handle(statement))
        }
    }

    private func sqliteError(operation: String, database: OpaquePointer?) -> SourceSignatureDatabaseError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error."
        return SourceSignatureDatabaseError(operation: operation, message: message)
    }

    private static var legacyDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
