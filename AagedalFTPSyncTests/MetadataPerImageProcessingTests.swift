import AppKit
import Foundation
import MetadataTemplates
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataPerImageProcessingTests: XCTestCase {
    private func image() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("per-image-\(UUID())")
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

    private func assignment(headline: String = "{photographer}", keywords: [String] = [],
                            overwrite: Set<MetadataWritableField> = []) throws -> MetadataAssignment {
        let profile = PhotographerProfile(name: "Display Name", filenamePrefix: "CN", creator: "Canonical Name", copyrightNotice: "")
        var fields = ScheduledMetadataFields()
        fields.setHeadline(try .activated(headline))
        if !keywords.isEmpty { fields.setKeywords(try .activated(keywords)) }
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Fixture", startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 600), fields: fields)
        return MetadataAssignment(photographer: profile, clip: clip, existingFieldPolicy: .init(overwriteFields: overwrite))
    }

    private func prepare(_ assignment: MetadataAssignment, file: URL, path: String = "fixture.jpg", zone: String = "Etc/UTC") throws -> MetadataProcessingResult {
        try MetadataProcessingCoordinator.preparePerImage(assignment: assignment, fileURL: file, relativePath: path,
            processingDate: Date(timeIntervalSince1970: 1_704_153_600), processingTimeZone: TimeZone(identifier: zone)!)
    }

    private func setCapture(_ original: String, offset: String? = nil, file: URL) throws {
        var metadata = try ImageMetadata.read(from: file)
        var exif = ExifData()
        let values: [(UInt16, String?)] = [(ExifTag.dateTimeOriginal, original), (ExifTag.offsetTimeOriginal, offset)]
        exif.exifIFD = IFD(entries: values.compactMap { tag, value in
            guard let value else { return nil }
            let data = Data((value + "\0").utf8)
            return IFDEntry(tag: tag, type: .ascii, count: UInt32(data.count), valueData: data)
        })
        metadata.exif = exif
        try metadata.write(to: file)
    }

    func testLegacyFastPathDoesNotReadFileOrActivateBraces() throws {
        let active = try assignment()
        var clip = active.clip
        clip.fields = ScheduledMetadataFields(headline: "{dateCaptured:YYYY-MM-DD}", keywords: ["  literal  "])
        let literal = MetadataAssignment(photographer: active.photographer, clip: clip, existingFieldPolicy: active.existingFieldPolicy)
        let result = try prepare(literal, file: URL(fileURLWithPath: "/nonexistent/metadata-fixture.jpg"))
        XCTAssertEqual(result, try MetadataProcessingCoordinator.prepareLiteral(literal))
        XCTAssertNil(result.context)
        XCTAssertEqual(result.changes.headline, "{dateCaptured:YYYY-MM-DD}")
    }

    func testActiveDatesUseFrozenProcessingDateAndExplicitOriginalOffsetWithoutWrites() throws {
        let file = try image()
        try setCapture("2024:01:01 23:30:00", offset: "-02:00", file: file)
        let original = try Data(contentsOf: file)
        let input = try assignment(headline: "{date:YYYY-MM-DD} / {dateCaptured:YYYY-MM-DD} / {photographer}")
        let result = try prepare(input, file: file)
        XCTAssertEqual(result.changes.headline, "2024-01-02 / 2024-01-01 / Canonical Name")
        XCTAssertEqual(result.context?.captureDate?.zoneSource, .explicitOffset(secondsFromGMT: -7200))
        XCTAssertEqual(result.context?.photographer, "Canonical Name")
        XCTAssertTrue(result.resolutionComplete)
        XCTAssertEqual(input.clip.fields.headline, "{date:YYYY-MM-DD} / {dateCaptured:YYYY-MM-DD} / {photographer}")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testOffsetFreeCaptureUsesSuppliedPersistedZoneAndMissingCaptureDoesNotUseToday() throws {
        let file = try image()
        let input = try assignment(headline: "{dateCaptured:YYYY-MM-DD}")
        let missing = try prepare(input, file: file)
        XCTAssertEqual(missing.fields[.headline], .omitted(.template(.missingValues([.captureDate]))))
        XCTAssertFalse(missing.resolutionComplete)
        XCTAssertEqual(missing.changes.headline, "")
        try setCapture("2024:02:29 23:00:00", file: file)
        let result = try prepare(input, file: file, zone: "Europe/Oslo")
        XCTAssertEqual(result.changes.headline, "2024-02-29")
        XCTAssertEqual(result.context?.captureDate?.zoneSource, .persistedFallback(identifier: "Europe/Oslo"))
    }

    func testExistingEmbeddedFieldsSuppressDependenciesAndPreserveWholeKeywords() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValue("Existing title", for: .headline)
        var xmp = XMPData(); xmp.subject = ["existing", "ordered"]
        metadata.xmp = xmp
        try metadata.write(to: file)
        let before = try Data(contentsOf: file)
        let input = try assignment(headline: "{dateCaptured:YYYY-MM-DD}", keywords: ["{gps:city}", "{persons}"])
        let result = try prepare(input, file: file)
        XCTAssertEqual(result.fields[.headline], .preservedByPolicy)
        XCTAssertEqual(result.fields[.keywords], .preservedByPolicy)
        XCTAssertNil(result.context?.captureDate)
        XCTAssertTrue(result.resolutionComplete)
        XCTAssertTrue(result.changes.keywords.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let overwritten = try prepare(assignment(headline: "{dateCaptured:YYYY-MM-DD}", keywords: ["{gps:city}"],
            overwrite: [.headline, .keywords]), file: file)
        XCTAssertFalse(overwritten.resolutionComplete)
        XCTAssertEqual(overwritten.fields[.keywords], .omitted(.template(.missingValues([.city]))))
    }

    func testRawSidecarControlsFieldPolicyButCannotHideValidEmbeddedCapture() throws {
        let file = try image()
        try setCapture("2024:03:01 12:00:00", offset: "+00:00", file: file)
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValue("Embedded title", for: .headline)
        try metadata.write(to: file)
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = XMPData(); xmp.exifDateTimeOriginal = "2020-01-01T00:00:00Z"
        xmp.subject = ["sidecar keywords"]
        try XMPSidecar.write(xmp, to: sidecar)
        let before = try Data(contentsOf: sidecar)
        // Synthetic JPEG bytes exercise the RAW extension dispatch, not a real camera RAW decoder.
        let result = try prepare(assignment(headline: "{dateCaptured:YYYY-MM-DD}", keywords: ["{gps:city}"]), file: file, path: "fixture.dng")
        XCTAssertEqual(result.changes.headline, "2024-03-01")
        XCTAssertEqual(result.fields[.headline], .proposed, "Existing sidecar is authoritative for fill policy")
        XCTAssertEqual(result.fields[.keywords], .preservedByPolicy)
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
    }

    func testRawWithoutSidecarSeedsEmbeddedFieldPolicyWithoutCreatingSidecar() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValue("Embedded title", for: .headline)
        try metadata.write(to: file)
        let result = try prepare(assignment(headline: "{gps:city}"), file: file, path: "fixture.dng")
        XCTAssertEqual(result.fields[.headline], .preservedByPolicy)
        XCTAssertTrue(result.resolutionComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("xmp").path))
    }

    func testRawCaptureFallbackOnlyForUnavailableNeverInvalidEmbeddedOriginal() throws {
        let file = try image()
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = XMPData(); xmp.exifDateTimeOriginal = "2020-02-29T10:00:00+02:00"
        try XMPSidecar.write(xmp, to: sidecar)
        let input = try assignment(headline: "{dateCaptured:YYYY-MM-DD}")
        XCTAssertEqual(try prepare(input, file: file, path: "fixture.dng").changes.headline, "2020-02-29")
        try setCapture("2024:02:30 10:00:00", file: file)
        let invalid = try prepare(input, file: file, path: "fixture.dng")
        XCTAssertEqual(invalid.fields[.headline], .omitted(.template(.missingValues([.captureDate]))))
        XCTAssertNil(invalid.context?.captureDate)
    }
}
