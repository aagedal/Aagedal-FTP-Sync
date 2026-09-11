import Foundation

/// Application-lifetime queue/cache ownership shared by jobs and previews.
/// Constructing the service performs no lookup or database loading. Tests inject
/// separate services so fixture outcomes cannot enter the application's cache.
struct MetadataProcessingServices: Sendable {
    static let shared = MetadataProcessingServices()
    let offlineGeocoding: MetadataGeocodingService

    init(offlineGeocoding: MetadataGeocodingService = OfflineMetadataGeocodingProvider.makeService()) {
        self.offlineGeocoding = offlineGeocoding
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
