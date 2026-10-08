import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataCoordinateReaderTests: XCTestCase {
    private let exifPosition = ScheduledGPSPosition(latitude: 59.5, longitude: 10.25)
    private let replacement = ScheduledGPSPosition(latitude: 48.5, longitude: 2.25)

    // Synthetic JPEG bytes with RAW relative-path dispatch exercise carrier policy,
    // not decoding coverage for proprietary camera RAW formats.
    private func image(gps: Bool = true, xmp: XMPData? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinate-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        var metadata = try ImageMetadata.read(from: file)
        if gps { metadata.setGPS(latitude: exifPosition.latitude, longitude: exifPosition.longitude) }
        metadata.xmp = xmp
        try metadata.write(to: file)
        return file
    }

    private func sidecar(_ file: URL) -> URL { file.deletingPathExtension().appendingPathExtension("xmp") }
    private func otherXMP() -> XMPData {
        var xmp = XMPData()
        xmp.exifGPSLatitude = "33,30S"
        xmp.exifGPSLongitude = "151,15E"
        return xmp
    }
    private func changeGPS(_ file: URL, _ transform: ([IFDEntry]) -> [IFDEntry]) throws {
        var metadata = try ImageMetadata.read(from: file)
        var exif = try XCTUnwrap(metadata.exif)
        exif.gpsIFD = IFD(entries: transform(try XCTUnwrap(exif.gpsIFD).entries))
        metadata.exif = exif
        try metadata.write(to: file)
    }

    func testEmbeddedAndRAWChooseWholePairsWithConflictAndDoNotCreateSidecar() throws {
        let file = try image(xmp: otherXMP())
        let original = try Data(contentsOf: file)
        let embedded = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg")
        XCTAssertEqual(embedded.selected?.source, .embeddedEXIF)
        XCTAssertEqual(embedded.selected?.pair.latitude, 59.5)
        XCTAssertEqual(embedded.selected?.pair.longitude, 10.25)
        XCTAssertNotNil(embedded.existingConflict)
        let raw = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3")
        XCTAssertEqual(raw.selected?.source, .xmp)
        XCTAssertEqual(raw.selected?.pair.latitude, -33.5)
        XCTAssertEqual(raw.selected?.pair.longitude, 151.25)
        XCTAssertNotNil(raw.existingConflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar(file).path))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testExistingSidecarWinsAndEmptySidecarFallsBackToEXIFNotEmbeddedXMP() throws {
        let file = try image(xmp: otherXMP())
        let original = try Data(contentsOf: file)
        var xmp = otherXMP(); xmp.exifGPSLatitude = "20,0N"
        try XMPSidecar.write(xmp, to: sidecar(file))
        let bytes = try Data(contentsOf: sidecar(file))
        let selected = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.nef")
        XCTAssertEqual(selected.selected?.source, .xmp)
        XCTAssertEqual(selected.selected?.pair.latitude, 20)
        XCTAssertNotNil(selected.existingConflict)
        XCTAssertEqual(try Data(contentsOf: sidecar(file)), bytes)
        try XMPSidecar.write(XMPData(), to: sidecar(file))
        let fallback = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.nef")
        XCTAssertEqual(fallback.selected?.source, .embeddedEXIF)
        XCTAssertEqual(fallback.selected?.pair.latitude, 59.5)
        XCTAssertNil(fallback.existingConflict)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testIncompleteCarriersNeverCombineComponents() throws {
        var xmp = XMPData(); xmp.exifGPSLongitude = "151,15E"
        let file = try image(xmp: xmp)
        try changeGPS(file) { $0.filter { ![ExifTag.gpsLongitude, ExifTag.gpsLongitudeRef].contains($0.tag) } }
        let result = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg")
        XCTAssertNil(result.selected)
        XCTAssertEqual(result.invalidSources, [.embeddedEXIF, .xmp])
        let filled = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg", scheduled: replacement)
        XCTAssertEqual(filled.selected?.source, .scheduled)
        XCTAssertEqual(filled.scheduledDisposition, .filledEmpty)
        XCTAssertEqual(filled.invalidSources, [.embeddedEXIF, .xmp])
    }

    func testMalformedEXIFCountDenominatorAndReferenceAreInvalidInsteadOfZero() throws {
        for variant in 0..<3 {
            let file = try image()
            try changeGPS(file) { entries in entries.map { entry in
                if variant == 2, entry.tag == ExifTag.gpsLatitudeRef {
                    return IFDEntry(tag: entry.tag, type: .ascii, count: 2, valueData: Data([81, 0]))
                }
                guard variant != 2, entry.tag == ExifTag.gpsLatitude else { return entry }
                if variant == 0 {
                    return IFDEntry(tag: entry.tag, type: .rational, count: 1, valueData: Data(entry.valueData.prefix(8)))
                }
                var bytes = entry.valueData
                bytes.replaceSubrange(4..<8, with: [0, 0, 0, 0])
                return IFDEntry(tag: entry.tag, type: entry.type, count: entry.count, valueData: bytes)
            } }
            let bytes = try Data(contentsOf: file)
            let result = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg", scheduled: replacement)
            XCTAssertEqual(result.invalidSources, [.embeddedEXIF], "Variant \(variant)")
            XCTAssertEqual(result.scheduledDisposition, .filledEmpty)
            for path in ["fixture.jpg", "fixture.cr3"] {
                let preview = try MetadataWriter.existingFields(at: file, relativePath: path)
                XCTAssertFalse(preview.carriers.contains { $0.fields[.gpsPosition] != nil })
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar(file).path))
        }
    }

    func testPinnedWriterRoundingToSixtySecondsIsNormalizedButOverflowRejected() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        metadata.setGPS(latitude: 59.9, longitude: 10.75)
        try metadata.write(to: file)
        let triplet = GPXGeotagger.degreesToRationalTriplet(59.9)
        XCTAssertEqual(triplet[1].numerator, 53)
        XCTAssertEqual(triplet[2].numerator, 600000)
        XCTAssertEqual(triplet[2].denominator, 10000)
        let result = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg")
        XCTAssertEqual(try XCTUnwrap(result.selected).pair.latitude, 59.9, accuracy: 0.0000001)
        XCTAssertTrue(result.invalidSources.isEmpty)
        try changeGPS(file) { entries in entries.map { entry in
            guard entry.tag == ExifTag.gpsLatitude else { return entry }
            var writer = BinaryWriter(capacity: 24)
            for value in [UInt32(59), 1, 53, 1, 61, 1] {
                writer.writeUInt32(value, endian: metadata.exif!.byteOrder)
            }
            return IFDEntry(tag: entry.tag, type: .rational, count: 3, valueData: writer.data)
        } }
        let invalid = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg")
        XCTAssertNil(invalid.selected)
        XCTAssertEqual(invalid.invalidSources, [.embeddedEXIF])
    }

    func testInvalidXMPAndAltitudeRetainEvidenceAndFallBack() throws {
        for variant in 0..<3 {
            let file = try image()
            var xmp = otherXMP()
            if variant == 0 { xmp.exifGPSLatitude = "Not a coordinate" }
            if variant == 1 { xmp.exifGPSAltitude = "1/0" }
            if variant == 2 { xmp.setValue(.simple("2"), namespace: XMPNamespace.exif, property: "GPSAltitudeRef") }
            try XMPSidecar.write(xmp, to: sidecar(file))
            let result = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.dng")
            XCTAssertEqual(result.selected?.source, .embeddedEXIF)
            XCTAssertEqual(result.invalidSources, [.xmp])
            XCTAssertNil(result.existingConflict)
        }
    }

    func testScheduledPolicyIsGPSOnlyAndInvalidScheduledDoesNotReplace() throws {
        let file = try image()
        let preserved = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg", scheduled: replacement,
            policy: .init(overwriteFields: [.headline]))
        XCTAssertEqual(preserved.scheduledDisposition, .preservedExisting)
        let overwritten = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg", scheduled: replacement,
            policy: .init(overwriteFields: [.gpsPosition]))
        XCTAssertEqual(overwritten.scheduledDisposition, .overwroteExisting)
        XCTAssertEqual(overwritten.selected?.pair.latitude, replacement.latitude)
        let invalid = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.jpg",
            scheduled: .init(latitude: .nan, longitude: 1), policy: .overwrite)
        XCTAssertEqual(invalid.scheduledDisposition, .invalid)
        XCTAssertEqual(invalid.selected?.source, .embeddedEXIF)
        XCTAssertEqual(invalid.invalidSources, [.scheduled])
    }

    func testCorruptAndLinkedExistingSidecarsThrowWithoutChangingBytes() throws {
        let file = try image()
        let bytes = try Data(contentsOf: file)
        let damaged = Data("not XML".utf8)
        try damaged.write(to: sidecar(file))
        XCTAssertThrowsError(try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3"))
        XCTAssertEqual(try Data(contentsOf: sidecar(file)), damaged)
        try FileManager.default.removeItem(at: sidecar(file))
        try FileManager.default.createSymbolicLink(at: sidecar(file), withDestinationURL: file.deletingLastPathComponent().appendingPathComponent("absent.xmp"))
        XCTAssertThrowsError(try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testStrictSidecarValidationRejectsMalformedXMLAndDTDWithoutFallback() throws {
        let file = try image()
        let original = try Data(contentsOf: file)
        let prefix = "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
        let invalid = [
            "not XML", prefix, prefix + "</wrong>",
            prefix + "<rdf:Description value=unquoted/></rdf:RDF>",
            prefix + "<rdf:Description a=\"1\" a=\"2\"/></rdf:RDF>",
            prefix + "<rdf:Description>&unknown;</rdf:Description></rdf:RDF>",
            "<!DOCTYPE rdf:RDF [<!ENTITY e \"test\">]>" + prefix + "</rdf:RDF>",
            "<!DOCTYPE rdf:RDF SYSTEM \"file:///does-not-exist\">" + prefix + "</rdf:RDF>",
            "<unrelated/>", "<unrelated>" + prefix + "</rdf:RDF></unrelated>",
            prefix + prefix + "</rdf:RDF></rdf:RDF>"
        ]
        for xml in invalid {
            let bytes = Data(xml.utf8)
            try bytes.write(to: sidecar(file))
            XCTAssertThrowsError(try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3"))
            XCTAssertEqual(try Data(contentsOf: sidecar(file)), bytes)
        }
        let deep = prefix + String(repeating: "<a>", count: 65)
            + String(repeating: "</a>", count: 65) + "</rdf:RDF>"
        XCTAssertThrowsError(try MetadataXMPValidation.validate(Data(deep.utf8)))
        XCTAssertThrowsError(try MetadataXMPValidation.validate(Data(repeating: 32,
            count: MetadataXMPValidation.maximumBytes + 1)))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testStrictSidecarValidationAcceptsCanonicalWrappersAndPredefinedEntities() throws {
        let file = try image()
        let rdf = "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description xmlns:exif=\"http://ns.adobe.com/exif/1.0/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
            + "<exif:GPSLatitude>0,0N</exif:GPSLatitude><exif:GPSLongitude>0,0E</exif:GPSLongitude>"
            + "<dc:description>A &amp; B &lt; C &#x41;</dc:description></rdf:Description></rdf:RDF>"
        for xml in [rdf, "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">" + rdf + "</x:xmpmeta>",
                    "<x:xapmeta xmlns:x=\"adobe:ns:meta/\">" + rdf + "</x:xapmeta>"] {
            let bytes = Data(xml.utf8)
            try bytes.write(to: sidecar(file))
            let result = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3")
            XCTAssertEqual(result.selected?.source, .xmp)
            XCTAssertEqual(result.selected?.pair.latitude, 0)
            XCTAssertEqual(result.selected?.pair.longitude, 0)
            XCTAssertTrue(result.invalidSources.isEmpty)
            XCTAssertEqual(try Data(contentsOf: sidecar(file)), bytes)
        }
    }

    func testUnreadableRAWMustHaveAuthoritativeValidSidecar() throws {
        let file = try image()
        let opaque = Data("unreadable camera RAW fixture".utf8)
        try opaque.write(to: file)
        XCTAssertThrowsError(try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3", scheduled: replacement))
        try XMPSidecar.write(XMPData(), to: sidecar(file))
        XCTAssertThrowsError(try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3", scheduled: replacement))
        try XMPSidecar.write(otherXMP(), to: sidecar(file))
        let result = try MetadataCoordinateReader.read(at: file, relativePath: "fixture.cr3", scheduled: replacement)
        XCTAssertEqual(result.selected?.source, .xmp)
        XCTAssertEqual(result.scheduledDisposition, .preservedExisting)
        XCTAssertEqual(try Data(contentsOf: file), opaque)
    }

    func testRAWPreviewIncludesOnlyGPSFromEmbeddedEXIFBesideExistingSidecar() throws {
        let file = try image()
        var xmp = XMPData(); xmp.headline = "Sidecar headline"
        try XMPSidecar.write(xmp, to: sidecar(file))
        let rawBytes = try Data(contentsOf: file), sidecarBytes = try Data(contentsOf: sidecar(file))
        let preview = try MetadataWriter.existingFields(at: file, relativePath: "fixture.nef")
        let exif = try XCTUnwrap(preview.carriers.first { $0.name == "Embedded EXIF" })
        XCTAssertEqual(exif.fields, [.gpsPosition: .position(exifPosition)])
        XCTAssertEqual(preview.carriers.first?.fields[.headline], .text("Sidecar headline"))
        XCTAssertNil(preview.carriers.first?.fields[.gpsPosition])
        XCTAssertEqual(try Data(contentsOf: file), rawBytes)
        XCTAssertEqual(try Data(contentsOf: sidecar(file)), sidecarBytes)
    }
}
