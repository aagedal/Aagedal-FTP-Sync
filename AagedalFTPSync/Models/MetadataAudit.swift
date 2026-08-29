import Foundation

enum MetadataAuditStatus: String, Codable, CaseIterable, Sendable {
    case applied
    case skipped
    case failed
}

enum MetadataAuditOperation: String, Codable, Sendable {
    case transfer
    case reprocess

    var title: String {
        switch self {
        case .transfer: "Transfer"
        case .reprocess: "Reprocess"
        }
    }
}

/// One durable record of the metadata decision made for a file.
///
/// Names are stored alongside identifiers so an audit remains readable after a
/// photographer or timeline clip is renamed or removed.
struct MetadataAuditEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let runID: UUID
    let jobID: UUID
    let occurredAt: Date
    let operation: MetadataAuditOperation
    let relativePath: String
    let status: MetadataAuditStatus
    let timestampPolicy: MetadataTimestampPolicy
    let scheduledAt: Date?
    let photographerID: UUID?
    let photographerName: String?
    let clipID: UUID?
    let clipName: String?
    let swiftExifWarnings: [String]
    let detail: String?

    init(
        id: UUID = UUID(),
        runID: UUID,
        jobID: UUID,
        occurredAt: Date = Date(),
        operation: MetadataAuditOperation,
        relativePath: String,
        status: MetadataAuditStatus,
        timestampPolicy: MetadataTimestampPolicy,
        scheduledAt: Date?,
        assignment: MetadataAssignment? = nil,
        matchedPhotographer: PhotographerProfile? = nil,
        matchedClip: MetadataScheduleClip? = nil,
        swiftExifWarnings: [String] = [],
        detail: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.jobID = jobID
        self.occurredAt = occurredAt
        self.operation = operation
        self.relativePath = relativePath
        self.status = status
        self.timestampPolicy = timestampPolicy
        self.scheduledAt = scheduledAt
        let photographer = assignment?.photographer ?? matchedPhotographer
        let clip = assignment?.clip ?? matchedClip
        photographerID = photographer?.id
        photographerName = photographer?.name
        clipID = clip?.id
        clipName = clip?.name
        self.swiftExifWarnings = Self.uniqueWarnings(swiftExifWarnings)
        self.detail = detail
    }

    private static func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            let normalized = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }
}

struct MetadataRunReport: Codable, Equatable, Sendable {
    var entries: [MetadataAuditEntry]

    init(entries: [MetadataAuditEntry] = []) {
        self.entries = entries
    }

    static let empty = MetadataRunReport()

    var applied: Int { count(.applied) }
    var skipped: Int { count(.skipped) }
    var failed: Int { count(.failed) }
    var hasActivity: Bool { !entries.isEmpty }

    mutating func append(_ entry: MetadataAuditEntry) {
        entries.append(entry)
    }

    mutating func append(contentsOf other: MetadataRunReport) {
        entries.append(contentsOf: other.entries)
    }

    private func count(_ status: MetadataAuditStatus) -> Int {
        entries.lazy.filter { $0.status == status }.count
    }
}

extension MetadataAutomation {
    /// Resolves the same preferred filename-prefix match used for assignment,
    /// even when no clip covers the scheduling timestamp. This lets skipped
    /// audit entries still identify the photographer whose prefix matched.
    func matchingPhotographer(for relativePath: String) -> PhotographerProfile? {
        guard isEnabled else { return nil }
        return photographers
            .filter { $0.matches(relativePath: relativePath) }
            .sorted {
                if $0.normalizedPrefix.count != $1.normalizedPrefix.count {
                    return $0.normalizedPrefix.count > $1.normalizedPrefix.count
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
    }
}
