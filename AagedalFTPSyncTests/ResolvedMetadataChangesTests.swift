import AppKit
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class ResolvedMetadataChangesTests: XCTestCase {
    func testLegacyIPTCEncodingAcceptsNewUnicodeWithoutChangingRetainedTextOrPixels() throws {
        for (encoding, city) in [(String.Encoding.isoLatin1, "Málaga"), (.windowsCP1252, "“Málaga”")] {
            let root = try fixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("legacy.jpg")
            let binary = Data([0, 4])
            let datasets = [
                try IPTCDataSet(tag: .city, stringValue: city, encoding: encoding),
                try IPTCDataSet(tag: .captionAbstract, stringValue: "Café déjà vu", encoding: encoding),
                try IPTCDataSet(tag: .keywords, stringValue: "Équipe", encoding: encoding),
                try IPTCDataSet(tag: .keywords, stringValue: "Équipe", encoding: encoding),
                IPTCDataSet(tag: .applicationRecordVersion, rawValue: binary)
            ]
            try jpegWithRawIPTC(datasets).write(to: url)
            let original = try ImageMetadata.read(from: url)
            XCTAssertEqual(original.iptc.encoding, encoding)
            let scan = try JPEGParser.parse(Data(contentsOf: url)).scanData
            let pixels = try decodedPixels(url)
            let changes = ResolvedMetadataChanges(headline: "東京のニュース", description: "Preserve old caption",
                creator: "علي", copyright: "© Example 📷", existingFieldPolicy: .fillEmpty)

            _ = try MetadataWriter.apply(changes, to: url)

            let actual = try ImageMetadata.read(from: url)
            XCTAssertEqual(actual.iptc.encoding, .utf8)
            XCTAssertEqual(actual.iptc.city, city)
            XCTAssertEqual(actual.iptc.caption, "Café déjà vu")
            XCTAssertEqual(actual.iptc.keywords, ["Équipe", "Équipe"])
            XCTAssertEqual(actual.iptc.rawValue(for: .applicationRecordVersion), binary)
            XCTAssertEqual(actual.iptc.headline, "東京のニュース")
            XCTAssertEqual(actual.xmp?.headline, "東京のニュース")
            XCTAssertEqual(actual.iptc.byline, "علي")
            XCTAssertEqual(actual.xmp?.creator, ["علي"])
            XCTAssertEqual(actual.iptc.copyright, "© Example 📷")
            XCTAssertEqual(actual.iptc.dataSets(for: .codedCharacterSet).map(\.rawValue), [Data([0x1B, 0x25, 0x47])])
            XCTAssertEqual(try JPEGParser.parse(Data(contentsOf: url)).scanData, scan)
            XCTAssertEqual(try decodedPixels(url), pixels)
        }
    }

    func testPromotingLegacyIPTCPreservesOrderBinaryAndOverlengthWarnings() throws {
        let original = IPTCData(datasets: [
            try IPTCDataSet(tag: .headline, stringValue: String(repeating: "é", count: 260), encoding: .isoLatin1),
            IPTCDataSet(tag: .objectDataPreviewData, rawValue: Data([0xFF, 0x80, 0x00, 0x81])),
            try IPTCDataSet(tag: .keywords, stringValue: "one", encoding: .isoLatin1),
            try IPTCDataSet(tag: .keywords, stringValue: "two", encoding: .isoLatin1)
        ], encoding: .isoLatin1)
        var actual = try MetadataWriter.utf8IPTCForWriting(original)
        XCTAssertEqual(actual.rawValue(for: .objectDataPreviewData), original.rawValue(for: .objectDataPreviewData))
        XCTAssertEqual(actual.headline, original.headline)
        XCTAssertEqual(actual.keywords, ["one", "two"])
        XCTAssertEqual(actual.datasets.filter { $0.tag != .codedCharacterSet }.map(\.tag), original.datasets.map(\.tag))
        XCTAssertFalse(actual.maxLengthWarnings().isEmpty)
        try actual.setValue("新しい値", for: .copyrightNotice)
        var warnings: [String] = []
        _ = try IPTCWriter.write(actual, warnings: &warnings)
        XCTAssertFalse(warnings.isEmpty)
    }

    func testPromotionRejectsUndecodableLegacyTextWithoutMutatingInput() throws {
        let original = IPTCData(datasets: [IPTCDataSet(tag: .captionAbstract, rawValue: Data([0xD8, 0x00]))], encoding: .utf16BigEndian)
        XCTAssertNil(original.caption)
        XCTAssertThrowsError(try MetadataWriter.utf8IPTCForWriting(original))
        XCTAssertEqual(original.rawValue(for: .captionAbstract), Data([0xD8, 0x00]))
        XCTAssertEqual(original.encoding, .utf16BigEndian)
    }

    func testASCIILegacyAndUTF8IPTCPromotionKeepUnicodeReady() throws {
        var ascii = try MetadataWriter.utf8IPTCForWriting(IPTCData(
            datasets: [try IPTCDataSet(tag: .city, stringValue: "Oslo", encoding: .isoLatin1)], encoding: .isoLatin1))
        XCTAssertEqual(ascii.encoding, .utf8)
        XCTAssertEqual(ascii.city, "Oslo")
        try ascii.setValue("東京", for: .headline)
        XCTAssertEqual(ascii.headline, "東京")
        XCTAssertEqual(try MetadataWriter.utf8IPTCForWriting(ascii), ascii)
    }

    func testLegacySnapshotKeepsBracesCanonicalNameAndKeywordBoundaries() {
        var photographer = PhotographerProfile(name: " Legacy Name ", filenamePrefix: "TEST", creator: "", copyrightNotice: " © {photographer} ")
        var clip = MetadataScheduleClip(photographerID: photographer.id, name: "Test", startsAt: .distantPast, endsAt: .distantFuture,
            fields: ScheduledMetadataFields(headline: " {{headline}} ", description: " {date:YYYY-MM-DD} ", keywords: [" Café ", "cafe", "One, Two", ""]))
        let changes = ResolvedMetadataChanges.literal(MetadataAssignment(photographer: photographer, clip: clip, existingFieldPolicy: .fillEmpty))
        photographer.creator = "Changed after snapshot"
        clip.fields.description = "Changed after snapshot"
        XCTAssertEqual(changes.headline, "{{headline}}")
        XCTAssertEqual(changes.description, "{date:YYYY-MM-DD}")
        XCTAssertEqual(changes.copyright, "© {photographer}")
        XCTAssertEqual(changes.creator, "Legacy Name")
        XCTAssertEqual(changes.keywords, ["Café", "One, Two"])
        XCTAssertEqual(changes.existingFieldPolicy, .fillEmpty)
    }

    func testFrozenValuesAssessAndWriteJPEGWhilePreservingFilledFieldsAndPixels() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.jpg")
        try jpeg().write(to: url)
        var initial = try ImageMetadata.read(from: url)
        var xmp = XMPData()
        xmp.description = "Existing caption"
        xmp.city = "Keep City"
        initial.xmp = xmp
        try initial.iptc.setValue("Existing caption", for: .captionAbstract)
        _ = try initial.write(to: url)
        let pixels = try decodedPixels(url)

        let changes = ResolvedMetadataChanges(headline: "Final {literal name}", description: "Replacement caption",
            keywords: ["One, Two", "Café"], creator: "Photographer", copyright: "2026 Example",
            gpsPosition: ScheduledGPSPosition(latitude: 59.9, longitude: 10.7), existingFieldPolicy: .fillEmpty)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: url, relativePath: "fixture.jpg"), .willApply)
        _ = try MetadataWriter.apply(changes, to: url, relativePath: "fixture.jpg")
        let actual = try ImageMetadata.read(from: url)
        XCTAssertEqual(actual.iptc.headline, "Final {literal name}")
        XCTAssertEqual(actual.xmp?.headline, "Final {literal name}")
        XCTAssertEqual(actual.iptc.caption, "Existing caption")
        XCTAssertEqual(actual.xmp?.description, "Existing caption")
        XCTAssertEqual(actual.xmp?.city, "Keep City")
        XCTAssertEqual(actual.iptc.keywords, ["One, Two", "Café"])
        XCTAssertEqual(actual.xmp?.subject, ["One, Two", "Café"])
        XCTAssertEqual(actual.iptc.byline, "Photographer")
        XCTAssertEqual(actual.xmp?.rights, "2026 Example")
        XCTAssertEqual(try XCTUnwrap(actual.exif?.gpsLatitude), 59.9, accuracy: 0.000001)
        XCTAssertEqual(try decodedPixels(url), pixels)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: url, relativePath: "fixture.jpg"), .existingMetadataPreserved)
    }

    func testOmittedResolvedValuesNeverEraseExistingFieldsUnderOverwritePolicy() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.jpg")
        try jpeg().write(to: url)
        let initial = ResolvedMetadataChanges(headline: "Keep headline", description: "Keep caption", keywords: ["Keep keyword"], creator: "Keep creator", copyright: "Keep copyright", existingFieldPolicy: .overwrite)
        _ = try MetadataWriter.apply(initial, to: url)
        let omissions = ResolvedMetadataChanges(existingFieldPolicy: .overwrite)
        XCTAssertEqual(try MetadataWriter.assess(omissions, at: url, relativePath: "fixture.jpg"), .alreadyApplied)
        _ = try MetadataWriter.apply(omissions, to: url)
        XCTAssertEqual(try MetadataWriter.assess(initial, at: url, relativePath: "fixture.jpg"), .alreadyApplied)
        let actual = try ImageMetadata.read(from: url)
        XCTAssertEqual(actual.iptc.headline, "Keep headline")
        XCTAssertEqual(actual.xmp?.headline, "Keep headline")
        XCTAssertEqual(actual.iptc.caption, "Keep caption")
        XCTAssertEqual(actual.xmp?.description, "Keep caption")
        XCTAssertEqual(actual.iptc.keywords, ["Keep keyword"])
        XCTAssertEqual(actual.xmp?.subject, ["Keep keyword"])
        XCTAssertEqual(actual.iptc.byline, "Keep creator")
        XCTAssertEqual(actual.xmp?.creator, ["Keep creator"])
        XCTAssertEqual(actual.iptc.copyright, "Keep copyright")
        XCTAssertEqual(actual.xmp?.rights, "Keep copyright")
    }

    func testResolvedSidecarWritesPreserveRAWAndUnrelatedXMP() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawURL = root.appendingPathComponent("fixture.nef")
        let original = Data("Opaque RAW bytes are not decoded when a sidecar exists".utf8)
        try original.write(to: rawURL)
        let sidecarURL = root.appendingPathComponent("fixture.xmp")
        var xmp = XMPData()
        xmp.description = "Keep existing caption"
        xmp.city = "Unrelated city"
        try XMPSidecar.write(xmp, to: sidecarURL)
        let changes = ResolvedMetadataChanges(headline: "Final headline", keywords: ["Person One, Person Two"], creator: "Creator", copyright: "Rights", existingFieldPolicy: .overwrite)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: rawURL, relativePath: "fixture.nef"), .willApply)
        guard case .sidecar(let writtenURL, _, _) = try MetadataWriter.apply(changes, to: rawURL, relativePath: "fixture.nef") else {
            return XCTFail("RAW metadata must use its sidecar")
        }
        XCTAssertEqual(writtenURL, sidecarURL)
        let actual = try XMPSidecar.read(from: sidecarURL)
        XCTAssertEqual(actual.headline, "Final headline")
        XCTAssertEqual(actual.description, "Keep existing caption")
        XCTAssertEqual(actual.city, "Unrelated city")
        XCTAssertEqual(actual.subject, ["Person One, Person Two"])
        XCTAssertEqual(actual.creator, ["Creator"])
        XCTAssertEqual(actual.rights, "Rights")
        XCTAssertEqual(try Data(contentsOf: rawURL), original)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: rawURL, relativePath: "fixture.nef"), .alreadyApplied)
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resolved-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func jpeg() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) { bytes[index] = UInt8(index % 251) }
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }

    /// Write raw IIM records to avoid canonicalizing the legacy fixture through
    /// IPTCWriter before the app ever sees it.
    private func jpegWithRawIPTC(_ datasets: [IPTCDataSet]) throws -> Data {
        var payload = Data()
        for dataset in datasets {
            XCTAssertLessThan(dataset.rawValue.count, 32_768)
            payload.append(contentsOf: [0x1C, dataset.tag.record, dataset.tag.dataSet,
                UInt8(dataset.rawValue.count >> 8), UInt8(dataset.rawValue.count & 0xFF)])
            payload.append(dataset.rawValue)
        }
        var file = try JPEGParser.parse(jpeg())
        let app13 = PhotoshopIRB.write(blocks: [IRBBlock(resourceID: PhotoshopIRB.iptcResourceID, data: payload)])
        file.replaceOrAddIPTCSegment(JPEGSegment(marker: .app13, data: app13))
        return try JPEGWriter.write(file)
    }

    private struct PixelSnapshot: Equatable {
        let width: Int
        let height: Int
        let rgba: Data
    }

    private func decodedPixels(_ url: URL) throws -> PixelSnapshot {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        let image = try XCTUnwrap(bitmap.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return PixelSnapshot(width: image.width, height: image.height, rgba: Data(bytes))
    }
}
