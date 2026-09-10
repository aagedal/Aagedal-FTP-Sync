import XCTest
@testable import AagedalFTPSync

final class OfflineMetadataGeocodingProviderTests: XCTestCase {
    func testPinnedDatabaseReturnsOsloWithDistanceAndProvenance() async throws {
        let service = OfflineMetadataGeocodingProvider.makeService()
        let query = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 59.9139, longitude: 10.7522, locale: "en_US"))
        guard case .found(let place, let identity) = await service.resolve(query) else {
            return XCTFail("Bundled database should resolve Oslo")
        }
        XCTAssertEqual(place.city, "Oslo")
        XCTAssertEqual(place.country, "Norway")
        XCTAssertLessThan(try XCTUnwrap(place.distanceMeters), 1_000)
        XCTAssertTrue(place.source.contains("nearest settlement"))
        XCTAssertEqual(identity, OfflineMetadataGeocodingProvider.identity)
    }

    func testCountryLocaleChangesWithoutTranslatingDatasetCity() async throws {
        let service = OfflineMetadataGeocodingProvider.makeService()
        let english = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 35.6762, longitude: 139.6503, locale: "en_US"))
        let french = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 35.6762, longitude: 139.6503, locale: "fr_FR"))
        guard case .found(let en, _) = await service.resolve(english),
              case .found(let fr, _) = await service.resolve(french) else {
            return XCTFail("Both concrete country locales should resolve")
        }
        XCTAssertEqual(en.country, "Japan")
        XCTAssertEqual(fr.country, "Japon")
        XCTAssertEqual(en.city, fr.city)
        XCTAssertEqual(en.distanceMeters, fr.distanceMeters)
    }

    func testOceanAndConfiguredDistanceThresholdAreExplicit() async throws {
        let ocean = try XCTUnwrap(MetadataGeocodingService.Query(latitude: -48.876, longitude: -123.393, locale: "en_US"))
        let defaultService = OfflineMetadataGeocodingProvider.makeService()
        let oceanResult = await defaultService.resolve(ocean)
        XCTAssertEqual(oceanResult, .tooDistant)
        var strict = OfflineMetadataGeocodingProvider.offlineLimits
        strict.maximumDistanceMeters = 1
        let strictService = OfflineMetadataGeocodingProvider.makeService(limits: strict)
        let oslo = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 59.9139, longitude: 10.7522, locale: "en_US"))
        let strictResult = await strictService.resolve(oslo)
        XCTAssertEqual(strictResult, .tooDistant)
    }
}
