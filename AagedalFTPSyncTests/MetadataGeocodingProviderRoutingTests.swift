import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataGeocodingProviderRoutingTests: XCTestCase {
    private actor Calls {
        private var count = 0
        func record() { count += 1 }
        func total() -> Int { count }
    }

    private let offlineIdentity = MetadataGeocodingService.Identity(provider: "offline-fixture", version: "1", dataset: "offline-test")
    private let appleIdentity = MetadataGeocodingService.Identity(provider: "apple-fixture", version: "1", dataset: "apple-test")

    private func service(identity: MetadataGeocodingService.Identity, calls: Calls,
                         response: MetadataGeocodingService.ProviderResponse) -> MetadataGeocodingService {
        MetadataGeocodingService(identity: identity) { _ in
            await calls.record()
            return response
        }
    }

    private func appleSettings() throws -> MetadataGeocodingSettings {
        try .init(cityPolicy: .overwrite, countryPolicy: .overwrite, localeIdentifier: "en_US",
                  provider: .apple, allowSendingCoordinatesToApple: true)
    }

    func testRegistryRoutesToSharedSelectedInstanceAndKeepsCachesSeparate() async throws {
        let offlineCalls = Calls(), appleCalls = Calls()
        let offline = service(identity: offlineIdentity, calls: offlineCalls,
            response: .found(.init(city: "Offline city", country: "Country", source: "fixture", distanceMeters: 10)))
        let apple = service(identity: appleIdentity, calls: appleCalls,
            response: .found(.init(city: "Apple city", country: "Country", source: "fixture", distanceMeters: nil)))
        let registry = MetadataProcessingServices(offlineGeocoding: offline, appleGeocoding: apple)
        let offlineSettings = try MetadataGeocodingSettings(cityPolicy: .overwrite, localeIdentifier: "en_US")
        let appleSettings = try appleSettings()
        XCTAssertTrue(try registry.geocoding(for: offlineSettings) === offline)
        XCTAssertTrue(try registry.geocoding(for: appleSettings) === apple)
        XCTAssertTrue(try registry.geocoding(for: appleSettings) === registry.geocoding(for: appleSettings))
        let query = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 59.5, longitude: 10.25, locale: "en_US"))
        let first = await (try registry.geocoding(for: appleSettings)).resolve(query)
        let repeated = await (try registry.geocoding(for: appleSettings)).resolve(query)
        let other = await (try registry.geocoding(for: offlineSettings)).resolve(query)
        XCTAssertEqual(first, repeated)
        guard case .found(let applePlace, let selectedApple) = first,
              case .found(let offlinePlace, let selectedOffline) = other else {
            return XCTFail("Injected providers should return their fixture values")
        }
        XCTAssertEqual(selectedApple, appleIdentity)
        XCTAssertEqual(selectedOffline, offlineIdentity)
        XCTAssertEqual(applePlace.city, "Apple city")
        XCTAssertEqual(offlinePlace.city, "Offline city")
        let appleCount = await appleCalls.total(), offlineCount = await offlineCalls.total()
        XCTAssertEqual(appleCount, 1)
        XCTAssertEqual(offlineCount, 1)
    }

    func testInvalidMutationAndAbsentAppleConsentRejectBeforeRoutingOrLookup() async throws {
        let calls = Calls()
        let fake = service(identity: appleIdentity, calls: calls, response: .noResult)
        let registry = MetadataProcessingServices(offlineGeocoding: fake, appleGeocoding: fake)
        var missingConsent = try appleSettings()
        missingConsent.allowSendingCoordinatesToApple = false
        var invalidLocale = try appleSettings()
        invalidLocale.localeIdentifier = "automatic"
        for settings in [missingConsent, invalidLocale] {
            XCTAssertThrowsError(try registry.geocoding(for: settings))
            do {
                _ = try await MetadataProcessingCoordinator.prepare(assignment: nil, geocoding: settings,
                    service: fake, fileURL: URL(fileURLWithPath: "/nonexistent/apple-privacy-fixture.jpg"),
                    relativePath: "fixture.jpg", processingDate: Date(timeIntervalSince1970: 0),
                    processingTimeZone: TimeZone(secondsFromGMT: 0)!)
                XCTFail("Invalid settings must refuse before reading the image or using an injected provider")
            } catch is MetadataGeocodingSettingsError { }
            catch { XCTFail("Expected settings refusal, got \(error)") }
        }
        let count = await calls.total()
        XCTAssertEqual(count, 0)
    }

    func testUnavailableAppleAdapterDoesNotSelectOfflineInstead() async throws {
        let calls = Calls()
        let offline = service(identity: offlineIdentity, calls: calls, response: .noResult)
        let registry = MetadataProcessingServices(offlineGeocoding: offline, appleGeocoding: nil)
        XCTAssertThrowsError(try registry.geocoding(for: appleSettings()))
        let count = await calls.total()
        XCTAssertEqual(count, 0)
    }

    private func image(gps: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        var metadata = try ImageMetadata.read(from: file)
        if gps { metadata.setGPS(latitude: 59.5, longitude: 10.25) }
        metadata.iptc.city = "Existing city"
        metadata.iptc.countryName = "Existing country"
        try metadata.write(to: file)
        return file
    }

    private func prepare(_ file: URL, service: MetadataGeocodingService) async throws -> MetadataProcessingResult {
        try await MetadataProcessingCoordinator.prepare(assignment: nil, geocoding: appleSettings(),
            service: service, fileURL: file, relativePath: "fixture.jpg",
            processingDate: Date(timeIntervalSince1970: 123_456), processingTimeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func testAppleFixtureProposalsRetainSelectedProvenanceWithoutWriting() async throws {
        let file = try image(), original = try Data(contentsOf: file), calls = Calls()
        let fake = service(identity: appleIdentity, calls: calls,
            response: .found(.init(city: "Resolved city", country: "Resolved country", source: "fixture-address", distanceMeters: nil)))
        let result = try await prepare(file, service: fake)
        guard case .lookup(.found(_, let identity)) = result.geocoding else {
            return XCTFail("Expected the injected Apple result")
        }
        XCTAssertEqual(identity, appleIdentity)
        XCTAssertEqual(result.geocodingLocaleIdentifier, "en_US")
        XCTAssertEqual(result.changes.places?.city, "Resolved city")
        XCTAssertEqual(result.places[.country], .proposed)
        XCTAssertTrue(result.resolutionComplete)
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result))
        XCTAssertEqual(evidence.geocodingDecision?.provider, appleIdentity.provider)
        let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Resolved city"))
        XCTAssertFalse(encoded.contains("fixture-address"))
        XCTAssertFalse(encoded.contains("59.5"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testCoordinatorUsesSelectedRegistryForFailureWithoutOfflineFallback() async throws {
        let file = try image(), original = try Data(contentsOf: file)
        let offlineCalls = Calls(), appleCalls = Calls()
        let offline = service(identity: offlineIdentity, calls: offlineCalls,
            response: .found(.init(city: "Offline fallback must not be used", country: "Country", source: "fixture", distanceMeters: 1)))
        let apple = service(identity: appleIdentity, calls: appleCalls, response: .failure(retryAfter: nil))
        let registry = MetadataProcessingServices(offlineGeocoding: offline, appleGeocoding: apple)
        let result = try await MetadataProcessingCoordinator.prepare(assignment: nil, geocoding: appleSettings(),
            services: registry, fileURL: file, relativePath: "fixture.jpg",
            processingDate: Date(timeIntervalSince1970: 123_456), processingTimeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(result.geocoding, .lookup(.providerFailure))
        XCTAssertEqual(result.geocodingProviderIdentity, appleIdentity)
        XCTAssertNil(result.changes.places)
        XCTAssertFalse(result.hasProposedChanges)
        XCTAssertFalse(result.resolutionComplete)
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result))
        XCTAssertEqual(evidence.geocodingDecision?.provider, appleIdentity.provider)
        XCTAssertEqual(evidence.geocodingDecision?.status, .providerFailure)
        let onlineCount = await appleCalls.total(), offlineCount = await offlineCalls.total()
        XCTAssertEqual(onlineCount, 1)
        XCTAssertEqual(offlineCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testSavedPreviewSelectsAppleRegistryAndDoesNotWrite() async throws {
        let file = try image(), original = try Data(contentsOf: file)
        let offlineCalls = Calls(), appleCalls = Calls()
        let registry = MetadataProcessingServices(
            offlineGeocoding: service(identity: offlineIdentity, calls: offlineCalls, response: .noResult),
            appleGeocoding: service(identity: appleIdentity, calls: appleCalls,
                response: .found(.init(city: "Apple preview", country: "Country", source: "fixture", distanceMeters: nil))))
        let preview = try await MetadataPreviewService.previewLocalFolder(at: file.deletingLastPathComponent(),
            automation: nil, geocoding: appleSettings(), services: registry,
            processingTimeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(preview.items.count, 1)
        let appleCount = await appleCalls.total(), offlineCount = await offlineCalls.total()
        XCTAssertEqual(appleCount, 1)
        XCTAssertEqual(offlineCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAppleNoResultAndMissingGPSRetainExistingFieldsWithoutFallback() async throws {
        let file = try image(), original = try Data(contentsOf: file), calls = Calls()
        let noResult = try await prepare(file, service: service(identity: appleIdentity, calls: calls, response: .noResult))
        XCTAssertEqual(noResult.geocoding, .lookup(.noResult))
        XCTAssertEqual(noResult.places[.city], .unavailable)
        XCTAssertEqual(noResult.places[.country], .unavailable)
        XCTAssertNil(noResult.changes.places)
        XCTAssertFalse(noResult.resolutionComplete)
        XCTAssertFalse(noResult.hasProposedChanges)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let missingCalls = Calls()
        let missing = try await prepare(image(gps: false), service:
            service(identity: appleIdentity, calls: missingCalls, response: .noResult))
        XCTAssertEqual(missing.geocoding, .missingCoordinates)
        XCTAssertFalse(missing.resolutionComplete)
        let count = await missingCalls.total()
        XCTAssertEqual(count, 0)
    }
}
