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
    let photographer: String?
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
        self.photographer = assignment.photographer.photographerName
        self.gpsPosition = assignment.clip.gpsPosition
        self.existingFieldPolicy = assignment.existingFieldPolicy
    }

    /// Standalone enrichment has no synthetic clip or photographer identity.
    init() {
        headline = .literal(""); description = .literal(""); keywords = .literal([])
        copyright = .literal(""); creator = ""; photographer = nil; gpsPosition = nil
        existingFieldPolicy = .fillEmpty
    }

    init(assignment: MetadataAssignment?) throws {
        if let assignment { self = try MetadataProcessingRequest(assignment: assignment) }
        else { self.init() }
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
    case invalidGPSPosition
}

enum MetadataProcessingFieldOutcome: Equatable, Sendable {
    case proposed, notRequested, preservedByPolicy
    case omitted(MetadataProcessingOmission)
}

enum MetadataProcessingGeocodingOutcome: Equatable, Sendable {
    case notRequested
    case missingCoordinates
    case lookup(MetadataGeocodingService.Outcome)
}

enum MetadataProcessingPlaceOutcome: Equatable, Sendable {
    case notRequested, preservedByPolicy, proposed
    case unavailable
    case invalidValue(MetadataProcessingOmission)
}

struct MetadataProcessingResult: Equatable, Sendable {
    let changes: ResolvedMetadataChanges
    let context: MetadataTemplateContext?
    let fields: [MetadataWritableField: MetadataProcessingFieldOutcome]
    /// Frozen original-coordinate decision, not proof that a proposal was written.
    /// Numeric values remain in memory; durable audit retains only source/decision labels.
    let coordinateResolution: EffectiveMetadataCoordinates.Resolution?
    let geocoding: MetadataProcessingGeocodingOutcome
    /// Concrete locale only when lookup was needed (including missing GPS).
    let geocodingLocaleIdentifier: String?
    let places: [MetadataPlaceField: MetadataProcessingPlaceOutcome]

    init(changes: ResolvedMetadataChanges, context: MetadataTemplateContext?,
         fields: [MetadataWritableField: MetadataProcessingFieldOutcome],
         coordinateResolution: EffectiveMetadataCoordinates.Resolution? = nil,
         geocoding: MetadataProcessingGeocodingOutcome = .notRequested,
         geocodingLocaleIdentifier: String? = nil,
         places: [MetadataPlaceField: MetadataProcessingPlaceOutcome] = [:]) {
        self.changes = changes
        self.context = context
        self.fields = fields
        self.coordinateResolution = coordinateResolution
        self.geocoding = geocoding
        self.geocodingLocaleIdentifier = geocodingLocaleIdentifier
        self.places = places
    }

    var hasProposedChanges: Bool {
        fields.values.contains(.proposed) || places.values.contains(.proposed)
    }

