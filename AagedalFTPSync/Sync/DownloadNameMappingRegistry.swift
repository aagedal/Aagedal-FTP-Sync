import Darwin
import Foundation

/// Durable authority for distinguishing a genuinely new v3 mapping from a lost
/// committed receipt. Migration must initialize the complete registry alongside
/// its maps. All runtime provisioning must share this lock and trusted stable root.
/// This does not choose v3 storage or exclude an older app's unrelated writers.
actor DownloadNameMappingRegistry {
    enum Entry: String, Codable, Sendable { case prepared, committed }
    struct State: Codable { var entries: [String: Entry] }
    enum Failure: Error { case invalidName, invalidState, unsafePath, busy, changed, orphanMapping, incompleteMapping, limitExceeded, fileSystem(Int32) }
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

    /// A prepared record permits recovery of this exact empty new map. Once
    /// committed, disappearance is damage, never a request for initialization.
    func admitOrProvision(fileName: String, checkpoint: (Checkpoint) throws -> Void = { _ in }) throws -> URL {
        try Self.validateName(fileName)
        try validateDirectories()
        // Refuse missing/incompatible state before even creating the lock file.
        _ = try load()
        let lockURL = storage.root.appendingPathComponent(".download-name-registry.lock")
        let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_nlink == 1 else { throw Failure.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(fd, LOCK_UN) }
        var (state, identity) = try load()
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

    private static func validateName(_ name: String) throws {
        let stem = name.hasSuffix(".json.replace") ? String(name.dropLast(13)) : name.hasSuffix(".json") ? String(name.dropLast(5)) : ""
        guard stem.utf8.count == 64, stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidName }
    }

    private func validateDirectories() throws {
        // Foundation may rewrite an existing /private/tmp path to its symlinked
        // /tmp alias during standardization. Validate lexical components and
        // actual ancestors instead of rejecting that trusted physical directory.
        guard storage.root.isFileURL, !storage.root.pathComponents.contains("."), !storage.root.pathComponents.contains(".."),
              storage.root.host == nil || storage.root.host == "" || storage.root.host == "localhost",
              storage.root.query == nil, storage.root.fragment == nil, !storage.root.path.utf8.contains(0) else { throw Failure.unsafePath }
        var directory = storage.downloadNamesDirectory
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
        let state = try Self.codec.decode(State.self, from: bytes, decoder: JSONDecoder())
        guard state.entries.count <= Self.maximumEntries else { throw Failure.limitExceeded }
        for name in state.entries.keys { try Self.validateName(name) }
        return (state, identity)
    }

    private func validateMap(at url: URL, mustBeEmpty: Bool) throws {
        let (bytes, _) = try read(url, maximumBytes: Self.maximumMappingBytes)
        let replacing = url.lastPathComponent.hasSuffix(".replace")
        let codec = VersionedStoreCodec(format: .version3, store: replacing ? .downloadReplacementNames : .downloadNames)
        let map = try codec.decode(DownloadNameMappingStorage.Version3State.self, from: bytes, decoder: JSONDecoder())
        try Self.validateMap(map, fileName: url.lastPathComponent, mustBeEmpty: mustBeEmpty)
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
