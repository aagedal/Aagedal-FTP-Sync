import Foundation

/// Resolves parsed GPS values without reading files, changing metadata, or doing a lookup.
/// Callers must supply each source as one candidate; missing components never cross sources.
enum EffectiveMetadataCoordinates {
    enum ImageKind: Sendable { case raw, embedded }
    enum Source: Hashable, Sendable { case embeddedEXIF, xmp, scheduled }
    enum ScheduledDisposition: Equatable, Sendable {
        case absent, invalid, preservedExisting, filledEmpty, overwroteExisting
    }

    /// Optional components retain incomplete source data for validation and diagnostics.
    struct Candidate: Sendable {
        let latitude: Double?
        let longitude: Double?
        let altitudeMeters: Double?

        init(latitude: Double?, longitude: Double?, altitudeMeters: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitudeMeters = altitudeMeters
        }

        init(_ position: ScheduledGPSPosition) {
            self.init(latitude: position.latitude, longitude: position.longitude,
                      altitudeMeters: position.altitudeMeters)
        }

        fileprivate var pair: Pair? {
            guard let latitude, let longitude else { return nil }
            // Match the writer's acceptance of a GPS position, including altitude validity.
            guard ScheduledGPSPosition(latitude: latitude, longitude: longitude,
                                       altitudeMeters: altitudeMeters).isValid else { return nil }
            return Pair(latitude: latitude, longitude: longitude)
        }
    }

    struct Pair: Hashable, Sendable {
        let latitude: Double
        let longitude: Double

        fileprivate init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    struct Selection: Equatable, Sendable {
        let pair: Pair
        let source: Source
    }

    struct Conflict: Equatable, Sendable {
        let embeddedEXIF: Pair
        let xmp: Pair
    }

    struct Resolution: Equatable, Sendable {
        let selected: Selection?
        /// Retained even when a scheduled replacement supersedes both existing sources.
        let existingConflict: Conflict?
        let invalidSources: Set<Source>
        let scheduledDisposition: ScheduledDisposition
    }

    static func resolve(
        imageKind: ImageKind,
        embeddedEXIF: Candidate? = nil,
        xmp: Candidate? = nil,
        scheduled: ScheduledGPSPosition? = nil,
        policy: MetadataExistingFieldPolicy = .fillEmpty
    ) -> Resolution {
        let embeddedPair = embeddedEXIF?.pair
        let xmpPair = xmp?.pair
        let scheduledPair = scheduled.flatMap { Candidate($0).pair }
        var invalidSources = Set<Source>()
        if embeddedEXIF != nil && embeddedPair == nil { invalidSources.insert(.embeddedEXIF) }
        if xmp != nil && xmpPair == nil { invalidSources.insert(.xmp) }
        if scheduled != nil && scheduledPair == nil { invalidSources.insert(.scheduled) }

        // Exact comparisons deliberately avoid rounding coordinates near boundaries.
        let conflict: Conflict?
        if let embeddedPair, let xmpPair, embeddedPair != xmpPair {
            conflict = Conflict(embeddedEXIF: embeddedPair, xmp: xmpPair)
        } else {
            conflict = nil
        }
        let embeddedSelection = embeddedPair.map { Selection(pair: $0, source: .embeddedEXIF) }
        let xmpSelection = xmpPair.map { Selection(pair: $0, source: .xmp) }
        let existing: Selection?
        switch imageKind {
        case .raw: existing = xmpSelection ?? embeddedSelection
        case .embedded: existing = embeddedSelection ?? xmpSelection
        }
        let selected: Selection?
        let disposition: ScheduledDisposition
        if let scheduledPair {
            if existing == nil || policy.overwrites(.gpsPosition) {
                selected = Selection(pair: scheduledPair, source: .scheduled)
                disposition = existing == nil ? .filledEmpty : .overwroteExisting
            } else {
                selected = existing
                disposition = .preservedExisting
            }
        } else {
            selected = existing
            disposition = scheduled == nil ? .absent : .invalid
        }
        return Resolution(selected: selected, existingConflict: conflict,
                          invalidSources: invalidSources, scheduledDisposition: disposition)
    }
}
