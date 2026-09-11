import Foundation
import MetadataTemplates
import SwiftMediaMetadata

/// In-memory input only. Persistence adapters must supply explicitly activated
/// source values after the v3 storage boundary is available; old records use literal().
struct MetadataProcessingRequest: Equatable, Sendable {
    let headline: MetadataTemplateText
    let description: MetadataTemplateText
    let keywords: MetadataTemplateKeywords
    let copyright: MetadataTemplateText
    let creator: String
    let gpsPosition: ScheduledGPSPosition?
    let existingFieldPolicy: MetadataExistingFieldPolicy

    init(
        assignment: MetadataAssignment,
        headline: MetadataTemplateText? = nil,
        description: MetadataTemplateText? = nil,
        keywords: MetadataTemplateKeywords? = nil,
        copyright: MetadataTemplateText? = nil
    ) throws {
        self.headline = try headline ?? assignment.clip.fields.validatedHeadline
        self.description = try description ?? assignment.clip.fields.validatedDescription
        let selectedKeywords = try keywords ?? assignment.clip.fields.validatedKeywords
        if selectedKeywords.templateVersion == nil {
            self.keywords = .literal(ScheduledMetadataFields(keywords: selectedKeywords.source).normalizedKeywords)
        } else {
            self.keywords = selectedKeywords
        }
        self.copyright = try copyright ?? assignment.photographer.validatedCopyright
        self.creator = assignment.photographer.photographerName
        self.gpsPosition = assignment.clip.gpsPosition
        self.existingFieldPolicy = assignment.existingFieldPolicy
    }

    /// Call after reading current metadata and applying field policies. Dependencies
    /// of fields that will be preserved must not trigger provider work.
    func requiredVariables(for writableFields: Set<MetadataWritableField>) -> Set<MetadataTemplateVariable> {
        var variables = Set<MetadataTemplateVariable>()
        if writableFields.contains(.headline) { variables.formUnion(headline.requiredVariables) }
        if writableFields.contains(.description) { variables.formUnion(description.requiredVariables) }
        if writableFields.contains(.keywords) { variables.formUnion(keywords.requiredVariables) }
        if writableFields.contains(.copyright) { variables.formUnion(copyright.requiredVariables) }
        return variables
    }
}

enum MetadataProcessingOmission: Equatable, Sendable {
    case template(MetadataTemplatePreservationReason)
    case writerByteLimit(maximum: Int)
    case invalidXMLCharacter
}

enum MetadataProcessingFieldOutcome: Equatable, Sendable {
    case proposed, notRequested, preservedByPolicy
    case omitted(MetadataProcessingOmission)
}

struct MetadataProcessingResult: Equatable, Sendable {
    let changes: ResolvedMetadataChanges
    let context: MetadataTemplateContext?
    let fields: [MetadataWritableField: MetadataProcessingFieldOutcome]

    /// This means resolution is complete, not that a write/publication succeeded.
    /// Future enrichment callers must also check provider and publication outcomes
    /// before allowing processed-source removal.
    var resolutionComplete: Bool {
        !fields.values.contains { if case .omitted = $0 { return true }; return false }
    }
}

enum MetadataProcessingCoordinator {
    /// Existing application paths freeze once per item and share this value between
    /// assessment and writing. No clock, parser or provider is consulted for literals.
    static func prepareLiteral(_ assignment: MetadataAssignment) throws -> MetadataProcessingResult {
        let changes = try ResolvedMetadataChanges.literal(assignment)
        return MetadataProcessingResult(changes: changes, context: nil, fields: [
            .headline: changes.headline.isEmpty ? .notRequested : .proposed,
            .description: changes.description.isEmpty ? .notRequested : .proposed,
            .keywords: changes.keywords.isEmpty ? .notRequested : .proposed,
            .creator: changes.creator.isEmpty ? .notRequested : .proposed,
            .copyright: changes.copyright.isEmpty ? .notRequested : .proposed,
            .gpsPosition: changes.gpsPosition == nil ? .notRequested : .proposed
        ])
    }

