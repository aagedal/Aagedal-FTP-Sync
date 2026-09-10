import Foundation
import SwiftMediaMetadata

/// Uses only the pinned, bundled GeoNames database. A nearest settlement is not an
/// administrative-boundary determination. City names retain the dataset's spelling.
enum OfflineMetadataGeocodingProvider {
    static let identity = MetadataGeocodingService.Identity(
        provider: "geonames-offline", version: "SwiftMediaMetadata-2.0.0",
        dataset: "sha256:1c0d66422b009340135398674ec93d69366776917be9e9ef179cf1457cceb26b")

    /// The caller should retain and share this service across jobs and previews.
    /// Distance is an explicit policy in metres, not a claim of border accuracy.
    static func makeService(limits: MetadataGeocodingService.Limits = offlineLimits) -> MetadataGeocodingService {
        MetadataGeocodingService(identity: identity, limits: limits, provider: lookup)
    }

    static var offlineLimits: MetadataGeocodingService.Limits {
        var limits = MetadataGeocodingService.Limits()
        limits.maximumDistanceMeters = 50_000
        return limits
    }

    /// The service executes this closure on its detached, bounded provider worker.
    /// Lazy database/tree construction therefore does not occupy the main actor.
    /// There is no online provider or fallback in this adapter.
    static let lookup: MetadataGeocodingService.Provider = { query in
        guard !Task.isCancelled else { return .failure(retryAfter: nil) }
        guard let location = ReverseGeocoder.shared.lookup(
            latitude: query.latitude, longitude: query.longitude,
            maxDistance: .greatestFiniteMagnitude
        ) else { return .noResult }
        guard !Task.isCancelled else { return .failure(retryAfter: nil) }
        // Do not use localizedCountry's implicit English fallback when the requested
        // locale cannot name the region. Missing values remain explicit downstream.
        let country = Locale(identifier: query.locale).localizedString(forRegionCode: location.countryCodeAlpha2)
        return .found(.init(city: location.city.isEmpty ? nil : location.city,
                            country: country?.isEmpty == false ? country : nil,
                            source: "GeoNames nearest settlement; city name from bundled dataset",
                            distanceMeters: location.distance * 1_000))
    }
}
