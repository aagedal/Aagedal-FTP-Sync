import Foundation

struct SyncFailureRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let jobID: UUID
    let occurredAt: Date
    let message: String

    init(
        id: UUID = UUID(),
        jobID: UUID,
        occurredAt: Date = Date(),
        message: String
    ) {
        self.id = id
        self.jobID = jobID
        self.occurredAt = occurredAt
        self.message = message
    }
}

struct SyncFailureLoadResult: Sendable {
    let entries: [SyncFailureRecord]
    let recoveredFromBackup: Bool
}

/// A small, persistent per-job history for errors that stop an entire sync run.
struct SyncFailureRepository: Sendable {
    private let fileURL: URL
    private let maximumEntries: Int

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil, maximumEntries: Int = 200) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("AagedalFTPSync", isDirectory: true)
                .appendingPathComponent("sync-errors-v1.json")
        }
        self.maximumEntries = max(maximumEntries, 1)
    }

    func loadResult() throws -> SyncFailureLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SyncFailureLoadResult(entries: [], recoveredFromBackup: false)
        }
        do {
            return SyncFailureLoadResult(entries: try decode(at: fileURL), recoveredFromBackup: false)
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                return SyncFailureLoadResult(entries: try decode(at: backupURL), recoveredFromBackup: true)
            } catch {
                throw primaryError
            }
        }
    }

    @discardableResult
    func append(_ entry: SyncFailureRecord) throws -> [SyncFailureRecord] {
        var entries = try loadResult().entries
        entries.append(entry)
        return try save(entries)
    }

    @discardableResult
    func remove(jobID: UUID) throws -> [SyncFailureRecord] {
        try save(try loadResult().entries.filter { $0.jobID != jobID })
    }

    @discardableResult
    func save(_ entries: [SyncFailureRecord]) throws -> [SyncFailureRecord] {
        let retained = Array(entries
            .sorted(by: Self.oldestFirst)
            .suffix(maximumEntries))
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.syncFailureConfigured.encode(retained)

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

    private func decode(at url: URL) throws -> [SyncFailureRecord] {
        try JSONDecoder.syncFailureConfigured.decode(
            [SyncFailureRecord].self,
            from: Data(contentsOf: url)
        )
    }

    private static func oldestFirst(_ lhs: SyncFailureRecord, _ rhs: SyncFailureRecord) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private extension JSONEncoder {
    static var syncFailureConfigured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var syncFailureConfigured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
