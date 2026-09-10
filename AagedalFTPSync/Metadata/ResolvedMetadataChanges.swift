import Foundation

/// One immutable set of final values shared by assessment and writing. This is
/// deliberately not Codable: resolved text must never replace stored templates.
/// Empty values mean no proposed write; they never erase existing metadata.
/// The processing coordinator owns omission reasons and completion status outside
/// this value. Writers only consume final values and never expand template syntax.
struct ResolvedMetadataChanges: Equatable, Sendable {
    let headline: String
    let description: String
    let keywords: [String]
    let creator: String
    let copyright: String
    let gpsPosition: ScheduledGPSPosition?
    let existingFieldPolicy: MetadataExistingFieldPolicy

    /// Keywords have already been normalized by the resolver. Preserve their
    /// entry boundaries and order, including commas inside an expanded value.
    init(
        headline: String = "", description: String = "", keywords: [String] = [],
        creator: String = "", copyright: String = "",
        gpsPosition: ScheduledGPSPosition? = nil,
        existingFieldPolicy: MetadataExistingFieldPolicy = .standard
    ) {
        self.headline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keywords = keywords
        self.creator = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        self.copyright = copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gpsPosition = gpsPosition
        self.existingFieldPolicy = existingFieldPolicy
    }

    /// Compatibility boundary: legacy source remains literal, including braces.
    /// Keep its existing keyword normalization and photographer-name fallback.
    static func literal(_ assignment: MetadataAssignment) -> Self {
        Self(
            headline: assignment.clip.fields.headline,
            description: assignment.clip.fields.description,
            keywords: assignment.clip.fields.normalizedKeywords,
            creator: assignment.photographer.photographerName,
            copyright: assignment.photographer.copyrightNotice,
            gpsPosition: assignment.clip.gpsPosition,
            existingFieldPolicy: assignment.existingFieldPolicy
        )
    }
}
