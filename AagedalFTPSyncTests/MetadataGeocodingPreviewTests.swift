import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataGeocodingPreviewTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func image(gps: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("T_fixture.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        if gps {
            var metadata = try ImageMetadata.read(from: file)
            metadata.setGPS(latitude: 59, longitude: 10)
            try metadata.write(to: file)
        }
        return file
    }
    private func service() -> MetadataGeocodingService {
        MetadataGeocodingService(identity: .init(provider: "fixture", version: "1", dataset: "fixture")) { _ in
            .found(.init(city: "Oslo", country: "Norway", source: "injected local fixture", distanceMeters: 50))
        }
    }
    private func automation(enabled: Bool, capture: Bool = false) -> MetadataAutomation {
        let profile = PhotographerProfile(name: "Author", filenamePrefix: "T", creator: "Author", copyrightNotice: "")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Other time",
            startsAt: date.addingTimeInterval(-3600), endsAt: date.addingTimeInterval(-1800),
            fields: .init(headline: "Must not apply"))
        return MetadataAutomation(isEnabled: enabled, timestampPolicy: capture ? .cameraCapture : .localArrival,
                                  photographers: [profile], clips: [clip])
    }
    private func preview(_ file: URL, automation: MetadataAutomation? = nil,
                         service: MetadataGeocodingService? = nil) async throws -> MetadataPreviewResult {
        try await MetadataPreviewService.previewLocalFolder(at: file.deletingLastPathComponent(), automation: automation,
            geocoding: MetadataGeocodingSettings(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en_US"),
            service: service ?? self.service(), arrivalDate: date, processingTimeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func testNoAutomationDisabledScheduleAndNoClipStillPreviewPlacesReadOnly() async throws {
        let file = try image()
        let before = try Data(contentsOf: file)
        for automation in [Optional<MetadataAutomation>.none, self.automation(enabled: false), self.automation(enabled: true)] {
            let result = try await preview(file, automation: automation)
            let item = try XCTUnwrap(result.items.first)
            XCTAssertEqual(item.status, .willApply)
            XCTAssertNil(item.clipID)
            XCTAssertNil(item.processing?.context?.photographer)
            XCTAssertEqual(item.processing?.changes.places?.city, "Oslo")
            XCTAssertEqual(item.processing?.changes.headline, "")
            XCTAssertNotNil(item.existingPlaces)
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).count, 1)
    }

    func testMissingCaptureOnlySuppressesScheduledFields() async throws {
        let file = try image()
        let result = try await preview(file, automation: automation(enabled: true, capture: true))
        let item = try XCTUnwrap(result.items.first)
        XCTAssertNil(item.scheduledAt)
        XCTAssertEqual(item.status, .willApply)
        XCTAssertEqual(item.processing?.changes.places?.country, "Norway")
        XCTAssertTrue(item.detail?.contains("Capture time was unavailable") == true)
    }

    func testPreservedPlacesDoNotRequestProviderOrClaimAWrite() async throws {
        let file = try image()
        _ = try MetadataWriter.apply(.init(places: .init(city: "Existing city", country: "Existing country",
            cityPolicy: .overwrite, countryPolicy: .overwrite)), to: file)
        let before = try Data(contentsOf: file)
        let provider = MetadataGeocodingService(identity: .init(provider: "forbidden", version: "1", dataset: "test")) { _ in
            XCTFail("Preserved places must not trigger lookup")
            return .failure(retryAfter: nil)
        }
        let result = try await preview(file, service: provider)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .noChanges)
        XCTAssertEqual(item.processing?.places[.city], .preservedByPolicy)
        XCTAssertEqual(item.processing?.geocoding, .notRequested)
        XCTAssertEqual(item.existingPlaces?.carriers.first?.city, "Existing city")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testImageChangedDuringLookupDiscardsMixedPreviewEvenWithSameSizeAndDate() async throws {
        let file = try image()
        let original = try Data(contentsOf: file)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let provider = MetadataGeocodingService(identity: .init(provider: "mutation", version: "1", dataset: "test")) { _ in
            do {
                // Keep the image decodable and its size/date unchanged. A byte
                // comparison must detect edits that a listing cannot reveal.
                var replacement = try ImageMetadata.read(from: file)
                replacement.setGPS(latitude: 60, longitude: 10)
                try replacement.write(to: file)
                if let modified {
                    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
                }
            } catch { XCTFail("Fixture mutation failed: \(error)") }
            return .found(.init(city: "Oslo", country: "Norway", source: "fixture", distanceMeters: 0))
        }
        let result = try await preview(file, service: provider)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .previewFailed)
        XCTAssertNil(item.processing)
        XCTAssertNil(item.existingFields)
        XCTAssertNil(item.existingPlaces)
        XCTAssertTrue(item.existingFieldsUnavailable)
        XCTAssertTrue(item.detail?.contains("changed during preview") == true)
        XCTAssertEqual(result.needsAttention, 1)
        XCTAssertEqual(result.willApply, 0)
        XCTAssertEqual(try Data(contentsOf: file).count, original.count)
    }

    func testRawSidecarChangedDuringLookupIsRejectedAndRefreshUsesNewRevision() async throws {
        let image = try image()
        let root = image.deletingLastPathComponent()
        try FileManager.default.removeItem(at: image)
        let raw = root.appendingPathComponent("fixture.CR3")
        try Data("opaque RAW fixture".utf8).write(to: raw)
        let sidecar = root.appendingPathComponent("fixture.xmp")
        let before = """
        <?xml version="1.0"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSLatitude="59,0N" exif:GPSLongitude="10,0E"/></rdf:RDF></x:xmpmeta>
        """
        try Data(before.utf8).write(to: sidecar)
        let provider = MetadataGeocodingService(identity: .init(provider: "mutation", version: "1", dataset: "test")) { _ in
            do { try Data(before.replacingOccurrences(of: "59,0N", with: "60,0N").utf8).write(to: sidecar) }
            catch { XCTFail("Fixture mutation failed: \(error)") }
            return .found(.init(city: "Oslo", country: "Norway", source: "fixture", distanceMeters: 0))
        }
        let result = try await preview(raw, service: provider)
        let item = try XCTUnwrap(result.items.first { $0.relativePath == "fixture.CR3" })
        XCTAssertEqual(item.status, .previewFailed)
        XCTAssertNil(item.processing)
        XCTAssertTrue(item.detail?.contains("changed during preview") == true)
        let refreshed = try await preview(raw)
        XCTAssertEqual(refreshed.items.first { $0.relativePath == "fixture.CR3" }?.status, .willApply)
        XCTAssertEqual(try Data(contentsOf: raw), Data("opaque RAW fixture".utf8))
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), before.replacingOccurrences(of: "59,0N", with: "60,0N"))
    }

    func testMissingGPSAndBadFileStaySeparateIncompleteAndFailedResults() async throws {
        let file = try image(gps: false)
        let bad = file.deletingLastPathComponent().appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)
        let result = try await preview(file)
        let item = try XCTUnwrap(result.items.first { $0.relativePath == file.lastPathComponent })
        XCTAssertEqual(item.status, .resolutionIncomplete)
        XCTAssertEqual(item.processing?.geocoding, .missingCoordinates)
        XCTAssertEqual(result.items.first { $0.relativePath == "bad.jpg" }?.status, .previewFailed)
        XCTAssertEqual(result.needsAttention, 2)
        XCTAssertEqual(result.willApply, 0)
    }
}
