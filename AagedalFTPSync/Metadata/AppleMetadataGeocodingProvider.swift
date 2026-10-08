import Foundation
import CoreLocation
import MapKit

/// Callback completion is the lifetime boundary, including after cancel().
/// Implementations must call completion exactly once and never resume early on cancellation.
@MainActor
protocol AppleMetadataGeocodingRequest: AnyObject, Sendable {
    func start(completion: @escaping @Sendable (MetadataGeocodingService.ProviderResponse) -> Void)
    func cancel()
}

/// Construction is inert. Only explicitly opted-in resolution sends supplied coordinates
/// to Apple. No CLLocationManager, device location permission, or offline fallback is used.
enum AppleMetadataGeocodingProvider {
    typealias RequestFactory = @MainActor @Sendable (MetadataGeocodingService.Query) -> (any AppleMetadataGeocodingRequest)?

    static var identity: MetadataGeocodingService.Identity {
        let adapter: String
        if #available(macOS 26.0, *) { adapter = "MapKit-26" } else { adapter = "CoreLocation-14" }
        return .init(provider: "apple-online", version: adapter, dataset: "Apple-server-managed")
    }

    static var onlineLimits: MetadataGeocodingService.Limits {
        var limits = MetadataGeocodingService.Limits()
        limits.concurrent = 1
        // Provisional conservative pause after completion, not an Apple quota guarantee.
        limits.minimumStartInterval = 1
        limits.work = 16
        limits.callers = 64
        return limits
    }

    /// Retain one service across jobs and previews; per-file construction defeats pacing.
    static func makeService(allowSendingCoordinatesToApple: Bool) -> MetadataGeocodingService? {
        makeService(allowSendingCoordinatesToApple: allowSendingCoordinatesToApple,
                    requestFactory: nativeRequest)
    }

    /// Injection seam: tests use callbacks without invoking either Apple service.
    static func makeService(allowSendingCoordinatesToApple: Bool,
                            requestFactory: @escaping RequestFactory) -> MetadataGeocodingService? {
        guard allowSendingCoordinatesToApple else { return nil }
        return MetadataGeocodingService(identity: identity, limits: onlineLimits) { query in
            await perform(query, requestFactory: requestFactory)
        }
    }

    @MainActor
    static func perform(_ query: MetadataGeocodingService.Query,
                        requestFactory: RequestFactory) async -> MetadataGeocodingService.ProviderResponse {
        guard !Task.isCancelled, let request = requestFactory(query) else { return .failure(retryAfter: nil) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(retryAfter: nil))
                    return
                }
                request.start { response in continuation.resume(returning: response) }
            }
        } onCancel: {
            // This bounded actor hop only signals cancellation. It does not resume the
            // continuation: the queue still owns the native worker until its callback.
            Task { @MainActor in request.cancel() }
        }
    }

    @MainActor
    private static func nativeRequest(_ query: MetadataGeocodingService.Query) -> (any AppleMetadataGeocodingRequest)? {
        if #available(macOS 26.0, *) { return MapKitRequest(query: query) }
        return CoreLocationRequest(query: query)
    }

    static func errorResponse(_ error: NSError) -> MetadataGeocodingService.ProviderResponse {
        if (error.domain == MKErrorDomain && error.code == MKError.placemarkNotFound.rawValue) ||
            (error.domain == kCLErrorDomain && error.code == CLError.geocodeFoundNoResult.rawValue) {
            return .noResult
        }
        return .failure(retryAfter: nil)
    }

    static func response(city: String?, country: String?, source: String) -> MetadataGeocodingService.ProviderResponse {
        let city = city?.isEmpty == false ? city : nil
        let country = country?.isEmpty == false ? country : nil
        guard city != nil || country != nil else { return .noResult }
        return .found(.init(city: city, country: country, source: source, distanceMeters: nil))
    }

    @available(macOS 26.0, *)
    @MainActor
    private final class MapKitRequest: AppleMetadataGeocodingRequest {
        let request: MKReverseGeocodingRequest
        init?(query: MetadataGeocodingService.Query) {
            guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: query.latitude, longitude: query.longitude)) else { return nil }
            request.preferredLocale = Locale(identifier: query.locale)
            self.request = request
        }
        func start(completion: @escaping @Sendable (MetadataGeocodingService.ProviderResponse) -> Void) {
            request.getMapItems { items, error in
                if let error { completion(AppleMetadataGeocodingProvider.errorResponse(error as NSError)); return }
                let address = items?.first?.addressRepresentations
                completion(AppleMetadataGeocodingProvider.response(city: address?.cityName, country: address?.regionName,
                                                                  source: "Apple MapKit reverse geocoder"))
            }
        }
        func cancel() { request.cancel() }
    }

    @MainActor
    private final class CoreLocationRequest: AppleMetadataGeocodingRequest {
        let geocoder = CLGeocoder()
        let query: MetadataGeocodingService.Query
        init(query: MetadataGeocodingService.Query) { self.query = query }
        func start(completion: @escaping @Sendable (MetadataGeocodingService.ProviderResponse) -> Void) {
            geocoder.reverseGeocodeLocation(CLLocation(latitude: query.latitude, longitude: query.longitude),
                                            preferredLocale: Locale(identifier: query.locale)) { places, error in
                if let error {
                    completion(AppleMetadataGeocodingProvider.errorResponse(error as NSError))
                    return
                }
                let place = places?.first
                completion(AppleMetadataGeocodingProvider.response(city: place?.locality, country: place?.country,
                                                                  source: "Apple Core Location reverse geocoder"))
            }
        }
        func cancel() { geocoder.cancelGeocode() }
    }
}
