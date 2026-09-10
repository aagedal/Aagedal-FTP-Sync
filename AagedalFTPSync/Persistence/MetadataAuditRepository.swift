import Foundation

struct MetadataAuditLoadResult: Sendable {
    let entries: [MetadataAuditEntry]
    let recoveredFromBackup: Bool
}

/// Bounded, backup-protected storage for per-file metadata decisions.
struct MetadataAuditRepository: Sendable {
    private let codec: VersionedStoreCodec
    private let fileURL: URL
    private let maximumEntries: Int

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil, maximumEntries: Int = 2_000, storage: AppStorageLayout = .legacy) {
        self.codec = VersionedStoreCodec(format: storage.storageFormat, store: .metadataAudit)
        self.fileURL = fileURL ?? storage.metadataAudit
        self.maximumEntries = max(maximumEntries, 1)
    }

    func load(jobID: UUID? = nil) throws -> [MetadataAuditEntry] {
        let entries = try loadResult().entries
        guard let jobID else { return entries }
        return entries.filter { $0.jobID == jobID }
    }

    func loadResult() throws -> MetadataAuditLoadResult {
        try codec.validateExistingStore(at: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try codec.validateExistingStore(at: fileURL)
            return MetadataAuditLoadResult(entries: [], recoveredFromBackup: false)
        }
        do {
            return MetadataAuditLoadResult(
                entries: try decode(at: fileURL),
                recoveredFromBackup: false
            )
        } catch let primaryError {
            guard VersionedStoreCodec.permitsBackupRecovery(after: primaryError) else { throw primaryError }
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                return MetadataAuditLoadResult(
                    entries: try decode(at: backupURL),
                    recoveredFromBackup: true
                )
            } catch {
                guard VersionedStoreCodec.permitsBackupRecovery(after: error) else { throw error }
                throw primaryError
            }
        }
    }

    @discardableResult
    func append(_ report: MetadataRunReport) throws -> [MetadataAuditEntry] {
        guard report.hasActivity else { return try load() }
        var entries = try load()
        entries.append(contentsOf: report.entries)
        return try save(entries)
    }

    @discardableResult
    func remove(jobID: UUID) throws -> [MetadataAuditEntry] {
        try save(try load().filter { $0.jobID != jobID })
    }

    @discardableResult
    func save(_ entries: [MetadataAuditEntry]) throws -> [MetadataAuditEntry] {
        let retained = Array(entries
            .sorted(by: Self.oldestFirst)
            .suffix(maximumEntries))
        try codec.validateExistingStore(at: fileURL)
        try codec.validateExistingStore(at: backupURL, required: false)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try codec.encode(retained, encoder: JSONEncoder.metadataAuditConfigured)

        if FileManager.default.fileExists(atPath: fileURL.path),
           (try? decode(at: fileURL)) != nil {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }

        try data.write(to: fileURL, options: .atomic)
        return retained
    }

    private func decode(at url: URL) throws -> [MetadataAuditEntry] {
        try codec.decode([MetadataAuditEntry].self, from: Data(contentsOf: url), decoder: JSONDecoder.metadataAuditConfigured)
    }

    private static func oldestFirst(_ lhs: MetadataAuditEntry, _ rhs: MetadataAuditEntry) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private extension JSONEncoder {
    static var metadataAuditConfigured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var metadataAuditConfigured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

