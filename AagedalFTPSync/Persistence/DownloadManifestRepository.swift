import Foundation
import Darwin

actor DownloadManifestRepository {
    private struct DestinationIdentity: Codable, Hashable, Sendable {
        let localPath: String

        init(endpoint: Endpoint) {
            localPath = URL(fileURLWithPath: endpoint.localPath).standardizedFileURL.path
        }
    }

    private struct Key: Hashable, Sendable {
        let jobID: UUID
        let destination: DestinationIdentity
        let relativePath: String
    }

    private struct Record: Codable, Sendable {
        let jobID: UUID
        let destination: DestinationIdentity
        let relativePath: String

        var key: Key {
            Key(jobID: jobID, destination: destination, relativePath: relativePath)
        }
    }

    private let codec: VersionedStoreCodec
    private let fileURL: URL
    private var cachedKeys: Set<Key>?
    private var validatedIdentity: StoreIdentity?

    private struct StoreIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    private enum StoreReadError: Error {
        case unsafeStore, changedDuringRead
        case fileSystem(Int32)
    }

    var nameMappingsDirectory: URL { AppStorageLayout(root: fileURL.deletingLastPathComponent()).downloadNamesDirectory }

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil, storage: AppStorageLayout = .legacy) {
        self.codec = VersionedStoreCodec(format: storage.storageFormat, store: .downloadManifest)
        self.fileURL = fileURL ?? storage.downloadManifest
    }

    func record(
        relativePaths: some Sequence<String>,
        jobID: UUID,
        destinationEndpoint: Endpoint
    ) throws {
        guard destinationEndpoint.kind == .local else { return }
        let paths = Set(relativePaths)
        guard !paths.isEmpty else { return }
        guard paths.allSatisfy(PathSafety.isSafeRelativePath) else {
            throw AppError.transferFailed("A published download path was unsafe and could not be recorded.")
        }

        var keys = try loadIfNeeded()
        let destination = DestinationIdentity(endpoint: destinationEndpoint)
        let originalCount = keys.count
        for relativePath in paths {
            keys.insert(Key(jobID: jobID, destination: destination, relativePath: relativePath))
        }
        guard keys.count != originalCount else { return }
        try persist(keys)
        cachedKeys = keys
    }

    func relativePaths(jobID: UUID, destinationEndpoint: Endpoint) throws -> Set<String> {
        guard destinationEndpoint.kind == .local else { return [] }
        let keys = try loadIfNeeded()
        let destination = DestinationIdentity(endpoint: destinationEndpoint)
        return Set(keys.compactMap { key in
            key.jobID == jobID && key.destination == destination ? key.relativePath : nil
        })
    }

    func remove(
        relativePaths: some Sequence<String>,
        jobID: UUID,
        destinationEndpoint: Endpoint
    ) throws {
        guard destinationEndpoint.kind == .local else { return }
        let removedPaths = Set(relativePaths)
        guard !removedPaths.isEmpty else { return }
        var keys = try loadIfNeeded()
        let destination = DestinationIdentity(endpoint: destinationEndpoint)
        let originalCount = keys.count
        keys = keys.filter { key in
            key.jobID != jobID
                || key.destination != destination
                || !removedPaths.contains(key.relativePath)
        }
        guard keys.count != originalCount else { return }
        try persist(keys)
        cachedKeys = keys
    }

    func removeAll(jobID: UUID) throws {
        var keys = try loadIfNeeded()
        let originalCount = keys.count
        keys = keys.filter { $0.jobID != jobID }
        guard keys.count != originalCount else { return }
        try persist(keys)
        cachedKeys = keys
    }

    private func loadIfNeeded() throws -> Set<Key> {
        try validatePrimaryIdentityIfNeeded()
        if let cachedKeys { return cachedKeys }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try codec.validateExistingStore(at: fileURL)
            cachedKeys = []
            return []
        }

        let records: [Record]
        var recoveredFromBackup = false
        do {
            records = try decodeRecords(at: fileURL)
        } catch let primaryError {
            guard VersionedStoreCodec.permitsBackupRecovery(after: primaryError) else { throw primaryError }
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                records = try decodeRecords(at: backupURL)
                recoveredFromBackup = true
            } catch {
                guard VersionedStoreCodec.permitsBackupRecovery(after: error) else { throw error }
                throw primaryError
            }
        }
        if codec.format == .version3, try primaryIdentity() != validatedIdentity {
            cachedKeys = nil
            validatedIdentity = nil
            throw StoreReadError.changedDuringRead
        }
        let keys = Set(records.map(\.key))
        // A fallback has a second mutable source. Re-read it on the next v3
        // request so replacing a recovery file cannot leave stale ownership cached.
        cachedKeys = codec.format == .version3 && recoveredFromBackup ? nil : keys
        return keys
    }

    /// Avoid reparsing a large v3 manifest for every ownership query. Normal atomic
    /// replacements and observed in-place changes invalidate both header and payload.
    /// The selected directory must remain trusted: this is not authentication against
    /// a hostile same-user writer manipulating files and timestamps concurrently.
    private func validatePrimaryIdentityIfNeeded() throws {
        guard codec.format == .version3 else { return }
        let identity = try primaryIdentity()
        guard identity != validatedIdentity else { return }
        cachedKeys = nil
        validatedIdentity = nil
        try codec.validateExistingStore(at: fileURL)
        guard try primaryIdentity() == identity else { throw StoreReadError.changedDuringRead }
        validatedIdentity = identity
    }

    private func primaryIdentity() throws -> StoreIdentity {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            if errno == ENOENT { throw VersionedStoreCodec.HeaderError.missingStore }
            throw StoreReadError.fileSystem(errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw StoreReadError.unsafeStore }
        return StoreIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                             modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                             changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    private func decodeRecords(at url: URL) throws -> [Record] {
        try codec.decode([Record].self, from: Data(contentsOf: url), decoder: Self.decoder)
    }

    private func persist(_ keys: Set<Key>) throws {
        let records = keys.map { key in
            Record(jobID: key.jobID, destination: key.destination, relativePath: key.relativePath)
        }.sorted {
            if $0.jobID != $1.jobID { return $0.jobID.uuidString < $1.jobID.uuidString }
            if $0.destination.localPath != $1.destination.localPath {
                return $0.destination.localPath < $1.destination.localPath
            }
            return $0.relativePath < $1.relativePath
        }

        try codec.validateExistingStore(at: fileURL)
        try codec.validateExistingStore(at: backupURL, required: false)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try codec.encode(records, encoder: Self.encoder)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? codec.decode([Record].self, from: existingData, decoder: Self.decoder)) != nil {
            try existingData.write(to: backupURL, options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
