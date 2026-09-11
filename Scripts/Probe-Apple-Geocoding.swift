import Foundation
import Darwin

/// Opt-in native provider probe using a fixed public Oslo city-centre coordinate.
/// Compile with the application's MetadataGeocodingService.swift and
/// AppleMetadataGeocodingProvider.swift. No user photos or device location are read.
@main
struct ProbeAppleGeocoding {
    static func main() async {
        guard ProcessInfo.processInfo.environment["FTP_SYNC_ALLOW_APPLE_PROBE"] == "1" else {
            print("Not run. Set FTP_SYNC_ALLOW_APPLE_PROBE=1 to send the fixed Oslo fixture coordinates to Apple.")
            exit(2)
        }
        guard let service = AppleMetadataGeocodingProvider.makeService(allowSendingCoordinatesToApple: true),
              let query = MetadataGeocodingService.Query(latitude: 59.9139, longitude: 10.7522, locale: "nb_NO") else {
            print("Could not construct the explicitly selected provider.")
            exit(1)
        }
        let started = Date()
        let result = await service.resolve(query)
        print("Provider: \(service.identity.provider); adapter: \(service.identity.version); locale: \(query.locale)")
        print(String(format: "Elapsed: %.3f seconds", Date().timeIntervalSince(started)))
        switch result {
        case .found(let place, _):
            print("City: \(place.city ?? "<unavailable>"); country: \(place.country ?? "<unavailable>")")
            guard place.city?.isEmpty == false, place.country?.isEmpty == false else { exit(1) }
            print("Native request completed. Check these public fixture names against the expected locale; this is not an app UI or supported-OS matrix pass.")
        default:
            print("Native request did not produce a place: \(result)")
            exit(1)
        }
    }
}
