import Foundation
import SQLite3

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
    private var databaseHandle: DatabaseHandle?

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL? = nil) {
        if let fileURL {
            // A supplied URL remains the store location so test and portable app
            // environments do not need a second configuration value. If it contains
            // v1 JSON, it is atomically replaced with the SQLite database on first use.
            databaseURL = fileURL
            legacyFileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AagedalFTPSync", isDirectory: true)
            databaseURL = base.appendingPathComponent("original-source-signatures-v2.sqlite3")
            legacyFileURL = base.appendingPathComponent("original-source-signatures-v1.json")
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

    private func openDatabaseIfNeeded() throws -> OpaquePointer {
        if let databaseHandle { return databaseHandle.pointer }
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