    /// Freeze activated values once for this image. The persisted processing zone
    /// also supplies the explicit fallback for an offset-free original capture.
    /// Missing enrichment stays a field omission; no provider or writer is invoked.
    static func preparePerImage(assignment: MetadataAssignment, fileURL: URL,
                                relativePath: String, processingDate: Date,
                                processingTimeZone: TimeZone) throws -> MetadataProcessingResult {
        guard assignment.clip.fields.hasActivatedTemplates || assignment.photographer.hasActivatedTemplates else {
            return try prepareLiteral(assignment)
        }
        let request = try MetadataProcessingRequest(assignment: assignment)
        let writable = try MetadataWriter.writableFields(at: fileURL, relativePath: relativePath,
                                                        policy: assignment.existingFieldPolicy)
        let required = request.requiredVariables(for: writable)
        var capture: MetadataCaptureDate?
        if required.contains(.captureDate) {
            var result = MetadataCaptureDateReader.read(from: fileURL,
                persistedFallbackTimeZoneIdentifier: processingTimeZone.identifier)
            if case .unavailable = result, MetadataWriter.usesXMPSidecar(for: relativePath) {
                let sidecar = fileURL.deletingPathExtension().appendingPathExtension("xmp")
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    result = MetadataCaptureDateReader.read(from: sidecar,
                        persistedFallbackTimeZoneIdentifier: processingTimeZone.identifier)
                }
            }
            // Invalid/ambiguous embedded originals remain unavailable; a sidecar
            // cannot silently replace contradictory capture evidence.
            if case .resolved(let value, _) = result { capture = value }
        }
        let context = MetadataTemplateContext(processingDate: processingDate,
            processingTimeZone: processingTimeZone, captureDate: capture,
            photographer: request.creator)
        return resolve(request, context: context, writableFields: writable)
    }

    /// Pure resolution against one supplied context; never reads or writes images.
    /// The caller supplies writability determined from original embedded/XMP metadata.
    /// preparePerImage supplies carrier-aware policy and frozen per-image inputs.
    static func resolve(
        _ request: MetadataProcessingRequest,
        context suppliedContext: MetadataTemplateContext,
        writableFields: Set<MetadataWritableField>
    ) -> MetadataProcessingResult {
        // Photographer always comes from the matched assignment, never recognition
        // or a caller's unrelated sample identity. Copyright cannot reference itself.
        let context = MetadataTemplateContext(
            processingDate: suppliedContext.processingDate,
            processingTimeZone: suppliedContext.processingTimeZone,
            captureDate: suppliedContext.captureDate,
            photographer: request.creator,
            city: suppliedContext.city, country: suppliedContext.country,
            persons: suppliedContext.persons
        )
        var outcomes: [MetadataWritableField: MetadataProcessingFieldOutcome] = [:]
        func text(_ source: MetadataTemplateText, field: MetadataWritableField, tag: IPTCTag) -> String {
            guard writableFields.contains(field) else {
                outcomes[field] = .preservedByPolicy
                return ""
            }
            switch source.resolve(using: context) {
            case .preserveExisting(let reason):
                outcomes[field] = .omitted(.template(reason))
                return ""
            case .resolved(let value):
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if source.templateVersion != nil, let reason = validate(value, tag: tag) {
                    outcomes[field] = .omitted(reason)
                    return ""
                }
                outcomes[field] = value.isEmpty ? .notRequested : .proposed
                return value
            }
        }
        let headline = text(request.headline, field: .headline, tag: .headline)
        let description = text(request.description, field: .description, tag: .captionAbstract)
        let copyright = text(request.copyright, field: .copyright, tag: .copyrightNotice)
        var keywords: [String] = []
        if writableFields.contains(.keywords) {
            switch request.keywords.resolve(using: context) {
            case .preserveExisting(let reason): outcomes[.keywords] = .omitted(.template(reason))
            case .resolved(let values):
                if request.keywords.templateVersion != nil,
                   let reason = values.compactMap({ validate($0, tag: .keywords) }).first {
                    outcomes[.keywords] = .omitted(reason)
                } else {
                    keywords = values
                    outcomes[.keywords] = values.isEmpty ? .notRequested : .proposed
                }
            }
        } else { outcomes[.keywords] = .preservedByPolicy }
        let creator = writableFields.contains(.creator) ? request.creator : ""
        outcomes[.creator] = writableFields.contains(.creator)
            ? (creator.isEmpty ? .notRequested : .proposed) : .preservedByPolicy
        let gps = writableFields.contains(.gpsPosition) ? request.gpsPosition : nil
        outcomes[.gpsPosition] = writableFields.contains(.gpsPosition)
            ? (gps == nil ? .notRequested : .proposed) : .preservedByPolicy
        return MetadataProcessingResult(
            changes: ResolvedMetadataChanges(headline: headline, description: description,
                keywords: keywords, creator: creator, copyright: copyright,
                gpsPosition: gps, existingFieldPolicy: request.existingFieldPolicy),
            context: context, fields: outcomes
        )
    }

    /// Activated values use the pinned writer's IPTC byte limits for embedded/XMP
    /// parity. Legacy source keeps its former writer behavior. Wire-format source
    /// limits remain the responsibility of calendar/configuration adapters.
    private static func validate(_ value: String, tag: IPTCTag) -> MetadataProcessingOmission? {
        if let maximum = tag.maxLength, value.utf8.count > maximum {
            return .writerByteLimit(maximum: maximum)
        }
        guard value.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return v == 9 || v == 10 || v == 13 || (0x20...0xD7FF).contains(v)
                || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
        }) else { return .invalidXMLCharacter }
        return nil
    }
}
