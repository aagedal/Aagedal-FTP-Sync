import Darwin
import Foundation

/// Durable authority for distinguishing a genuinely new v3 mapping from a lost
/// committed receipt. Migration must initialize the complete registry alongside
/// its maps. All runtime provisioning must share this lock and trusted stable root.
/// This does not choose v3 storage or exclude an older app's unrelated writers.
actor DownloadNameMappingRegistry {
    enum Entry: String, Codable, Sendable { case prepared, committed }
    struct State: Codable { var entries: [String: Entry] }
    enum Failure: Error { case invalidName, invalidState, unsafePath, busy, changed, orphanMapping, incompleteMapping, recoveryRequired, limitExceeded, fileSystem(Int32) }
    enum Checkpoint: Equatable, Sendable { case preparedRecorded, mappingCreated, committedRecorded }
    private let storage: AppStorageLayout
    private static let codec = VersionedStoreCodec(format: .version3, store: .downloadNameRegistry)
    private static let maximumEntries = 4096
    private static let maximumRegistryBytes = 1_048_576
    private static let maximumMappingBytes = 8 * 1_048_576

    init(storage: AppStorageLayout) throws {
        guard storage.storageFormat == .version3 else { throw Failure.invalidState }
        self.storage = storage
    }

    /// Only for a converter's complete, validated mapping set (or an explicitly
    /// empty new installation). This never discovers files or initializes a live
    /// missing registry. Retained mappings must not be omitted from this set.
    static func initialData(committedMappingNames: Set<String>) throws -> Data {
        guard committedMappingNames.count <= maximumEntries else { throw Failure.limitExceeded }
        for name in committedMappingNames { try validateName(name) }
        return try encode(State(entries: Dictionary(uniqueKeysWithValues: committedMappingNames.map { ($0, .committed) })))
    }

    /// Pure conversion of the complete, explicitly inventoried legacy directory.
    /// Keys are actual mapping filenames, not paths. Output paths are relative
    /// to the future v3 root. No missing mapping is invented or silently skipped.
    static func convertLegacyMappings(_ mappings: [String: Data]) throws -> [String: Data] {
        guard mappings.count <= maximumEntries,
              mappings.values.reduce(0, { $0 + $1.count }) <= 256 * 1_048_576 else { throw Failure.limitExceeded }
        struct Replacement: Decodable { let names: [String: String]; let newestDates: [String: Date] }
        let layout = AppStorageLayout(root: URL(fileURLWithPath: "/"), storageFormat: .version3)
        var output = [layout.downloadNameRegistry.lastPathComponent: try initialData(committedMappingNames: Set(mappings.keys))]
        for (name, bytes) in mappings {
            try validateName(name)
            guard bytes.count <= maximumMappingBytes else { throw Failure.limitExceeded }
            let replacing = name.hasSuffix(".replace")
            let state: DownloadNameMappingStorage.Version3State
            if replacing {
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(object.keys) == ["names", "newestDates"] else { throw Failure.invalidState }
                let legacy = try JSONDecoder().decode(Replacement.self, from: bytes)
                state = .init(mappingID: name, names: legacy.names, newestDates: legacy.newestDates)
            } else {
                state = .init(mappingID: name, names: try JSONDecoder().decode([String: String].self, from: bytes), newestDates: [:])
            }
            try validateMap(state, fileName: name, mustBeEmpty: false)
            let codec = VersionedStoreCodec(format: .version3, store: replacing ? .downloadReplacementNames : .downloadNames)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try codec.encode(state, encoder: encoder)
            guard encoded.count <= maximumMappingBytes else { throw Failure.limitExceeded }
            output[layout.downloadNamesDirectory.lastPathComponent + "/" + name] = encoded
        }
        return output
    }

    /// Resolve the complete current mapping set from the mutable registry, rather
    /// than the immutable initial migration manifest. A prepared journal requires
    /// explicit recovery before repositories or transfers may open.
    static func currentStorePaths(in files: [String: Data]) throws -> [String] {
        let layout = AppStorageLayout(root: URL(fileURLWithPath: "/"), storageFormat: .version3)
        guard let bytes = files[layout.downloadNameRegistry.lastPathComponent] else { throw Failure.invalidState }
        let state = try decodeRegistry(bytes)
        guard state.entries.values.allSatisfy({ $0 == .committed }) else { throw Failure.recoveryRequired }
        return state.entries.keys.sorted().map { layout.downloadNamesDirectory.lastPathComponent + "/" + $0 }
    }

    /// Pure validation for both migration output and committed-open collection.
    /// Unregistered maps, missing receipts and future or mismatched payloads fail.
    static func validateCurrentMappings(in files: [String: Data]) throws {
        let paths = Set(try currentStorePaths(in: files))
        let prefix = "download-names-v1/"
        guard Set(files.keys.filter { $0.hasPrefix(prefix) }) == paths else { throw Failure.orphanMapping }
        var total = 0
        for path in paths {
            guard let bytes = files[path] else { throw Failure.invalidState }
            total += bytes.count
            guard total <= 256 * 1_048_576 else { throw Failure.limitExceeded }
            try validateMapBytes(bytes, fileName: String(path.dropFirst(prefix.count)), mustBeEmpty: false)
        }
    }

    /// Hold the provisioning lock throughout a synchronous startup admission.
    /// The caller must also exclude naming-session and all other store writers;
    /// this lock only serializes registry provisioners. The snapshot includes the
    /// registry and every actual map, after a bounded directory inventory. Compare
    /// these exact bytes with the migration helper's collected files in `body`.
    /// An absent directory is valid only for an empty registry. No recovery, map
    /// initialization or cleanup is inferred by this read-only admission.
    func withValidatedCurrentMappings<T: Sendable>(
        _ body: @Sendable ([String: Data]) throws -> T
    ) throws -> T {
        try validateDirectories(allowMissingMappings: true)
        _ = try load()
        return try withRegistryLock {
            let (state, registryIdentity) = try load()
            guard state.entries.values.allSatisfy({ $0 == .committed }) else { throw Failure.recoveryRequired }
            let actualNames = try mappingDirectoryNames()
            guard actualNames == Set(state.entries.keys) else { throw Failure.orphanMapping }
            let (registryBytes, identity) = try read(storage.downloadNameRegistry, maximumBytes: Self.maximumRegistryBytes)
            guard identity == registryIdentity else { throw Failure.changed }
            var files = [storage.downloadNameRegistry.lastPathComponent: registryBytes]
            var total = registryBytes.count
            for name in actualNames.sorted() {
                let (bytes, _) = try read(storage.downloadNamesDirectory.appendingPathComponent(name), maximumBytes: Self.maximumMappingBytes)
                total += bytes.count
                guard total <= 256 * 1_048_576 else { throw Failure.limitExceeded }
                files[storage.downloadNamesDirectory.lastPathComponent + "/" + name] = bytes
            }
            try Self.validateCurrentMappings(in: files)
            guard try DownloadNameMappingStorage.identity(at: storage.downloadNameRegistry) == registryIdentity,
                  try mappingDirectoryNames() == actualNames else { throw Failure.changed }
            return try body(files)
        }
    }

    private func mappingDirectoryNames() throws -> Set<String> {
        guard try exists(storage.downloadNamesDirectory) else { return [] }
        // Ancestors were checked above and must remain trusted and stable.
        var info = stat()
        guard lstat(storage.downloadNamesDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
        guard let directory = opendir(storage.downloadNamesDirectory.path) else { throw Failure.fileSystem(errno) }
        defer { closedir(directory) }
        var names = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Failure.fileSystem(errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try Self.validateName(name)
            names.insert(name)
            guard names.count <= Self.maximumEntries else { throw Failure.limitExceeded }
        }
        return names
    }

    private func withRegistryLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = storage.root.appendingPathComponent(".download-name-registry.lock")
        let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// A prepared record permits recovery of this exact empty new map. Once
    /// committed, disappearance is damage, never a request for initialization.
    func admitOrProvision(fileName: String, checkpoint: (Checkpoint) throws -> Void = { _ in }) throws -> URL {
        try Self.validateName(fileName)
        try validateDirectories(allowMissingMappings: true)
        // Refuse missing/incompatible state before even creating the lock file.
        _ = try load()
        return try withRegistryLock {
            var (state, identity) = try load()
            if try !exists(storage.downloadNamesDirectory) {
                // Empty migrations have no map file to create this directory. Its
                // absence cannot authorize rebuilding any committed receipt.
                guard !state.entries.values.contains(.committed) else { throw Failure.incompleteMapping }
                guard mkdir(storage.downloadNamesDirectory.path, 0o700) == 0 else { throw Failure.fileSystem(errno) }
                let parent = Darwin.open(storage.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw Failure.fileSystem(errno) }
                defer { Darwin.close(parent) }
                guard fsync(parent) == 0 else { throw Failure.fileSystem(errno) }
            }
            try validateDirectories()
            let url = storage.downloadNamesDirectory.appendingPathComponent(fileName)
            if state.entries[fileName] == .committed {
                try validateMap(at: url, mustBeEmpty: false)
                return url
            }
            if state.entries[fileName] == nil {
                guard state.entries.count < Self.maximumEntries else { throw Failure.limitExceeded }
                guard try !exists(url) else { throw Failure.orphanMapping }
                state.entries[fileName] = .prepared
                identity = try save(state, expected: identity)
                try checkpoint(.preparedRecorded)
            }
            if try !exists(url) {
                try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: url, overwriteCaseVariants: fileName.hasSuffix(".replace"))
            }
            try validateMap(at: url, mustBeEmpty: true)
            try checkpoint(.mappingCreated)
            state.entries[fileName] = .committed
            _ = try save(state, expected: identity)
            try checkpoint(.committedRecorded)
            return url
        }
    }

    private static func validateName(_ name: String) throws {
        let stem = name.hasSuffix(".json.replace") ? String(name.dropLast(13)) : name.hasSuffix(".json") ? String(name.dropLast(5)) : ""
        guard stem.utf8.count == 64, stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidName }
    }

    private func validateDirectories(allowMissingMappings: Bool = false) throws {
        // Foundation may rewrite an existing /private/tmp path to its symlinked
        // /tmp alias during standardization. Validate lexical components and
        // actual ancestors instead of rejecting that trusted physical directory.
        guard storage.root.isFileURL, !storage.root.pathComponents.contains("."), !storage.root.pathComponents.contains(".."),
              storage.root.host == nil || storage.root.host == "" || storage.root.host == "localhost",
              storage.root.query == nil, storage.root.fragment == nil, !storage.root.path.utf8.contains(0) else { throw Failure.unsafePath }
        var directory = storage.downloadNamesDirectory
        if allowMissingMappings, try !exists(directory) { directory = storage.root }
        while true {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
    }

    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.fileSystem(errno) }
        return false
    }

    private func read(_ url: URL, maximumBytes: Int) throws -> (Data, DownloadNameMappingStorage.Identity) {
        let identity = try DownloadNameMappingStorage.identity(at: url)
        guard identity.size >= 0, identity.size <= maximumBytes else { throw Failure.limitExceeded }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumBytes else { throw Failure.limitExceeded }
        guard try DownloadNameMappingStorage.identity(at: url) == identity else { throw Failure.changed }
        return (bytes, identity)
    }

    private func load() throws -> (State, DownloadNameMappingStorage.Identity) {
        let (bytes, identity) = try read(storage.downloadNameRegistry, maximumBytes: Self.maximumRegistryBytes)
        return (try Self.decodeRegistry(bytes), identity)
    }

    private static func decodeRegistry(_ bytes: Data) throws -> State {
        guard bytes.count <= maximumRegistryBytes else { throw Failure.limitExceeded }
        let state = try codec.decode(State.self, from: bytes, decoder: JSONDecoder())
        guard state.entries.count <= maximumEntries else { throw Failure.limitExceeded }
        for name in state.entries.keys { try validateName(name) }
        return state
    }

    private func validateMap(at url: URL, mustBeEmpty: Bool) throws {
        let (bytes, _) = try read(url, maximumBytes: Self.maximumMappingBytes)
        try Self.validateMapBytes(bytes, fileName: url.lastPathComponent, mustBeEmpty: mustBeEmpty)
    }

    private static func validateMapBytes(_ bytes: Data, fileName: String, mustBeEmpty: Bool) throws {
        try validateName(fileName)
        guard bytes.count <= maximumMappingBytes else { throw Failure.limitExceeded }
        let codec = VersionedStoreCodec(format: .version3, store: fileName.hasSuffix(".replace") ? .downloadReplacementNames : .downloadNames)
        let map = try codec.decode(DownloadNameMappingStorage.Version3State.self, from: bytes, decoder: JSONDecoder())
        try validateMap(map, fileName: fileName, mustBeEmpty: mustBeEmpty)
    }

    private static func validateMap(_ map: DownloadNameMappingStorage.Version3State, fileName: String, mustBeEmpty: Bool) throws {
        let replacing = fileName.hasSuffix(".replace")
        guard map.mappingID == fileName,
              map.names.allSatisfy({ original, local in
                  PathSafety.isSafeRelativePath(original) && PathSafety.isSafeRelativePath(local)
                  && !PathSafety.isInternalStagingPath(original) && !PathSafety.isInternalStagingPath(local)
                  && (original as NSString).deletingLastPathComponent == (local as NSString).deletingLastPathComponent
                  && (replacing ? PathSafety.localComparisonKey(original) == PathSafety.localComparisonKey(local)
                      : (original as NSString).pathExtension == (local as NSString).pathExtension)
              }),
              Set(map.names.values.map(PathSafety.localComparisonKey)).count == map.names.count else { throw Failure.invalidState }
        let keys = Set(map.names.keys.map(PathSafety.localComparisonKey))
        guard map.newestDates.allSatisfy({ keys.contains($0.key) && $0.value.timeIntervalSinceReferenceDate.isFinite }),
              replacing || map.newestDates.isEmpty else { throw Failure.invalidState }
        if mustBeEmpty, !map.names.isEmpty || !map.newestDates.isEmpty { throw Failure.incompleteMapping }
    }

    private static func encode(_ state: State) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try codec.encode(state, encoder: encoder)
        guard bytes.count <= maximumRegistryBytes else { throw Failure.limitExceeded }
        return bytes
    }

    private func save(_ state: State, expected: DownloadNameMappingStorage.Identity) throws -> DownloadNameMappingStorage.Identity {
        let bytes = try Self.encode(state)
        guard try DownloadNameMappingStorage.identity(at: storage.downloadNameRegistry) == expected else { throw Failure.changed }
        let temporary = storage.root.appendingPathComponent(".mapping-registry-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.fileSystem(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.fileSystem(errno) }
        guard try DownloadNameMappingStorage.identity(at: storage.downloadNameRegistry) == expected else { throw Failure.changed }
        guard rename(temporary.path, storage.downloadNameRegistry.path) == 0 else { throw Failure.fileSystem(errno) }
        let directoryFD = Darwin.open(storage.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw Failure.fileSystem(errno) }
        return try DownloadNameMappingStorage.identity(at: storage.downloadNameRegistry)
    }
}
