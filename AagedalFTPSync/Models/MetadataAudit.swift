import Foundation
import MetadataTemplates

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

/// Resolution evidence only: this is not proof of writing or publication. Retains
/// dependency identifiers and assumptions, never template source or resolved values.
struct MetadataProcessingAuditEvidence: Codable, Equatable, Sendable {
    /// Deliberately excludes numeric coordinates and conflicting coordinate pairs.
    struct CoordinateDecision: Codable, Equatable, Sendable {
        enum Source: String, Codable, Sendable { case embeddedEXIF, xmp, scheduled }
        enum ScheduledDisposition: String, Codable, Sendable {
            case absent, invalid, preservedExisting, filledEmpty, overwroteExisting
        }
        let selectedSource: Source?
        let existingConflict: Bool
        let invalidSources: [Source]
        let scheduledDisposition: ScheduledDisposition

        init(_ resolution: EffectiveMetadataCoordinates.Resolution) {
            func source(_ value: EffectiveMetadataCoordinates.Source) -> Source {
                switch value {
                case .embeddedEXIF: return .embeddedEXIF
                case .xmp: return .xmp
                case .scheduled: return .scheduled
                }
            }
            selectedSource = resolution.selected.map { source($0.source) }
            existingConflict = resolution.existingConflict != nil
            invalidSources = resolution.invalidSources.map(source).sorted { $0.rawValue < $1.rawValue }
            switch resolution.scheduledDisposition {
            case .absent: scheduledDisposition = .absent
            case .invalid: scheduledDisposition = .invalid
            case .preservedExisting: scheduledDisposition = .preservedExisting
            case .filledEmpty: scheduledDisposition = .filledEmpty
            case .overwroteExisting: scheduledDisposition = .overwroteExisting
            }
        }
    }

    struct CaptureAssumption: Codable, Equatable, Sendable {
        enum Source: String, Codable, Sendable { case explicitOffset, persistedFallback }
        let source: Source
        let timeZoneIdentifier: String
        let secondsFromGMT: Int?
    }

    struct FieldOutcome: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case proposed, notRequested, preservedByPolicy, omitted }
        enum Reason: String, Codable, Sendable {
            case missingValues, invalidDate, outputByteLimit, keywordEntryLimit, writerByteLimit, invalidXMLCharacter, invalidGPSPosition
        }
        let status: Status
        let reason: Reason?
        let variables: [String]
        let limit: Int?

        fileprivate init(_ outcome: MetadataProcessingFieldOutcome) {
            var reason: Reason?
            var variables: [String] = []
            var limit: Int?
            switch outcome {
            case .proposed: status = .proposed
            case .notRequested: status = .notRequested
            case .preservedByPolicy: status = .preservedByPolicy
            case .omitted(let omission):
                status = .omitted
                switch omission {
                case .invalidGPSPosition: reason = .invalidGPSPosition
                case .invalidXMLCharacter: reason = .invalidXMLCharacter
                case .writerByteLimit(let maximum): reason = .writerByteLimit; limit = maximum
                case .template(let failure):
                    switch failure {
                    case .missingValues(let missing):
                        reason = .missingValues; variables = missing.map(\.rawValue).sorted()
                    case .invalidDate(let variable): reason = .invalidDate; variables = [variable.rawValue]
                    case .outputLimitExceeded(let maximum): reason = .outputByteLimit; limit = maximum
                    case .keywordEntryLimitExceeded(let maximum): reason = .keywordEntryLimit; limit = maximum
                    }
                }
            }
            self.reason = reason
            self.variables = variables
            self.limit = limit
        }
    }

    let processingDate: Date
    let processingTimeZoneIdentifier: String
    let captureAssumption: CaptureAssumption?
    let fields: [String: FieldOutcome]
    let resolutionComplete: Bool
    let coordinateDecision: CoordinateDecision?

    /// Literal processing has no frozen template context and keeps its old audit shape.
    init?(result: MetadataProcessingResult) {
        guard let context = result.context else { return nil }
        processingDate = context.processingDate
        processingTimeZoneIdentifier = context.processingTimeZone.identifier
        if let capture = context.captureDate {
            switch capture.zoneSource {
            case .explicitOffset(let seconds):
                captureAssumption = CaptureAssumption(source: .explicitOffset,
                    timeZoneIdentifier: capture.timeZone.identifier, secondsFromGMT: seconds)
            case .persistedFallback(let identifier):
                captureAssumption = CaptureAssumption(source: .persistedFallback,
                    timeZoneIdentifier: identifier, secondsFromGMT: nil)
            }
        } else { captureAssumption = nil }
        fields = Dictionary(uniqueKeysWithValues: result.fields.map { ($0.key.rawValue, FieldOutcome($0.value)) })
        resolutionComplete = result.resolutionComplete
        coordinateDecision = result.coordinateResolution.map(CoordinateDecision.init)
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
    let processingEvidence: MetadataProcessingAuditEvidence?

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
        detail: String? = nil,
        processingEvidence: MetadataProcessingAuditEvidence? = nil
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
        self.processingEvidence = processingEvidence
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
                let lhsLength = $0.matchingPrefixLength(relativePath: relativePath) ?? 0
                let rhsLength = $1.matchingPrefixLength(relativePath: relativePath) ?? 0
                if lhsLength != rhsLength {
                    return lhsLength > rhsLength
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
    }
}
