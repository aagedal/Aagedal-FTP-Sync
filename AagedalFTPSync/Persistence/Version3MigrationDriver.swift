import Darwin
import Foundation

/// Explicit selected-source migration and committed-root admission. The caller
/// must exclude every repository writer and older app process for the whole call.
/// This does not select backups, acquire a lifetime lease, or construct UI/runtime.
struct Version3MigrationDriver: Sendable {
    enum Source: Codable, Equatable, Sendable { case absent, file(String) }
    enum Signatures: Codable, Equatable, Sendable { case absent, json(String), sqlite(String) }
    struct Plan: Sendable {
        let legacyFiles: [String]
        let primarySources: [String: Source]
        let signatures: Signatures
        let calendar: Calendar
        let migrationDate: Date
        var maximumFiles = 8_192
        var maximumBytes = 256 * 1_048_576
    }
    struct SelectionRecord: Codable, Sendable {
        let format: String
        let version: Int
        let primarySources: [String: Source]
        let signatures: Signatures
        let calendarIdentifier: String
        let timeZoneIdentifier: String
        let migrationTimestamp: Double
    }
    struct Admission: Sendable {
        let storage: AppStorageLayout
        let selection: SelectionRecord
        let currentCredentialIDs: Set<String>
        // Retained legacy and earlier failed-migration archives may contain
        // additional/undecodable references. Preserve all obsolete credentials
        // until a separate complete reachability/recovery decision exists.
        let allowsCredentialGarbageCollection = false
    }
    enum Failure: Error, Equatable {
        case invalidPlan, unsafePath, limitExceeded, incompleteInventory(String)
        case missingSelectedSource(String), absentSourceHasRetainedData(String)
        case migrationRequired, alreadyMigrated, invalidStoreSet, invalidSelectionRecord
        case interruptedLegacyMigration
    }

    let root: URL
    let temporaryDirectory: URL
    static let selectionFilename = "migration-source-selection-v3.json"
    private static let namesDirectory = "download-names-v1/"
    private static let signaturesName = "original-source-signatures-v2.sqlite3"
    private static let legacySignaturesName = "original-source-signatures-v1.json"
    private static let registryName = "download-name-registry-v3.json"
    static var fixedLegacyPaths: Set<String> {
        let primaries = Version3JSONStoreConversion.primaryFilenames
        var paths = primaries.union(primaries.map { $0 + ".backup" })
        for base in [signaturesName, legacySignaturesName, signaturesName + ".pre-sqlite-backup"] {
            paths.formUnion([base, base + ".backup", base + ".migrated-backup"])
        }
        paths.formUnion([signaturesName + "-wal", signaturesName + "-shm", signaturesName + "-journal"])
        let interrupted = signaturesName + ".migration-in-progress"
        paths.formUnion([interrupted, interrupted + "-wal", interrupted + "-shm", interrupted + "-journal"])
        return paths
    }

