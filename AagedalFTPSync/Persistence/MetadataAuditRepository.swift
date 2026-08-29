import Foundation

struct MetadataAuditLoadResult: Sendable {
    let entries: [MetadataAuditEntry]
    let recoveredFromBackup: Bool
}

/// Bounded, backup-protected storage for per-file metadata decisions.
struct MetadataAuditRepository: Sendable {
    private let fileURL: URL
    private let maximumEntries: Int

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil, maximumEntries: Int = 2_000) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("AagedalFTPSync", isDirectory: true)
                .appendingPathComponent("metadata-audit-v1.json")
        }
        self.maximumEntries = max(maximumEntries, 1)
    }

    func load(jobID: UUID? = nil) throws -> [MetadataAuditEntry] {
        let entries = try loadResult().entries
        guard let jobID else { return entries }
        return entries.filter { $0.jobID == jobID }
    }

    func loadResult() throws -> MetadataAuditLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MetadataAuditLoadResult(entries: [], recoveredFromBackup: false)
        }
        do {
            return MetadataAuditLoadResult(
                entries: try decode(at: fileURL),
                recoveredFromBackup: false
            )
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                return MetadataAuditLoadResult(
                    entries: try decode(at: backupURL),
                    recoveredFromBackup: true
                )
            } catch {
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
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.metadataAuditConfigured.encode(retained)

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
        try JSONDecoder.metadataAuditConfigured.decode(
            [MetadataAuditEntry].self,
            from: Data(contentsOf: url)
        )
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

