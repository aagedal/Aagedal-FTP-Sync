import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataPlaceWriterTests: XCTestCase {
    private func image() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        return file
    }
    private func pixels(_ file: URL) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    func testIndependentPoliciesPreserveCityOverwriteCountryAndPixels() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValue("Keep city", for: .city)
        try metadata.iptc.setValue("Old country", for: .countryPrimaryLocationName)
        try metadata.iptc.setValue("ZZZ", for: .countryPrimaryLocationCode)
        try metadata.iptc.setValue("Keep headline", for: .headline)
        var xmp = XMPData(); xmp.city = "Different existing city"; xmp.country = "Old country"
        metadata.xmp = xmp
        try metadata.write(to: file)
        let beforePixels = try pixels(file)
        let changes = ResolvedMetadataChanges(places: .init(city: "New city", country: "Norge",
            cityPolicy: .fillEmpty, countryPolicy: .overwrite))
        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.jpg"), .willApply)
        _ = try MetadataWriter.apply(changes, to: file)
        let after = try ImageMetadata.read(from: file)
        XCTAssertEqual(after.iptc.city, "Keep city")
        XCTAssertEqual(after.xmp?.city, "Different existing city")
        XCTAssertEqual(after.iptc.countryName, "Norge")
        XCTAssertEqual(after.xmp?.country, "Norge")
        XCTAssertEqual(after.iptc.countryCode, "ZZZ")
        XCTAssertEqual(after.iptc.headline, "Keep headline")
        XCTAssertEqual(try pixels(file), beforePixels)
    }

    func testEmptyFieldsFillBothCarriersAndDisabledCountryDoesNotWrite() throws {
        let file = try image()
        let changes = ResolvedMetadataChanges(places: .init(city: "Ålesund", country: "Ignored", cityPolicy: .fillEmpty))
        _ = try MetadataWriter.apply(changes, to: file)
        let after = try ImageMetadata.read(from: file)
        XCTAssertEqual(after.iptc.city, "Ålesund")
        XCTAssertEqual(after.xmp?.city, "Ålesund")
        XCTAssertNil(after.iptc.countryName)
        XCTAssertNil(after.xmp?.country)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.jpg"), .alreadyApplied)
    }

    func testRAWExistingSidecarIsAuthoritativeAndRAWBytesNeverChange() throws {
        let file = try image()
        var embedded = try ImageMetadata.read(from: file)
        try embedded.iptc.setValue("Embedded", for: .city)
        try embedded.write(to: file)
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = XMPData(); xmp.city = "Sidecar city"; xmp.headline = "Retain"
        try XMPSidecar.write(xmp, to: sidecar)
        let rawBytes = try Data(contentsOf: file)
        let settings = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en_US")
        XCTAssertEqual(try MetadataWriter.writablePlaceFields(at: file, relativePath: "fixture.nef", settings: settings), [.country])
        let changes = ResolvedMetadataChanges(places: .init(city: "Ignored", country: "Norway", cityPolicy: .fillEmpty, countryPolicy: .fillEmpty))
        _ = try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef")
        let after = try XMPSidecar.read(from: sidecar)
        XCTAssertEqual(after.city, "Sidecar city")
        XCTAssertEqual(after.country, "Norway")
        XCTAssertEqual(after.headline, "Retain")
        XCTAssertEqual(try Data(contentsOf: file), rawBytes)
        let snapshot = try MetadataWriter.existingPlaceFields(at: file, relativePath: "fixture.nef")
        XCTAssertEqual(snapshot.carriers.first?.city, "Sidecar city")
    }

    func testMissingRAWSidecarUsesSeededPlaceValuesAndEmptyResultsNeverErase() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValue("Embedded city", for: .city)
        try metadata.write(to: file)
        let before = try Data(contentsOf: file)
        let changes = ResolvedMetadataChanges(places: .init(city: "", country: "Norway", cityPolicy: .overwrite, countryPolicy: .fillEmpty))
        _ = try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef")
        let xmp = try XMPSidecar.read(from: file.deletingPathExtension().appendingPathExtension("xmp"))
        XCTAssertEqual(xmp.city, "Embedded city")
        XCTAssertEqual(xmp.country, "Norway")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testInvalidPlaceValuesFailBeforeAnyFileOrSidecarMutation() throws {
        let file = try image()
        let before = try Data(contentsOf: file)
        for city in [String(repeating: "é", count: 17), "bad\u{1}city"] {
            let changes = ResolvedMetadataChanges(places: .init(city: city, cityPolicy: .overwrite))
            XCTAssertThrowsError(try MetadataWriter.apply(changes, to: file))
            XCTAssertThrowsError(try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef"))
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("xmp").path))
        }
        XCTAssertEqual(MetadataWriter.maximumPlaceUTF8Bytes(for: .city), 32)
        XCTAssertEqual(MetadataWriter.maximumPlaceUTF8Bytes(for: .country), 64)
    }

    func testUnreadableExistingRAWSidecarCannotBeReplacedByPlaceWrites() throws {
        let file = try image()
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        let damaged = Data("<broken".utf8)
        try damaged.write(to: sidecar)
        let before = try Data(contentsOf: file)
        let changes = ResolvedMetadataChanges(places: .init(city: "Oslo", cityPolicy: .overwrite))
        XCTAssertThrowsError(try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef"))
        XCTAssertEqual(try Data(contentsOf: sidecar), damaged)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
