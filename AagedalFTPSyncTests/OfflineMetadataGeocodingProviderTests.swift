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

    func testPublicRuralAndCoastalFixturesExerciseNearestSettlementPolicy() async throws {
        let service = OfflineMetadataGeocodingProvider.makeService()
        let rural = try XCTUnwrap(MetadataGeocodingService.Query(
            latitude: 60.1000,
            longitude: 7.5000,
            locale: "en_US"
        ))
        let ruralResult = await service.resolve(rural)
        XCTAssertEqual(ruralResult, .tooDistant)

        let coastal = try XCTUnwrap(MetadataGeocodingService.Query(
            latitude: 58.8887,
            longitude: 5.6009,
            locale: "en_US"
        ))
        guard case .found(let place, let identity) = await service.resolve(coastal) else {
            return XCTFail("Sola coast should resolve to a nearby settlement")
        }
        XCTAssertEqual(place.country, "Norway")
        XCTAssertFalse(try XCTUnwrap(place.city).isEmpty)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(place.distanceMeters),
            OfflineMetadataGeocodingProvider.offlineLimits.maximumDistanceMeters
        )
        XCTAssertEqual(identity, OfflineMetadataGeocodingProvider.identity)
    }

    func testNearbyCrossBorderFixturesRemainDistinctWithoutCoordinateRounding() async throws {
        let service = OfflineMetadataGeocodingProvider.makeService()
        let denmark = try XCTUnwrap(MetadataGeocodingService.Query(
            latitude: 56.0361,
            longitude: 12.6136,
            locale: "en_US"
        ))
        let sweden = try XCTUnwrap(MetadataGeocodingService.Query(
            latitude: 56.0465,
            longitude: 12.6945,
            locale: "en_US"
        ))

        guard case .found(let danishPlace, _) = await service.resolve(denmark),
              case .found(let swedishPlace, _) = await service.resolve(sweden) else {
            return XCTFail("Both sides of the Øresund border should resolve")
        }

        XCTAssertEqual(danishPlace.country, "Denmark")
        XCTAssertEqual(swedishPlace.country, "Sweden")
        XCTAssertNotEqual(danishPlace.city, swedishPlace.city)
        XCTAssertLessThan(try XCTUnwrap(danishPlace.distanceMeters), 5_000)
        XCTAssertLessThan(try XCTUnwrap(swedishPlace.distanceMeters), 5_000)
    }
}
