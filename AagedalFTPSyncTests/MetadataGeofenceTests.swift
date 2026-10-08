import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataGeofenceTests: XCTestCase {
    private func square(name: String = "My venue") -> MetadataGeofence {
        .init(name: name, vertices: [
            .init(latitude: 59.4, longitude: 10.2),
            .init(latitude: 59.4, longitude: 10.3),
            .init(latitude: 59.6, longitude: 10.3),
            .init(latitude: 59.6, longitude: 10.2)
        ])
    }

    func testPolygonIncludesBoundaryAndExcludesNearbyCoordinates() {
        let area = square()
        XCTAssertTrue(area.isValid)
        XCTAssertTrue(area.contains(latitude: 59.5, longitude: 10.25))
        XCTAssertTrue(area.contains(latitude: 59.4, longitude: 10.25))
        XCTAssertTrue(area.contains(latitude: 59.4, longitude: 10.2))
        XCTAssertFalse(area.contains(latitude: 59.7, longitude: 10.25))
        XCTAssertFalse(area.contains(latitude: 59.5, longitude: 10.35))
    }

    func testInvalidPolygonsAndNamesCannotBeSaved() throws {
        var area = square()
        area.name = "   "
        XCTAssertFalse(area.isValid)
        area = square()
        area.vertices = [area.vertices[0], area.vertices[2], area.vertices[1], area.vertices[3]]
        XCTAssertFalse(area.isValid, "Self-intersecting outlines must be rejected")
        area = square()
        area.vertices[0].latitude = 91
        XCTAssertFalse(area.isValid)
        XCTAssertThrowsError(try MetadataGeocodingSettings(cityPolicy: .overwrite,
            localeIdentifier: "en", geofences: [area]))
    }

    func testSavedAreaRoundTripsWithStrictSettingsAndListPriority() throws {
        let first = square(name: "First"), second = square(name: "Second")
        let settings = try MetadataGeocodingSettings(resolveVariables: true,
            cityPolicy: .overwrite, localeIdentifier: "en", geofences: [first, second])
        XCTAssertEqual(settings.geofence(latitude: 59.5, longitude: 10.25)?.name, "First")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(MetadataGeocodingSettings.self, from: data), settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        var missing = object
        missing.removeValue(forKey: "geofences")
        XCTAssertThrowsError(try JSONDecoder().decode(MetadataGeocodingSettings.self,
            from: JSONSerialization.data(withJSONObject: missing)))
        var future = object
        var areas = try XCTUnwrap(future["geofences"] as? [[String: Any]])
        areas[0]["unknownFutureRule"] = true
        future["geofences"] = areas
        XCTAssertThrowsError(try JSONDecoder().decode(MetadataGeocodingSettings.self,
            from: JSONSerialization.data(withJSONObject: future)))
        var invalid = settings
        invalid.geofences = [first, first]
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))

        let apple = try MetadataGeocodingSettings(cityPolicy: .overwrite,
            localeIdentifier: "en", provider: .apple,
            allowSendingCoordinatesToApple: true, geofences: [first])
        let appleData = try JSONEncoder().encode(apple)
        XCTAssertEqual(try JSONDecoder().decode(MetadataGeocodingSettings.self, from: appleData), apple)
        let appleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: appleData) as? [String: Any])
        XCTAssertEqual(appleObject["schemaVersion"] as? Int, 4)
    }

    func testChangingNamedAreasInvalidatesSavedMetadataReceipt() throws {
        var settings = try MetadataGeocodingSettings(cityPolicy: .overwrite,
            localeIdentifier: "en", geofences: [square()])
        func revision(_ value: MetadataGeocodingSettings) throws -> String {
            try MetadataProcessingFingerprint.settingsRevision(assignment: nil,
                geocoding: value, faceRecognition: nil, timestampPolicy: .sourceModification,
                processingTimeZone: XCTUnwrap(TimeZone(identifier: "Etc/UTC")))
        }
        let original = try revision(settings)
        settings.geofences[0].name = "Another venue"
        XCTAssertNotEqual(try revision(settings), original)
        settings.geofences[0].name = "My venue"
        settings.geofences[0].vertices[0].latitude = 59.41
        XCTAssertNotEqual(try revision(settings), original)
    }
}
