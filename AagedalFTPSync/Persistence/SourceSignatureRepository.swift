import Foundation

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

actor SourceSignatureRepository {
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

        var sortKey: String {
            [kind.rawValue, localPath, host, String(port), username, remotePath]
                .joined(separator: "\u{0}")
        }
    }

    private struct Key: Hashable, Sendable {
        let jobID: UUID
        let source: SourceIdentity
        let relativePath: String
    }

    private struct Record: Codable, Sendable {
        let jobID: UUID
        let source: SourceIdentity
        let relativePath: String
        let signature: SourceFileSignature

        var key: Key {
            Key(jobID: jobID, source: source, relativePath: relativePath)
        }
    }

    private let fileURL: URL
    private var cachedSignatures: [Key: SourceFileSignature]?

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
                .appendingPathComponent("original-source-signatures-v1.json")
        }
    }

    func signature(
        jobID: UUID,
        sourceEndpoint: Endpoint,
        relativePath: String
    ) throws -> SourceFileSignature? {
        let signatures = try loadIfNeeded()
        return signatures[Key(
            jobID: jobID,
            source: SourceIdentity(endpoint: sourceEndpoint),
            relativePath: relativePath
        )]
    }

    func signatures(jobID: UUID, sourceEndpoint: Endpoint) throws -> [String: SourceFileSignature] {
        let signatures = try loadIfNeeded()
        let source = SourceIdentity(endpoint: sourceEndpoint)
        return Dictionary(
            uniqueKeysWithValues: signatures.compactMap { key, signature in
                guard key.jobID == jobID, key.source == source else { return nil }
                return (key.relativePath, signature)
            }
        )
    }

    func record(_ file: SyncFile, jobID: UUID, sourceEndpoint: Endpoint) throws {
        var signatures = try loadIfNeeded()
        let key = Key(
            jobID: jobID,
            source: SourceIdentity(endpoint: sourceEndpoint),
            relativePath: file.relativePath
        )
        let newSignature = SourceFileSignature(file: file)
        guard signatures[key] != newSignature else { return }
        signatures[key] = newSignature
        try persist(signatures)
        cachedSignatures = signatures
    }

    func removeSignatures(jobID: UUID) throws {
        var signatures = try loadIfNeeded()
        let originalCount = signatures.count
        signatures = signatures.filter { $0.key.jobID != jobID }
        guard signatures.count != originalCount else { return }
        try persist(signatures)
        cachedSignatures = signatures
    }

    private func loadIfNeeded() throws -> [Key: SourceFileSignature] {
        if let cachedSignatures { return cachedSignatures }
        let records: [Record]
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedSignatures = [:]
            return [:]
        }
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
        let signatures = Dictionary(records.map { ($0.key, $0.signature) }, uniquingKeysWith: { _, newest in newest })
        cachedSignatures = signatures
        return signatures
    }

    private func decodeRecords(at url: URL) throws -> [Record] {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode([Record].self, from: data)
    }

    private func persist(_ signatures: [Key: SourceFileSignature]) throws {
        let records = signatures.map { key, signature in
            Record(
                jobID: key.jobID,
                source: key.source,
                relativePath: key.relativePath,
                signature: signature
            )
        }.sorted {
            if $0.jobID != $1.jobID { return $0.jobID.uuidString < $1.jobID.uuidString }
            if $0.source != $1.source { return $0.source.sortKey < $1.source.sortKey }
            return $0.relativePath < $1.relativePath
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(records)
        if FileManager.default.fileExists(atPath: fileURL.path),
           (try? decodeRecords(at: fileURL)) != nil {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