    /// The plan names every primary/backup/companion (including absent files) and
    /// every actual name map. All nine primary selections and the signature source
    /// are explicit; selecting a backup never silently discards its damaged primary.
    /// Original captures and the immutable selection record are committed together.
    func migrateSelectedSources(_ plan: Plan,
                                checkpoint: (VersionedAppStorage.Checkpoint) throws -> Void = { _ in }) throws -> Admission {
        try validatePlan(plan)
        try validateRoot()
        guard !exists(root.appendingPathComponent(".v3-storage-boundary.json")),
              !exists(root.appendingPathComponent("v3")) else { throw Failure.alreadyMigrated }
        try verifyInventory(plan)
        let storage = VersionedAppStorage(root: root)
        var acquisitions: [String: VersionedAppStorage.SQLiteAcquisition] = [:]
        if case .sqlite(let path) = plan.signatures {
            acquisitions[path] = try storage.acquireLegacySQLite(relativePath: path, temporaryDirectory: temporaryDirectory,
                limits: .init(maximumBytes: plan.maximumBytes))
        }
        var frozenCalendar = Calendar(identifier: plan.calendar.identifier)
        frozenCalendar.timeZone = plan.calendar.timeZone
        frozenCalendar.locale = plan.calendar.locale
        frozenCalendar.firstWeekday = plan.calendar.firstWeekday
        frozenCalendar.minimumDaysInFirstWeek = plan.calendar.minimumDaysInFirstWeek
        let record = SelectionRecord(format: "AagedalFTPSync.migration-selection", version: 3,
            primarySources: plan.primarySources, signatures: plan.signatures,
            calendarIdentifier: String(describing: frozenCalendar.identifier), timeZoneIdentifier: frozenCalendar.timeZone.identifier,
            migrationTimestamp: plan.migrationDate.timeIntervalSince1970)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recordBytes = try encoder.encode(record)
        var admitted: (selection: SelectionRecord, credentials: Set<String>)?
        let v3 = try storage.openOrMigrate(plan: .init(legacyFiles: plan.legacyFiles,
            maximumFiles: plan.maximumFiles, maximumBytes: plan.maximumBytes), convert: { files in
            var selected: [String: Data] = [:]
            for (primary, source) in plan.primarySources {
                switch source {
                case .absent:
                    guard files[primary] == nil, files[primary + ".backup"] == nil else {
                        throw Failure.absentSourceHasRetainedData(primary)
                    }
                case .file(let path):
                    guard let data = files[path] else { throw Failure.missingSelectedSource(path) }
                    selected[primary] = data
                }
            }
            let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: selected,
                maximumInputBytes: plan.maximumBytes, implicitTrackCalendar: frozenCalendar)
            var stores = converted.stores
            let signatureInput: Version3SignatureConversion.Input
            switch plan.signatures {
            case .absent:
                guard !files.keys.contains(where: { $0.hasPrefix("original-source-signatures-") }) else {
                    throw Failure.absentSourceHasRetainedData(Self.signaturesName)
                }
                signatureInput = .noLegacyStore
            case .json(let path):
                guard let bytes = files[path] else { throw Failure.missingSelectedSource(path) }
                signatureInput = .legacyJSON(bytes, migratedAt: plan.migrationDate)
            case .sqlite(let path):
                guard let receipt = acquisitions[path] else { throw Failure.invalidPlan }
                signatureInput = .standaloneSnapshot(receipt.output.data)
            }
            stores[Self.signaturesName] = try Version3SignatureConversion.convert(signatureInput,
                temporaryDirectory: temporaryDirectory, limits: .init(maximumBytes: plan.maximumBytes)).data
            var maps: [String: Data] = [:]
            for path in plan.legacyFiles where path.hasPrefix(Self.namesDirectory) {
                guard let bytes = files[path] else { throw Failure.missingSelectedSource(path) }
                maps[String(path.dropFirst(Self.namesDirectory.count))] = bytes
            }
            for (path, bytes) in try DownloadNameMappingRegistry.convertLegacyMappings(maps) {
                guard stores[path] == nil else { throw Failure.invalidStoreSet }
                stores[path] = bytes
            }
            stores[Self.selectionFilename] = recordBytes
            return stores
        }, validate: { files in
            admitted = try Self.validateCurrentSet(files, temporaryDirectory: temporaryDirectory, maximumBytes: plan.maximumBytes)
        }, currentStorePaths: DownloadNameMappingRegistry.currentStorePaths,
           sqliteAcquisitions: acquisitions, immutableStorePaths: [Self.selectionFilename], checkpoint: { stage in
            if case .snapshotCaptured = stage { try verifyInventory(plan) }
            if case .stageValidated = stage { try verifyInventory(plan) }
            try checkpoint(stage)
        })
        // Validation above has already read the exact committed output. Returned
        // credential IDs cover current data; GC remains globally disabled for all
        // retained source references, including archives this plan did not decode.
        guard let admitted else { throw Failure.invalidStoreSet }
        return Admission(storage: AppStorageLayout(root: v3, storageFormat: .version3),
                         selection: admitted.selection, currentCredentialIDs: admitted.credentials)
    }

    /// Finish only the frozen PREPARED installation. Current legacy files are never
    /// recopied; an installed directory uses normal complete current admission.
    func recoverPreparedInstallation() async throws -> Admission {
        try validateRoot()
        if exists(root.appendingPathComponent("v3")) { return try await openCommitted() }
        var admitted: (selection: SelectionRecord, credentials: Set<String>)?
        let v3 = try VersionedAppStorage(root: root).recoverPreparedInstallation(validate: { files in
            admitted = try Self.validateCurrentSet(files, temporaryDirectory: temporaryDirectory)
        }, currentStorePaths: DownloadNameMappingRegistry.currentStorePaths,
           immutableStorePaths: [Self.selectionFilename])
        guard let admitted else { throw Failure.invalidStoreSet }
        return Admission(storage: AppStorageLayout(root: v3, storageFormat: .version3),
                         selection: admitted.selection, currentCredentialIDs: admitted.credentials)
    }

    /// Open only a committed/prepared-installed boundary, never infer new migration
    /// from absence. The registry lock covers actual directory inventory, complete
    /// collection and byte comparison. Caller also excludes all other writers.
    func openCommitted() async throws -> Admission {
        try validateRoot()
        guard exists(root.appendingPathComponent(".v3-storage-boundary.json")) else { throw Failure.migrationRequired }
        let layout = AppStorageLayout(root: root.appendingPathComponent("v3", isDirectory: true), storageFormat: .version3)
        let registry = try DownloadNameMappingRegistry(storage: layout)
        let root = root, temporary = temporaryDirectory
        return try await registry.withValidatedCurrentMappings { snapshot in
            var result: Admission?
            _ = try VersionedAppStorage(root: root).openOrMigrate(plan: .init(legacyFiles: []), convert: { _ in
                throw Failure.migrationRequired
            }, validate: { files in
                for (path, bytes) in snapshot where files[path] != bytes { throw Failure.invalidStoreSet }
                let current = try Self.validateCurrentSet(files, temporaryDirectory: temporary)
                result = Admission(storage: layout, selection: current.selection, currentCredentialIDs: current.credentials)
            }, currentStorePaths: DownloadNameMappingRegistry.currentStorePaths,
               immutableStorePaths: [Self.selectionFilename])
            guard let result else { throw Failure.invalidStoreSet }
            return result
        }
    }

    private static func validateCurrentSet(_ files: [String: Data], temporaryDirectory: URL,
                                          maximumBytes: Int = 256 * 1_048_576) throws -> (selection: SelectionRecord, credentials: Set<String>) {
        let maps = Set(try DownloadNameMappingRegistry.currentStorePaths(in: files))
        let required = Version3JSONStoreConversion.primaryFilenames.union([signaturesName, registryName, selectionFilename]).union(maps)
        guard Set(files.keys) == required, files.values.reduce(0, { $0 + $1.count }) <= maximumBytes,
              let signatureBytes = files[signaturesName], let selectionBytes = files[selectionFilename],
              selectionBytes.count <= 1_048_576 else { throw Failure.invalidStoreSet }
        let selection = try JSONDecoder().decode(SelectionRecord.self, from: selectionBytes)
        guard selection.format == "AagedalFTPSync.migration-selection", selection.version == 3,
              Set(selection.primarySources.keys) == Version3JSONStoreConversion.primaryFilenames,
              !selection.calendarIdentifier.isEmpty, TimeZone(identifier: selection.timeZoneIdentifier) != nil,
              selection.migrationTimestamp.isFinite else { throw Failure.invalidSelectionRecord }
        let json = try Version3JSONStoreConversion.validateCurrentStores(files, maximumInputBytes: maximumBytes)
        try DownloadNameMappingRegistry.validateCurrentMappings(in: files)
        _ = try Version3SignatureConversion.validateVersion3Snapshot(signatureBytes, temporaryDirectory: temporaryDirectory,
                                                                    limits: .init(maximumBytes: maximumBytes))
        return (selection, json.retainedCredentialIDs)
    }

    private func validatePlan(_ plan: Plan) throws {
        let declared = Set(plan.legacyFiles)
        guard plan.maximumFiles > 0, plan.maximumFiles <= 8_192,
              plan.maximumBytes >= 4096, plan.maximumBytes <= 256 * 1_048_576,
              plan.legacyFiles.count == declared.count, declared.count <= plan.maximumFiles,
              Self.fixedLegacyPaths.isSubset(of: declared),
              Set(plan.primarySources.keys) == Version3JSONStoreConversion.primaryFilenames,
              plan.migrationDate.timeIntervalSince1970.isFinite else { throw Failure.invalidPlan }
        for path in declared where !Self.fixedLegacyPaths.contains(path) {
            guard path.hasPrefix(Self.namesDirectory), !String(path.dropFirst(Self.namesDirectory.count)).contains("/") else { throw Failure.invalidPlan }
            // Reuse the mapping filename contract without inventing a live map.
            _ = try DownloadNameMappingRegistry.initialData(committedMappingNames: [String(path.dropFirst(Self.namesDirectory.count))])
        }
        for (primary, source) in plan.primarySources {
            if case .file(let path) = source {
                guard path == primary || path == primary + ".backup", declared.contains(path) else { throw Failure.invalidPlan }
            }
        }
        switch plan.signatures {
        case .absent: break
        case .json(let path):
            guard Self.fixedLegacyPaths.contains(path), path.hasPrefix("original-source-signatures-"),
                  !path.contains("migration-in-progress"), !path.hasSuffix("-wal"), !path.hasSuffix("-shm"), !path.hasSuffix("-journal") else { throw Failure.invalidPlan }
        case .sqlite(let path): guard path == Self.signaturesName else { throw Failure.invalidPlan }
        }
    }

    private func validateRoot() throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.pathComponents.contains("."), !root.pathComponents.contains(".."),
              root.query == nil, root.fragment == nil, root.host == nil || root.host == "" || root.host == "localhost" else { throw Failure.unsafePath }
        var directory = root
        while true {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
    }

    private func verifyInventory(_ plan: Plan) throws {
        let declared = Set(plan.legacyFiles)
        var count = 0
        func scan(_ directory: URL, prefix: String) throws {
            guard let handle = opendir(directory.path) else { throw Failure.unsafePath }
            defer { closedir(handle) }
            while true {
                errno = 0
                guard let entry = readdir(handle) else {
                    guard errno == 0 else { throw Failure.unsafePath }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                count += 1
                guard count <= plan.maximumFiles else { throw Failure.limitExceeded }
                let path = prefix + name
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Failure.unsafePath }
                if prefix.isEmpty, name.hasPrefix(".v3-migration-"), info.st_mode & S_IFMT == S_IFDIR { continue }
                if prefix.isEmpty, [".v3-migration.lock", ".v3-runtime.lock", ".DS_Store"].contains(name), info.st_mode & S_IFMT == S_IFREG { continue }
                if prefix.isEmpty, name == "download-names-v1", info.st_mode & S_IFMT == S_IFDIR {
                    try scan(url, prefix: Self.namesDirectory)
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafePath }
                guard declared.contains(path) else { throw Failure.incompleteInventory(path) }
                if path.contains(".migration-in-progress") { throw Failure.interruptedLegacyMigration }
            }
        }
        try scan(root, prefix: "")
    }
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