    /// This means resolution is complete, not that a write/publication succeeded.
    /// Future enrichment callers must also check provider and publication outcomes
    /// before allowing processed-source removal.
    var resolutionComplete: Bool {
        if fields.values.contains(where: { if case .omitted = $0 { return true }; return false }) { return false }
        if places.values.contains(where: {
            switch $0 { case .unavailable, .invalidValue: return true; default: return false }
        }) { return false }
        switch geocoding {
        case .notRequested, .lookup(.found): return true
        default: return false
        }
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
        var coordinateResolution: EffectiveMetadataCoordinates.Resolution?
        if request.gpsPosition != nil {
            coordinateResolution = try MetadataCoordinateReader.read(at: fileURL, relativePath: relativePath,
                scheduled: request.gpsPosition, policy: request.existingFieldPolicy)
        }
        // Validate scheduled-coordinate sidecars before the legacy policy reader
        // can parse them. Other activated/literal workflows retain their old path.
        var writable = try MetadataWriter.writableFields(at: fileURL, relativePath: relativePath,
                                                        policy: assignment.existingFieldPolicy)
        if let resolution = coordinateResolution {
            // An existing RAW sidecar can lack GPS even when EXIF has a valid
            // pair. The activated path preserves that pair under fill-empty;
            // do not let the legacy sidecar-only policy propose a replacement.
            switch resolution.scheduledDisposition {
            case .filledEmpty, .overwroteExisting: writable.insert(.gpsPosition)
            case .absent, .invalid, .preservedExisting: writable.remove(.gpsPosition)
            }
        }
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
            photographer: request.photographer)
        return resolve(request, context: context, writableFields: writable,
                       coordinateResolution: coordinateResolution)
    }

    /// Offline enrichment shares one injected service and freezes original GPS before
    /// any proposal. Disabled settings retain the existing synchronous behavior.
    static func prepare(
        assignment: MetadataAssignment?, geocoding: MetadataGeocodingSettings?,
        service: MetadataGeocodingService, fileURL: URL, relativePath: String,
        processingDate: Date, processingTimeZone: TimeZone
    ) async throws -> MetadataProcessingResult {
        try Task.checkCancellation()
        guard let settings = geocoding, settings.isEnabled else {
            if let assignment {
                return try preparePerImage(assignment: assignment, fileURL: fileURL,
                    relativePath: relativePath, processingDate: processingDate,
                    processingTimeZone: processingTimeZone)
            }
            return MetadataProcessingResult(changes: .init(), context: nil, fields: [:])
        }
        try settings.validate()
        let request = try MetadataProcessingRequest(assignment: assignment)
        // This performs strict existing RAW sidecar validation for every enabled
        // geocoding mode, including variables-only and preserved place fields,
        // before the legacy scheduled-field policy reader can inspect it.
        let placeWritable = try MetadataWriter.writablePlaceFields(at: fileURL,
            relativePath: relativePath, settings: settings)
        // Standalone runs do not read unrelated text/capture fields.
        var writable = Set<MetadataWritableField>()
        if assignment != nil {
            writable = try MetadataWriter.writableFields(at: fileURL, relativePath: relativePath,
                                                         policy: request.existingFieldPolicy)
        }
        let required = request.requiredVariables(for: writable)
        let needsVariables = settings.resolveVariables && !required.isDisjoint(with: [.city, .country])
        let needsLookup = needsVariables || !placeWritable.isEmpty
        var coordinates: EffectiveMetadataCoordinates.Resolution?
        if needsLookup || request.gpsPosition != nil {
            coordinates = try MetadataCoordinateReader.read(at: fileURL, relativePath: relativePath,
                scheduled: request.gpsPosition, policy: request.existingFieldPolicy)
        }
        if let coordinates {
            switch coordinates.scheduledDisposition {
            case .filledEmpty, .overwroteExisting: writable.insert(.gpsPosition)
            case .absent, .invalid, .preservedExisting: writable.remove(.gpsPosition)
            }
        }
        var stage: MetadataProcessingGeocodingOutcome = .notRequested
        var place: MetadataGeocodingService.Place?
        if needsLookup {
            if let pair = coordinates?.selected?.pair {
                guard let query = MetadataGeocodingService.Query(latitude: pair.latitude,
                    longitude: pair.longitude, locale: settings.localeIdentifier) else {
                    throw AppError.invalidConfiguration("Offline metadata requires a concrete supported locale.")
                }
                let outcome = await service.resolve(query)
                try Task.checkCancellation()
                if case .cancelled = outcome { throw CancellationError() }
                stage = .lookup(outcome)
                if case .found(let found, _) = outcome { place = found }
            } else { stage = .missingCoordinates }
        }
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
            if case .resolved(let value, _) = result { capture = value }
        }
        let context = MetadataTemplateContext(processingDate: processingDate,
            processingTimeZone: processingTimeZone, captureDate: capture,
            photographer: request.photographer, city: settings.resolveVariables ? place?.city : nil,
            country: settings.resolveVariables ? place?.country : nil)
        let base = resolve(request, context: context, writableFields: writable,
                           coordinateResolution: coordinates)
        var outcomes: [MetadataPlaceField: MetadataProcessingPlaceOutcome] = [:]
        func value(_ source: String?, field: MetadataPlaceField,
                   policy: MetadataPlaceFieldPolicy, tag: IPTCTag) -> String? {
            guard policy != .disabled else { outcomes[field] = .notRequested; return nil }
            guard placeWritable.contains(field) else { outcomes[field] = .preservedByPolicy; return nil }
            guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                outcomes[field] = .unavailable; return nil
            }
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = validate(trimmed, tag: tag) { outcomes[field] = .invalidValue(reason); return nil }
            outcomes[field] = .proposed
            return trimmed
        }
        let city = value(place?.city, field: .city, policy: settings.cityPolicy, tag: .city)
        let country = value(place?.country, field: .country, policy: settings.countryPolicy,
                            tag: .countryPrimaryLocationName)
        let changes = base.changes
        try Task.checkCancellation()
        return MetadataProcessingResult(changes: .init(headline: changes.headline,
            description: changes.description, keywords: changes.keywords, creator: changes.creator,
            copyright: changes.copyright, gpsPosition: changes.gpsPosition,
            existingFieldPolicy: changes.existingFieldPolicy,
            places: city == nil && country == nil ? nil : .init(city: city, country: country,
                cityPolicy: settings.cityPolicy, countryPolicy: settings.countryPolicy)),
            context: context, fields: base.fields, coordinateResolution: coordinates,
            geocoding: stage, geocodingLocaleIdentifier: needsLookup ? settings.localeIdentifier : nil,
            places: outcomes)
    }

    /// Pure resolution against one supplied context; never reads or writes images.
    /// The caller supplies writability determined from original embedded/XMP metadata.
    /// preparePerImage supplies carrier-aware policy and frozen per-image inputs.
    static func resolve(
        _ request: MetadataProcessingRequest,
        context suppliedContext: MetadataTemplateContext,
        writableFields: Set<MetadataWritableField>,
        coordinateResolution: EffectiveMetadataCoordinates.Resolution? = nil
    ) -> MetadataProcessingResult {
        // Photographer always comes from the matched assignment, never recognition
        // or a caller's unrelated sample identity. Copyright cannot reference itself.
        let context = MetadataTemplateContext(
            processingDate: suppliedContext.processingDate,
            processingTimeZone: suppliedContext.processingTimeZone,
            captureDate: suppliedContext.captureDate,
            photographer: request.photographer,
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
        let gps: ScheduledGPSPosition?
        if let requested = request.gpsPosition, !requested.isValid {
            gps = nil
            outcomes[.gpsPosition] = .omitted(.invalidGPSPosition)
        } else {
            gps = writableFields.contains(.gpsPosition) ? request.gpsPosition : nil
            outcomes[.gpsPosition] = writableFields.contains(.gpsPosition)
                ? (gps == nil ? .notRequested : .proposed) : .preservedByPolicy
        }
        var resolvedPolicy = request.existingFieldPolicy
        if gps != nil, coordinateResolution?.scheduledDisposition == .filledEmpty {
            // The strict reader may reject malformed EXIF that the legacy parser
            // interprets as zero. This approved fill must reach the writer; only
            // GPS is promoted, after freezing the original-coordinate decision.
            resolvedPolicy.overwriteFields.insert(.gpsPosition)
        }
        return MetadataProcessingResult(
            changes: ResolvedMetadataChanges(headline: headline, description: description,
                keywords: keywords, creator: creator, copyright: copyright,
                gpsPosition: gps, existingFieldPolicy: resolvedPolicy),
            context: context, fields: outcomes, coordinateResolution: coordinateResolution
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
