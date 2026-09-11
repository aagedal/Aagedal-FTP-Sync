import Foundation

enum MetadataPlaceFieldPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled, fillEmpty, overwrite
}

enum MetadataGeocodingProviderSelection: String, CaseIterable, Hashable, Sendable {
    case offline, apple
}

enum MetadataGeocodingSettingsError: LocalizedError, Equatable {
    case invalidSettings, requiresOneWayJob, requiresLocalDestination, appleConsentRequired

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            "The saved geocoding settings are malformed or unsupported. Choose a supported concrete locale and provider policy in version 3."
        case .requiresOneWayJob: "Geocoding is only available for one-way jobs."
        case .requiresLocalDestination: "Geocoding requires a local destination folder."
        case .appleConsentRequired: "Allow sending image coordinates to Apple before selecting the Apple geocoding provider."
        }
    }
}

/// Job-local provider policy. Absence on a job means off; calendar programming
/// never carries this configuration. Changing provider/dataset policy requires
/// an explicit future schema adapter rather than silently changing its meaning.
struct MetadataGeocodingSettings: Codable, Hashable, Sendable {
    static let schemaVersion = 1
    static let providerIdentifier = "geonames-offline"
    static let providerVersion = "SwiftMediaMetadata-2.0.0"
    static let datasetIdentifier = "sha256:1c0d66422b009340135398674ec93d69366776917be9e9ef179cf1457cceb26b"
    static let maximumDistanceMeters = 50_000
    // Portable policy identity, independent of the OS-specific runtime adapter.
    static let appleSchemaVersion = 2
    static let appleProviderIdentifier = "apple-online"
    static let appleProviderVersion = "Apple-geocoding-policy-1"
    static let appleDatasetIdentifier = "Apple-server-managed"
    static let appleMaximumDistanceMeters = 100_000

    var resolveVariables: Bool
    var cityPolicy: MetadataPlaceFieldPolicy
    var countryPolicy: MetadataPlaceFieldPolicy
    var localeIdentifier: String
    var provider: MetadataGeocodingProviderSelection = .offline
    var allowSendingCoordinatesToApple = false

    init(resolveVariables: Bool = false, cityPolicy: MetadataPlaceFieldPolicy = .disabled,
         countryPolicy: MetadataPlaceFieldPolicy = .disabled, localeIdentifier: String,
         provider: MetadataGeocodingProviderSelection = .offline,
         allowSendingCoordinatesToApple: Bool = false) throws {
        self.resolveVariables = resolveVariables
        self.cityPolicy = cityPolicy
        self.countryPolicy = countryPolicy
        self.localeIdentifier = localeIdentifier
        self.provider = provider
        self.allowSendingCoordinatesToApple = allowSendingCoordinatesToApple
        try validate()
    }

    var isEnabled: Bool { resolveVariables || cityPolicy != .disabled || countryPolicy != .disabled }

    mutating func selectProvider(_ provider: MetadataGeocodingProviderSelection,
                                 allowSendingCoordinatesToApple: Bool = false) throws {
        var selected = self
        selected.provider = provider
        selected.allowSendingCoordinatesToApple = allowSendingCoordinatesToApple
        try selected.validate()
        self = selected
    }

    func validate() throws {
        switch provider {
        case .offline:
            guard !allowSendingCoordinatesToApple else { throw MetadataGeocodingSettingsError.invalidSettings }
        case .apple:
            guard allowSendingCoordinatesToApple else { throw MetadataGeocodingSettingsError.appleConsentRequired }
        }
        guard MetadataGeocodingService.Query(latitude: 0, longitude: 0, locale: localeIdentifier) != nil else {
            throw MetadataGeocodingSettingsError.invalidSettings
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, providerIdentifier, providerVersion, datasetIdentifier, maximumDistanceMeters
        case resolveVariables, cityPolicy, countryPolicy, localeIdentifier, allowSendingCoordinatesToApple
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
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decode(Int.self, forKey: .schemaVersion)
            let expectedKeys: Set<String>
            switch version {
            case Self.schemaVersion:
                expectedKeys = Set(CodingKeys.allCases.filter { $0 != .allowSendingCoordinatesToApple }.map(\.rawValue))
                provider = .offline
                allowSendingCoordinatesToApple = false
                guard try values.decode(String.self, forKey: .providerIdentifier) == Self.providerIdentifier,
                      try values.decode(String.self, forKey: .providerVersion) == Self.providerVersion,
                      try values.decode(String.self, forKey: .datasetIdentifier) == Self.datasetIdentifier,
                      try values.decode(Int.self, forKey: .maximumDistanceMeters) == Self.maximumDistanceMeters else {
                    throw MetadataGeocodingSettingsError.invalidSettings
                }
            case Self.appleSchemaVersion:
                expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
                provider = .apple
                allowSendingCoordinatesToApple = try values.decode(Bool.self, forKey: .allowSendingCoordinatesToApple)
                guard try values.decode(String.self, forKey: .providerIdentifier) == Self.appleProviderIdentifier,
                      try values.decode(String.self, forKey: .providerVersion) == Self.appleProviderVersion,
                      try values.decode(String.self, forKey: .datasetIdentifier) == Self.appleDatasetIdentifier,
                      try values.decode(Int.self, forKey: .maximumDistanceMeters) == Self.appleMaximumDistanceMeters else {
                    throw MetadataGeocodingSettingsError.invalidSettings
                }
            default: throw MetadataGeocodingSettingsError.invalidSettings
            }
            guard Set(keys.allKeys.map(\.stringValue)) == expectedKeys else {
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
        switch provider {
        case .offline:
            // The schema-1 representation must remain byte-for-byte compatible.
            try values.encode(Self.schemaVersion, forKey: .schemaVersion)
            try values.encode(Self.providerIdentifier, forKey: .providerIdentifier)
            try values.encode(Self.providerVersion, forKey: .providerVersion)
            try values.encode(Self.datasetIdentifier, forKey: .datasetIdentifier)
            try values.encode(Self.maximumDistanceMeters, forKey: .maximumDistanceMeters)
        case .apple:
            try values.encode(Self.appleSchemaVersion, forKey: .schemaVersion)
            try values.encode(Self.appleProviderIdentifier, forKey: .providerIdentifier)
            try values.encode(Self.appleProviderVersion, forKey: .providerVersion)
            try values.encode(Self.appleDatasetIdentifier, forKey: .datasetIdentifier)
            try values.encode(Self.appleMaximumDistanceMeters, forKey: .maximumDistanceMeters)
            try values.encode(allowSendingCoordinatesToApple, forKey: .allowSendingCoordinatesToApple)
        }
        try values.encode(resolveVariables, forKey: .resolveVariables)
        try values.encode(cityPolicy, forKey: .cityPolicy)
        try values.encode(countryPolicy, forKey: .countryPolicy)
        try values.encode(localeIdentifier, forKey: .localeIdentifier)
    }
}
