import Foundation

enum MetadataPlaceFieldPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled, fillEmpty, overwrite
}

enum MetadataGeocodingSettingsError: LocalizedError, Equatable {
    case invalidSettings, requiresOneWayJob, requiresLocalDestination

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            "The saved offline geocoding settings are malformed or unsupported. Choose a supported concrete locale and offline policy in version 3."
        case .requiresOneWayJob: "Offline geocoding is only available for one-way jobs."
        case .requiresLocalDestination: "Offline geocoding requires a local destination folder."
        }
    }
}

/// Job-local offline policy. Absence on a job means off; calendar programming
/// never carries this configuration. Changing provider/dataset policy requires
/// an explicit future schema adapter rather than silently changing its meaning.
struct MetadataGeocodingSettings: Codable, Hashable, Sendable {
    static let schemaVersion = 1
    static let providerIdentifier = "geonames-offline"
    static let providerVersion = "SwiftMediaMetadata-2.0.0"
    static let datasetIdentifier = "sha256:1c0d66422b009340135398674ec93d69366776917be9e9ef179cf1457cceb26b"
    static let maximumDistanceMeters = 50_000

    var resolveVariables: Bool
    var cityPolicy: MetadataPlaceFieldPolicy
    var countryPolicy: MetadataPlaceFieldPolicy
    var localeIdentifier: String

    init(resolveVariables: Bool = false, cityPolicy: MetadataPlaceFieldPolicy = .disabled,
         countryPolicy: MetadataPlaceFieldPolicy = .disabled, localeIdentifier: String) throws {
        self.resolveVariables = resolveVariables
        self.cityPolicy = cityPolicy
        self.countryPolicy = countryPolicy
        self.localeIdentifier = localeIdentifier
        try validate()
    }

    var isEnabled: Bool { resolveVariables || cityPolicy != .disabled || countryPolicy != .disabled }

    func validate() throws {
        guard MetadataGeocodingService.Query(latitude: 0, longitude: 0, locale: localeIdentifier) != nil else {
            throw MetadataGeocodingSettingsError.invalidSettings
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, providerIdentifier, providerVersion, datasetIdentifier, maximumDistanceMeters
        case resolveVariables, cityPolicy, countryPolicy, localeIdentifier
    }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        do {
            let keys = try decoder.container(keyedBy: Key.self)
            guard Set(keys.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw MetadataGeocodingSettingsError.invalidSettings
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard try values.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion,
                  try values.decode(String.self, forKey: .providerIdentifier) == Self.providerIdentifier,
                  try values.decode(String.self, forKey: .providerVersion) == Self.providerVersion,
                  try values.decode(String.self, forKey: .datasetIdentifier) == Self.datasetIdentifier,
                  try values.decode(Int.self, forKey: .maximumDistanceMeters) == Self.maximumDistanceMeters else {
                throw MetadataGeocodingSettingsError.invalidSettings
            }
            resolveVariables = try values.decode(Bool.self, forKey: .resolveVariables)
            cityPolicy = try values.decode(MetadataPlaceFieldPolicy.self, forKey: .cityPolicy)
            countryPolicy = try values.decode(MetadataPlaceFieldPolicy.self, forKey: .countryPolicy)
            localeIdentifier = try values.decode(String.self, forKey: .localeIdentifier)
            try validate()
        } catch { throw MetadataGeocodingSettingsError.invalidSettings }
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(Self.providerIdentifier, forKey: .providerIdentifier)
        try values.encode(Self.providerVersion, forKey: .providerVersion)
        try values.encode(Self.datasetIdentifier, forKey: .datasetIdentifier)
        try values.encode(Self.maximumDistanceMeters, forKey: .maximumDistanceMeters)
        try values.encode(resolveVariables, forKey: .resolveVariables)
        try values.encode(cityPolicy, forKey: .cityPolicy)
        try values.encode(countryPolicy, forKey: .countryPolicy)
        try values.encode(localeIdentifier, forKey: .localeIdentifier)
    }
}
