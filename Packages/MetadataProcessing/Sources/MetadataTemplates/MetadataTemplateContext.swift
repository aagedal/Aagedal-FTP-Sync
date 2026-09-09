import Foundation

/// The caller selects a zone before decoding an EXIF wall-clock value into an instant.
/// Keep this provenance with the operation for preview and audit. No system-zone fallback occurs here.
public struct MetadataCaptureDate: Equatable, Sendable {
    public enum ZoneSource: Equatable, Sendable {
        case explicitOffset(secondsFromGMT: Int)
        case persistedFallback(identifier: String)
    }

    public let date: Date
    public let timeZone: TimeZone
    public let zoneSource: ZoneSource

    /// Returns nil for an invalid offset or zone identifier. Explicit offsets must be whole minutes.
    public init?(date: Date, zoneSource: ZoneSource) {
        let zone: TimeZone?
        switch zoneSource {
        case .explicitOffset(let seconds):
            guard (-14 * 3600 ... 14 * 3600).contains(seconds), seconds.isMultiple(of: 60) else { return nil }
            zone = TimeZone(secondsFromGMT: seconds)
        case .persistedFallback(let identifier):
            zone = TimeZone(identifier: identifier)
        }
        guard let zone else { return nil }
        self.date = date
        self.timeZone = zone
        self.zoneSource = zoneSource
    }
}

/// Freeze one context per processing operation and reuse it for every field and retry.
/// The caller supplies the matched profile's canonical name (including any legacy fallback),
/// and merges existing/accepted Person Shown names before constructing this value.
public struct MetadataTemplateContext: Equatable, Sendable {
    public let processingDate: Date
    public let processingTimeZone: TimeZone
    public let captureDate: MetadataCaptureDate?
    public let photographer: String?
    public let city: String?
    public let country: String?
    public let persons: [String]?

    public init(
        processingDate: Date,
        processingTimeZone: TimeZone,
        captureDate: MetadataCaptureDate? = nil,
        photographer: String? = nil,
        city: String? = nil,
        country: String? = nil,
        persons: [String]? = nil
    ) {
        self.processingDate = processingDate
        // Snapshot even if a caller accidentally supplies .autoupdatingCurrent.
        self.processingTimeZone = TimeZone(identifier: processingTimeZone.identifier) ?? processingTimeZone
        self.captureDate = captureDate
        self.photographer = photographer
        self.city = city
        self.country = country
        self.persons = persons
    }
}
