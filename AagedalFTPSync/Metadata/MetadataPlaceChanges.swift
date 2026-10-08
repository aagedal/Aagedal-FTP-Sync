import Foundation

/// Separate from scheduled/shared metadata policy; these fields are local enrichment.
enum MetadataPlaceField: String, CaseIterable, Hashable, Sendable {
    case city, country
    var title: String { self == .city ? "City" : "Country" }
}

/// Resolved output only, never persisted template source. Nil or empty values do
/// not erase a field. Each place field has its own explicit write policy.
struct ResolvedMetadataPlaceChanges: Equatable, Sendable {
    let city: String?
    let country: String?
    let cityPolicy: MetadataPlaceFieldPolicy
    let countryPolicy: MetadataPlaceFieldPolicy

    init(city: String? = nil, country: String? = nil,
         cityPolicy: MetadataPlaceFieldPolicy = .disabled, countryPolicy: MetadataPlaceFieldPolicy = .disabled) {
        func value(_ source: String?) -> String? {
            guard let source else { return nil }
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.city = value(city)
        self.country = value(country)
        self.cityPolicy = cityPolicy
        self.countryPolicy = countryPolicy
    }
}
