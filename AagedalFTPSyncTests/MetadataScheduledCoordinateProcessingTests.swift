import AppKit
import Foundation
import MetadataTemplates
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataScheduledCoordinateProcessingTests: XCTestCase {
    private let existing = ScheduledGPSPosition(latitude: 59.9, longitude: 10.75)
    private let scheduled = ScheduledGPSPosition(latitude: 48.85, longitude: 2.35)

    private func image(withExistingGPS: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduled-coordinates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        if withExistingGPS {
            var metadata = try ImageMetadata.read(from: file)
            metadata.setGPS(latitude: existing.latitude, longitude: existing.longitude)
            try metadata.write(to: file)
        }
        return file
    }

    private func input(active: Bool = true, policy: MetadataExistingFieldPolicy = .fillEmpty,
                       gps: ScheduledGPSPosition? = nil) throws -> MetadataAssignment {
        let photographer = PhotographerProfile(name: "Fixture", filenamePrefix: "CN", creator: "Fixture", copyrightNotice: "")
        var fields = ScheduledMetadataFields(headline: "Literal headline")
        if active { fields.setHeadline(try .activated("{photographer}")) }
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Fixture",
            startsAt: Date(timeIntervalSince1970: 0), endsAt: Date(timeIntervalSince1970: 600),
            fields: fields, gpsPosition: gps ?? scheduled)
        return MetadataAssignment(photographer: photographer, clip: clip, existingFieldPolicy: policy)
    }

    private func prepare(_ input: MetadataAssignment, file: URL, raw: Bool = true) throws -> MetadataProcessingResult {
        // JPEG bytes with RAW dispatch test the publication policy, not a real camera RAW decoder.
        try MetadataProcessingCoordinator.preparePerImage(assignment: input, fileURL: file,
            relativePath: raw ? "fixture.dng" : "fixture.jpg", processingDate: Date(timeIntervalSince1970: 123_456),
            processingTimeZone: TimeZone(identifier: "Etc/UTC")!)
    }

    private func sidecar(_ file: URL) -> URL { file.deletingPathExtension().appendingPathExtension("xmp") }

    func testActivatedRawFillPreservesEXIFWhenExistingSidecarHasNoGPS() throws {
        let file = try image()
        var xmp = XMPData(); xmp.subject = ["Keep this keyword"]
        try XMPSidecar.write(xmp, to: sidecar(file))
        let original = try Data(contentsOf: file)
        let result = try prepare(input(), file: file)
        XCTAssertEqual(result.coordinateResolution?.selected?.source, .embeddedEXIF)
        XCTAssertEqual(result.coordinateResolution?.scheduledDisposition, .preservedExisting)
        XCTAssertEqual(result.fields[.gpsPosition], .preservedByPolicy)
        XCTAssertNil(result.changes.gpsPosition)
        XCTAssertTrue(result.resolutionComplete)
        _ = try MetadataWriter.apply(result.changes, to: file, relativePath: "fixture.dng")
        let written = try XMPSidecar.read(from: sidecar(file))
        XCTAssertNil(written.exifGPSLatitude)
        XCTAssertNil(written.exifGPSLongitude)
        XCTAssertEqual(written.subject, ["Keep this keyword"])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testActivatedRawOverwritePublishesScheduledPairAndKeepsRAWBytes() throws {
        let file = try image()
        try XMPSidecar.write(XMPData(), to: sidecar(file))
        let original = try Data(contentsOf: file)
        let result = try prepare(input(policy: .init(overwriteFields: [.gpsPosition])), file: file)
        XCTAssertEqual(result.coordinateResolution?.scheduledDisposition, .overwroteExisting)
        XCTAssertEqual(result.fields[.gpsPosition], .proposed)
        XCTAssertEqual(result.changes.gpsPosition, scheduled)
        _ = try MetadataWriter.apply(result.changes, to: file, relativePath: "fixture.dng")
        let written = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.dng")
        XCTAssertEqual(written.selected?.source, .xmp)
        XCTAssertEqual(try XCTUnwrap(written.selected).pair.latitude, scheduled.latitude, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(written.selected).pair.longitude, scheduled.longitude, accuracy: 0.0000001)
        XCTAssertNotNil(written.existingConflict)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testLegacyRawFillRetainsOriginalSidecarOnlyPolicy() throws {
        let file = try image()
        try XMPSidecar.write(XMPData(), to: sidecar(file))
        let original = try Data(contentsOf: file)
        let result = try prepare(input(active: false), file: file)
        XCTAssertNil(result.context)
        XCTAssertNil(result.coordinateResolution)
        XCTAssertEqual(result.changes.gpsPosition, scheduled)
        _ = try MetadataWriter.apply(result.changes, to: file, relativePath: "fixture.dng")
        let written = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.dng")
        XCTAssertEqual(try XCTUnwrap(written.selected).pair.latitude, scheduled.latitude, accuracy: 0.0000001)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testActivatedRawWithoutSidecarPreservesEXIFAndPreparationCreatesNothing() throws {
        let file = try image()
        let original = try Data(contentsOf: file)
        let result = try prepare(input(), file: file)
        XCTAssertEqual(result.coordinateResolution?.scheduledDisposition, .preservedExisting)
        XCTAssertNil(result.changes.gpsPosition)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar(file).path))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testActivatedFillWithNoPairWritesGPSWithoutOverwritingOtherFields() throws {
        let file = try image(withExistingGPS: false)
        var xmp = XMPData(); xmp.headline = "Keep headline"
        try XMPSidecar.write(xmp, to: sidecar(file))
        let result = try prepare(input(), file: file)
        XCTAssertEqual(result.coordinateResolution?.scheduledDisposition, .filledEmpty)
        XCTAssertEqual(result.fields[.headline], .preservedByPolicy)
        XCTAssertEqual(result.changes.existingFieldPolicy.overwriteFields, [.gpsPosition])
        _ = try MetadataWriter.apply(result.changes, to: file, relativePath: "fixture.dng")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar(file)).headline, "Keep headline")
        let written = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.dng")
        XCTAssertEqual(try XCTUnwrap(written.selected).pair.latitude, scheduled.latitude, accuracy: 0.0000001)
    }

    func testInvalidScheduledGPSIsOmittedAndIncompleteEvenWhenExistingPairIsPreserved() throws {
        let file = try image()
        let invalid = ScheduledGPSPosition(latitude: .nan, longitude: 10)
        let result = try prepare(input(gps: invalid), file: file, raw: false)
        XCTAssertEqual(result.coordinateResolution?.scheduledDisposition, .invalid)
        XCTAssertEqual(result.coordinateResolution?.selected?.source, .embeddedEXIF)
        XCTAssertEqual(result.fields[.gpsPosition], .omitted(.invalidGPSPosition))
        XCTAssertNil(result.changes.gpsPosition)
        XCTAssertFalse(result.resolutionComplete)
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result))
        XCTAssertEqual(evidence.fields["gpsPosition"]?.reason, .invalidGPSPosition)
        XCTAssertFalse(evidence.resolutionComplete)
    }

    func testStrictFillReplacesMalformedEXIFThatLegacyParserTreatsAsZero() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValue("Keep headline", for: .headline)
        var exif = try XCTUnwrap(metadata.exif)
        let gps = try XCTUnwrap(exif.gpsIFD)
        exif.gpsIFD = IFD(entries: gps.entries.map { entry in
            guard entry.tag == ExifTag.gpsLatitude else { return entry }
            return IFDEntry(tag: entry.tag, type: .rational, count: 1,
                            valueData: Data(entry.valueData.prefix(8)))
        })
        metadata.exif = exif
        try metadata.write(to: file)
        XCTAssertEqual(try ImageMetadata.read(from: file).exif?.gpsLatitude, 0,
                       "Pinned legacy parser fabricates zero for the malformed rational count")
        XCTAssertFalse(try MetadataWriter.writableFields(at: file, relativePath: "fixture.jpg", policy: .fillEmpty).contains(.gpsPosition))
        let result = try prepare(input(), file: file, raw: false)
        XCTAssertEqual(result.coordinateResolution?.scheduledDisposition, .filledEmpty)
        XCTAssertEqual(result.coordinateResolution?.invalidSources, [.embeddedEXIF])
        XCTAssertEqual(result.fields[.gpsPosition], .proposed)
        XCTAssertEqual(result.changes.existingFieldPolicy.overwriteFields, [.gpsPosition])
        _ = try MetadataWriter.apply(result.changes, to: file, relativePath: "fixture.jpg")
        let written = try ImageMetadata.read(from: file)
        XCTAssertEqual(try XCTUnwrap(written.exif?.gpsLatitude), scheduled.latitude, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(written.exif?.gpsLongitude), scheduled.longitude, accuracy: 0.0000001)
        XCTAssertEqual(written.iptc.headline, "Keep headline")
    }
}
