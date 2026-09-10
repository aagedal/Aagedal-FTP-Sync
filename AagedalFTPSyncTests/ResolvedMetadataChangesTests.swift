import AppKit
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class ResolvedMetadataChangesTests: XCTestCase {
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
