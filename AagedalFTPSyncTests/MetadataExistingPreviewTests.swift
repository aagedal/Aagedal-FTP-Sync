import AppKit
import Foundation
import SwiftMediaMetadata
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class MetadataExistingPreviewTests: XCTestCase {
    private func image() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("T_fixture.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        return file
    }

    func testEmbeddedIPTCAndXMPValuesStaySeparateAndUnmodified() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValue("IPTC headline", for: .headline)
        var xmp = XMPData()
        xmp.headline = "XMP headline"
        // The metadata library normalizes surrounding XML text whitespace on read.
        xmp.subject = ["one,two", "ordered"]
        metadata.xmp = xmp
        try metadata.write(to: file)
        let before = try Data(contentsOf: file)
        let snapshot = try MetadataWriter.existingFields(at: file, relativePath: file.lastPathComponent)
        XCTAssertTrue(snapshot.readable)
        XCTAssertEqual(snapshot.carriers.first { $0.name == "Embedded IPTC" }?.fields[.headline], .text("IPTC headline"))
        XCTAssertEqual(snapshot.carriers.first { $0.name == "Embedded XMP" }?.fields[.headline], .text("XMP headline"))
        XCTAssertEqual(snapshot.carriers.first { $0.name == "Embedded XMP" }?.fields[.keywords], .list(["one,two", "ordered"]))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testExistingRAWXMPWinsOverEmbeddedValuesWithoutWritingEitherFile() throws {
        let file = try image()
        _ = try MetadataWriter.apply(ResolvedMetadataChanges(headline: "Embedded", existingFieldPolicy: .overwrite), to: file)
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = XMPData(); xmp.headline = "Sidecar"; xmp.subject = ["raw,one", "raw-two"]
        try XMPSidecar.write(xmp, to: sidecar)
        let before = try [file, sidecar].map { try Data(contentsOf: $0) }
        let snapshot = try MetadataWriter.existingFields(at: file, relativePath: "T_fixture.nef")
        XCTAssertEqual(snapshot.carriers.count, 1)
        XCTAssertEqual(snapshot.carriers[0].name, "Existing XMP sidecar")
        XCTAssertEqual(snapshot.carriers[0].fields[.headline], .text("Sidecar"))
        XCTAssertEqual(snapshot.carriers[0].fields[.keywords], .list(["raw,one", "raw-two"]))
        XCTAssertFalse(try MetadataWriter.writableFields(at: file, relativePath: "T_fixture.nef", policy: .init(overwriteFields: [])).contains(.headline))
        XCTAssertEqual(try [file, sidecar].map { try Data(contentsOf: $0) }, before)
    }

    func testMissingRAWXMPShowsSeededEmbeddedValuesButCreatesNothing() throws {
        let file = try image()
        _ = try MetadataWriter.apply(ResolvedMetadataChanges(headline: "Seed title", existingFieldPolicy: .overwrite), to: file)
        let before = try Data(contentsOf: file)
        let snapshot = try MetadataWriter.existingFields(at: file, relativePath: "T_fixture.nef")
        XCTAssertTrue(snapshot.readable)
        XCTAssertEqual(snapshot.carriers[0].fields[.headline], .text("Seed title"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("xmp").path))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testRealPreviewCarriesExistingAlongsidePreservedOutcome() throws {
        let file = try image()
        _ = try MetadataWriter.apply(ResolvedMetadataChanges(headline: "Retain headline", creator: "Retain creator", existingFieldPolicy: .overwrite), to: file)
        let before = try Data(contentsOf: file)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = PhotographerProfile(name: "Author", filenamePrefix: "T", creator: "Author", copyrightNotice: "")
        var fields = ScheduledMetadataFields()
        fields.setHeadline(try .activated("{photographer}"))
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Preview", startsAt: date.addingTimeInterval(-60),
                                       endsAt: date.addingTimeInterval(60), fields: fields)
        let automation = MetadataAutomation(isEnabled: false, timestampPolicy: .localArrival,
            existingFieldPolicy: .init(overwriteFields: []), photographers: [profile], clips: [clip])
        let preview = try MetadataPreviewService.previewLocalFolder(at: file.deletingLastPathComponent(), automation: automation,
            arrivalDate: date, processingTimeZone: TimeZone(secondsFromGMT: 0)!)
        let item = try XCTUnwrap(preview.items.first)
        XCTAssertFalse(item.existingFieldsUnavailable)
        XCTAssertEqual(item.existingFields?.carriers.first?.fields[.headline], .text("Retain headline"))
        XCTAssertEqual(item.processing?.fields[.headline], .preservedByPolicy)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testUnreadableMetadataIsNotReportedAsKnownEmpty() throws {
        let file = try image()
        try Data("unreadable".utf8).write(to: file)
        XCTAssertThrowsError(try MetadataWriter.existingFields(at: file, relativePath: "T_fixture.jpg"))
        XCTAssertFalse(try MetadataWriter.existingFields(at: file, relativePath: "T_fixture.nef").readable)
    }
}
