import Foundation

/// Application-lifetime queue/cache ownership shared by jobs and previews.
/// Constructing the service performs no lookup or database loading. Tests inject
/// separate services so fixture outcomes cannot enter the application's cache.
struct MetadataProcessingServices: Sendable {
    static let shared = MetadataProcessingServices()
    let offlineGeocoding: MetadataGeocodingService
    private let appleGeocoding: MetadataGeocodingService?

    init(offlineGeocoding: MetadataGeocodingService = OfflineMetadataGeocodingProvider.makeService(),
         appleGeocoding: MetadataGeocodingService? = AppleMetadataGeocodingProvider.makeService(allowSendingCoordinatesToApple: true)) {
        self.offlineGeocoding = offlineGeocoding
        // Both factories are inert. Constructing the shared queue is not consent:
        // every operation must pass the persisted selection check below before use.
        self.appleGeocoding = appleGeocoding
    }

    func geocoding(for settings: MetadataGeocodingSettings) throws -> MetadataGeocodingService {
        try settings.validate()
        switch settings.provider {
        case .offline: return offlineGeocoding
        case .apple:
            guard settings.allowSendingCoordinatesToApple, let appleGeocoding else {
                throw MetadataGeocodingSettingsError.invalidSettings
            }
            return appleGeocoding
        }
    }

    static func geocodingApplies(to relativePath: String, settings: MetadataGeocodingSettings?) -> Bool {
        settings?.isEnabled == true
            && FilterPreset.photos.extensions?.contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased()) == true
    }
}

extension SyncJob {
    var metadataOperationTimeZone: TimeZone? {
        get throws {
            if metadataGeocoding?.isEnabled == true { return try requiredMetadataProcessingTimeZone() }
            return try validatedMetadataProcessingTimeZone
        }
    }
}
