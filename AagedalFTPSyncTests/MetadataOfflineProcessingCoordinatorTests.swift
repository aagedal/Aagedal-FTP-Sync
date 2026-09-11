import AppKit
import Foundation
import MetadataTemplates
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataOfflineProcessingCoordinatorTests: XCTestCase {
    private actor Calls {
        var queries: [MetadataGeocodingService.Query] = []
        func record(_ query: MetadataGeocodingService.Query) { queries.append(query) }
        func all() -> [MetadataGeocodingService.Query] { queries }
    }

    private func image(gps: Bool = true, headline: String = "") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-processing-\(UUID())")
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
        metadata.iptc.headline = headline
        try metadata.write(to: file)
        return file
    }

    private func assignment(source: String, active: Bool = true) throws -> MetadataAssignment {
        let photographer = PhotographerProfile(name: "Fixture", filenamePrefix: "CN", creator: "Canonical", copyrightNotice: "")
        var fields = ScheduledMetadataFields(headline: source)
        if active { fields.setHeadline(try .activated(source)) }
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Fixture",
            startsAt: Date(timeIntervalSince1970: 0), endsAt: Date(timeIntervalSince1970: 600), fields: fields)
        return MetadataAssignment(photographer: photographer, clip: clip, existingFieldPolicy: .fillEmpty)
    }

    private func service(_ calls: Calls, response: MetadataGeocodingService.ProviderResponse =
        .found(.init(city: "Oslo", country: "Norge", source: "fixture", distanceMeters: 100))) -> MetadataGeocodingService {
        MetadataGeocodingService(identity: .init(provider: "fixture", version: "1", dataset: "test")) { query in
            await calls.record(query)
            return response
        }
    }

    private func prepare(_ file: URL, assignment: MetadataAssignment? = nil,
                         settings: MetadataGeocodingSettings?, service: MetadataGeocodingService,
                         relativePath: String = "fixture.jpg") async throws -> MetadataProcessingResult {
        try await MetadataProcessingCoordinator.prepare(assignment: assignment, geocoding: settings,
            service: service, fileURL: file, relativePath: relativePath,
            processingDate: Date(timeIntervalSince1970: 123_456), processingTimeZone: TimeZone(identifier: "Etc/UTC")!)
    }

    func testStandaloneProposesPlacesWithoutIdentityOrMutationAndLooksUpOnce() async throws {
        let file = try image(), original = try Data(contentsOf: file), calls = Calls()
        let settings = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "nb_NO")
        let result = try await prepare(file, settings: settings, service: service(calls))
        XCTAssertEqual(result.changes.places?.city, "Oslo")
        XCTAssertEqual(result.changes.places?.country, "Norge")
        XCTAssertEqual(result.places[.city], .proposed)
        XCTAssertNil(result.context?.photographer)
        XCTAssertTrue(result.changes.creator.isEmpty)
        XCTAssertTrue(result.hasProposedChanges)
        XCTAssertTrue(result.resolutionComplete)
        let queries = await calls.all()
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first?.latitude, 59.5)
        XCTAssertEqual(queries.first?.locale, "nb_NO")
        XCTAssertEqual(result.geocodingLocaleIdentifier, "nb_NO")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMissingGPSAndNoResultAreIncompleteWithoutPlaceWrites() async throws {
        let settings = try MetadataGeocodingSettings(cityPolicy: .overwrite, localeIdentifier: "en_US")
        let calls = Calls()
        let missing = try await prepare(image(gps: false), settings: settings, service: service(calls))
        XCTAssertEqual(missing.geocoding, .missingCoordinates)
        XCTAssertEqual(missing.geocodingLocaleIdentifier, "en_US")
        XCTAssertEqual(missing.places[.city], .unavailable)
        XCTAssertFalse(missing.hasProposedChanges)
        XCTAssertFalse(missing.resolutionComplete)
        let missingCalls = await calls.all()
        XCTAssertTrue(missingCalls.isEmpty)
        let noResult = try await prepare(image(), settings: settings, service: service(calls, response: .noResult))
        XCTAssertEqual(noResult.geocoding, .lookup(.noResult))
        XCTAssertNil(noResult.changes.places)
        XCTAssertFalse(noResult.resolutionComplete)
    }

    func testCityLimitsAndMissingCountryOmitIndependently() async throws {
        let settings = try MetadataGeocodingSettings(cityPolicy: .overwrite, countryPolicy: .overwrite, localeIdentifier: "en_US")
        let tooLong = try await prepare(image(), settings: settings, service: service(Calls(), response:
            .found(.init(city: String(repeating: "é", count: 17), country: "Norway", source: "fixture", distanceMeters: 1))))
        XCTAssertEqual(tooLong.places[.city], .invalidValue(.writerByteLimit(maximum: 32)))
        XCTAssertEqual(tooLong.changes.places?.country, "Norway")
        XCTAssertNil(tooLong.changes.places?.city)
        XCTAssertFalse(tooLong.resolutionComplete)
        let missing = try await prepare(image(), settings: settings, service: service(Calls(), response:
            .found(.init(city: "Oslo", country: nil, source: "fixture", distanceMeters: 1))))
        XCTAssertEqual(missing.places[.country], .unavailable)
        XCTAssertEqual(missing.changes.places?.city, "Oslo")
        XCTAssertFalse(missing.resolutionComplete)
    }

    func testPreservedTemplateDoesNotTriggerLookupOrMissingDependency() async throws {
        let calls = Calls()
        let result = try await prepare(image(headline: "Keep"), assignment: assignment(source: "{gps:city}"),
            settings: try .init(resolveVariables: true, localeIdentifier: "en_US"), service: service(calls))
        XCTAssertEqual(result.geocoding, .notRequested)
        XCTAssertEqual(result.fields[.headline], .preservedByPolicy)
        XCTAssertTrue(result.resolutionComplete)
        let queries = await calls.all()
        XCTAssertTrue(queries.isEmpty)
    }

    func testVariableConsentAndLegacyLiteralBoundaries() async throws {
        let calls = Calls(), file = try image()
        let enabled = try MetadataGeocodingSettings(resolveVariables: true, localeIdentifier: "en_US")
        let resolved = try await prepare(file, assignment: assignment(source: "{photographer} in {gps:city}"),
            settings: enabled, service: service(calls))
        XCTAssertEqual(resolved.changes.headline, "Canonical in Oslo")
        let literal = try await prepare(file, assignment: assignment(source: "{gps:city}", active: false),
            settings: enabled, service: service(calls))
        XCTAssertEqual(literal.changes.headline, "{gps:city}")
        XCTAssertEqual(literal.geocoding, .notRequested)
        let withoutConsent = try await prepare(file, assignment: assignment(source: "{gps:city}"),
            settings: try .init(cityPolicy: .overwrite, localeIdentifier: "en_US"), service: service(calls))
        XCTAssertTrue(withoutConsent.changes.headline.isEmpty)
        XCTAssertEqual(withoutConsent.changes.places?.city, "Oslo")
        XCTAssertFalse(withoutConsent.resolutionComplete)
    }

    func testPreservedStandalonePlacesSkipLookupEvenWithoutGPS() async throws {
        let file = try image(gps: false), calls = Calls()
        var metadata = try ImageMetadata.read(from: file)
        metadata.iptc.city = "Existing city"
        metadata.iptc.countryName = "Existing country"
        try metadata.write(to: file)
        let result = try await prepare(file,
            settings: try .init(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en_US"),
            service: service(calls))
        XCTAssertEqual(result.geocoding, .notRequested)
        XCTAssertEqual(result.places[.city], .preservedByPolicy)
        XCTAssertEqual(result.places[.country], .preservedByPolicy)
        XCTAssertFalse(result.hasProposedChanges)
        XCTAssertTrue(result.resolutionComplete)
        let queries = await calls.all()
        XCTAssertTrue(queries.isEmpty)
    }

    private actor ProviderGate {
        var entered = false
        var started: CheckedContinuation<Void, Never>?
        var finish: CheckedContinuation<Void, Never>?
        func run() async {
            entered = true; started?.resume(); started = nil
            await withCheckedContinuation { finish = $0 }
        }
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { started = $0 }
        }
        func release() { finish?.resume(); finish = nil }
    }

    func testCancellationThrowsWithoutTurningIntoAnIncompleteAuditResult() async throws {
        let file = try image(), gate = ProviderGate()
        let service = MetadataGeocodingService(identity: .init(provider: "fixture", version: "1", dataset: "test")) { _ in
            await gate.run()
            return .noResult
        }
        let settings = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, localeIdentifier: "en_US")
        let task = Task { try await self.prepare(file, settings: settings, service: service) }
        await gate.waitForEntry()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must throw") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        await gate.release()
    }

    func testDisabledGeocodingExactlyMatchesExistingLiteralPathWithoutReadingFile() async throws {
        let input = try assignment(source: "{gps:city}", active: false), calls = Calls()
        let result = try await prepare(URL(fileURLWithPath: "/nonexistent/fixture.jpg"), assignment: input,
            settings: nil, service: service(calls))
        XCTAssertEqual(result, try MetadataProcessingCoordinator.prepareLiteral(input))
        let queries = await calls.all()
        XCTAssertTrue(queries.isEmpty)
    }

    func testCorruptRAWPreservedPlacesAndVariablesOnlyRejectBeforeLookupOrWrite() async throws {
        let file = try image(), calls = Calls()
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = XMPData()
        xmp.city = "Existing city"; xmp.country = "Existing country"; xmp.headline = "Keep"
        try XMPSidecar.write(xmp, to: sidecar)
        var damaged = try Data(contentsOf: sidecar)
        damaged.append(Data("<broken".utf8))
        try damaged.write(to: sidecar)
        let original = try Data(contentsOf: file)
        let modes = [
            try MetadataGeocodingSettings(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en_US"),
            try MetadataGeocodingSettings(resolveVariables: true, localeIdentifier: "en_US")
        ]
        for settings in modes {
            do {
                _ = try await prepare(file, assignment: assignment(source: "{gps:city}"), settings: settings,
                    service: service(calls), relativePath: "fixture.cr3")
                XCTFail("Malformed sidecar must be refused even when requested fields are preserved")
            } catch is CancellationError { throw CancellationError() }
            catch { }
        }
        let queries = await calls.all()
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sidecar), damaged)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRAWEmptySidecarUsesEXIFForLookupWithoutCreatingGPSProposal() async throws {
        // Synthetic JPEG with RAW dispatch verifies carrier policy, not a camera RAW decoder.
        let file = try image(), calls = Calls()
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        try XMPSidecar.write(XMPData(), to: sidecar)
        let bytes = try Data(contentsOf: sidecar)
        let result = try await prepare(file, settings: try .init(cityPolicy: .fillEmpty, localeIdentifier: "en_US"),
            service: service(calls), relativePath: "fixture.cr3")
        XCTAssertEqual(result.coordinateResolution?.selected?.source, .embeddedEXIF)
        XCTAssertNil(result.changes.gpsPosition)
        let queries = await calls.all()
        XCTAssertEqual(queries.first?.latitude, 59.5)
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
    }
}
