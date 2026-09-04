import Foundation

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

    private let fileURL: URL
    private var cachedKeys: Set<Key>?

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("AagedalFTPSync", isDirectory: true)
                .appendingPathComponent("download-manifest-v1.json")
        }
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
        if let cachedKeys { return cachedKeys }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedKeys = []
            return []
        }

        let records: [Record]
        do {
            records = try decodeRecords(at: fileURL)
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                records = try decodeRecords(at: backupURL)
            } catch {
                throw primaryError
            }
        }
        let keys = Set(records.map(\.key))
        cachedKeys = keys
        return keys
    }

    private func decodeRecords(at url: URL) throws -> [Record] {
        try Self.decoder.decode([Record].self, from: Data(contentsOf: url))
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

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(records)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? Self.decoder.decode([Record].self, from: existingData)) != nil {
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
