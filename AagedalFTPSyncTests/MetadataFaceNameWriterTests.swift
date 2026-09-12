import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataFaceNameWriterTests: XCTestCase {
    private func image() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("face-name-writer-" + UUID().uuidString)
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

    func testResolvedNamesNormalizeWithoutSplittingOrInterpretingLiteralText() {
        let names = ResolvedFaceNameChanges(
            names: [" Existing ", "existing", "Café", "cafe", "Doe, Jane", "{persons}", ""],
            appendToKeywords: true
        )
        XCTAssertEqual(names.names, ["Existing", "Café", "Doe, Jane", "{persons}"])
        XCTAssertTrue(names.appendToKeywords)
        XCTAssertEqual(ResolvedMetadataChanges(faceNames: names).faceNames, names)

        let localeStable = ResolvedFaceNameChanges(names: ["I", "i", "\u{0131}"])
        XCTAssertEqual(localeStable.names, ["I", "\u{0131}"])
    }

    func testEmbeddedWriteAppendsPersonShownAndSeparateKeywordsIdempotently() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        try metadata.iptc.setValues(["IPTC existing"], for: .keywords)
        var xmp = XMPData()
        xmp.personInImage = ["Existing Person", "Café"]
        xmp.subject = ["XMP existing"]
        metadata.xmp = xmp
        try metadata.write(to: file)
        let originalPixels = try pixels(file)
        let changes = ResolvedMetadataChanges(faceNames: .init(
            names: [" cafe ", "Doe, Jane", "{literal name}"], appendToKeywords: true
        ))

        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.jpg"), .willApply)
        _ = try MetadataWriter.apply(changes, to: file, relativePath: "fixture.jpg")
        let actual = try ImageMetadata.read(from: file)
        XCTAssertEqual(actual.xmp?.personInImage, ["Existing Person", "Café", "Doe, Jane", "{literal name}"])
        XCTAssertEqual(actual.iptc.keywords, ["IPTC existing", "cafe", "Doe, Jane", "{literal name}"])
        XCTAssertEqual(actual.xmp?.subject, ["XMP existing", "cafe", "Doe, Jane", "{literal name}"])
        XCTAssertEqual(try pixels(file), originalPixels)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.jpg"), .alreadyApplied)
        _ = try MetadataWriter.apply(changes, to: file, relativePath: "fixture.jpg")
        let second = try ImageMetadata.read(from: file)
        XCTAssertEqual(second.xmp?.personInImage, actual.xmp?.personInImage)
        XCTAssertEqual(second.iptc.keywords, actual.iptc.keywords)
        XCTAssertEqual(second.xmp?.subject, actual.xmp?.subject)
    }

    func testRAWSidecarAppendsNamesAndPreservesRAWAndExistingValues() throws {
        let file = try image()
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = XMPData()
        xmp.personInImage = ["Retained"]
        xmp.subject = ["Keep, intact"]
        xmp.description = "Unrelated"
        try XMPSidecar.write(xmp, to: sidecar)
        let rawBytes = try Data(contentsOf: file)
        let changes = ResolvedMetadataChanges(faceNames: .init(names: ["Retained", "New, Name"], appendToKeywords: true))

        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.nef"), .willApply)
        guard case .sidecar = try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef") else {
            return XCTFail("RAW metadata must use an XMP sidecar")
        }
        let actual = try XMPSidecar.read(from: sidecar)
        XCTAssertEqual(actual.personInImage, ["Retained", "New, Name"])
        XCTAssertEqual(actual.subject, ["Keep, intact", "Retained", "New, Name"])
        XCTAssertEqual(actual.description, "Unrelated")
        XCTAssertEqual(try Data(contentsOf: file), rawBytes)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.nef"), .alreadyApplied)
    }

    func testMissingRAWSidecarSeedsEmbeddedPersonShownWithoutChangingRAW() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        var xmp = XMPData(); xmp.personInImage = ["Embedded Person"]; xmp.description = "Keep"
        metadata.xmp = xmp
        try metadata.write(to: file)
        let rawBytes = try Data(contentsOf: file)
        let changes = ResolvedMetadataChanges(faceNames: .init(names: ["New Person"]))

        _ = try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef")
        let sidecar = try XMPSidecar.read(from: file.deletingPathExtension().appendingPathExtension("xmp"))
        XCTAssertEqual(sidecar.personInImage, ["Embedded Person", "New Person"])
        XCTAssertEqual(sidecar.description, "Keep")
        XCTAssertEqual(try Data(contentsOf: file), rawBytes)
        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.nef"), .alreadyApplied)
    }

    func testScheduledKeywordReplacementAndFaceAppendAssessAsOneIdempotentResult() throws {
        let file = try image()
        let changes = ResolvedMetadataChanges(keywords: ["Scheduled"], existingFieldPolicy: .overwrite,
            faceNames: .init(names: ["Person"], appendToKeywords: true))
        _ = try MetadataWriter.apply(changes, to: file)
        let metadata = try ImageMetadata.read(from: file)
        XCTAssertEqual(metadata.iptc.keywords, ["Scheduled", "Person"])
        XCTAssertEqual(metadata.xmp?.subject, ["Scheduled", "Person"])
        XCTAssertEqual(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.jpg"), .alreadyApplied)
    }

    func testFaceWriteRejectsUnreadableOrLinkedSidecarWithoutMutation() throws {
        for linked in [false, true] {
            let file = try image()
            let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
            let damaged = Data("<broken".utf8)
            if linked {
                let target = file.deletingLastPathComponent().appendingPathComponent("target.xmp")
                try damaged.write(to: target)
                try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
            } else {
                try damaged.write(to: sidecar)
            }
            let before = try Data(contentsOf: file)
            let changes = ResolvedMetadataChanges(faceNames: .init(names: ["Person"]))
            XCTAssertThrowsError(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.nef"))
            XCTAssertThrowsError(try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef"))
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertEqual(try Data(contentsOf: linked
                ? file.deletingLastPathComponent().appendingPathComponent("target.xmp") : sidecar), damaged)
        }
    }

    func testFaceWriteDoesNotCreateSidecarLargerThanItsAdmissionLimit() throws {
        let file = try image()
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = XMPData()
        xmp.description = ""
        let fixedBytes = XMPWriter.generateXML(xmp).utf8.count
        xmp.description = String(repeating: "x", count: MetadataXMPValidation.maximumBytes - fixedBytes - 8)
        try XMPSidecar.write(xmp, to: sidecar)
        _ = try MetadataXMPValidation.read(at: sidecar)
        let original = try Data(contentsOf: sidecar)

        let changes = ResolvedMetadataChanges(faceNames: .init(names: ["A name that cannot fit"]))
        XCTAssertThrowsError(try MetadataWriter.apply(changes, to: file, relativePath: "fixture.nef"))
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }

    func testExistingFieldPreviewCapturesPersonShownForEmbeddedAndRAW() throws {
        let file = try image()
        var metadata = try ImageMetadata.read(from: file)
        var xmp = XMPData(); xmp.personInImage = ["Embedded Person"]
        metadata.xmp = xmp
        try metadata.write(to: file)
        let embedded = try MetadataWriter.existingFields(at: file, relativePath: "fixture.jpg")
        XCTAssertEqual(embedded.carriers.first { $0.name == "Embedded XMP" }?.personInImage, ["Embedded Person"])

        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        xmp.personInImage = ["Sidecar Person"]
        try XMPSidecar.write(xmp, to: sidecar)
        let raw = try MetadataWriter.existingFields(at: file, relativePath: "fixture.nef")
        XCTAssertEqual(raw.carriers.first?.personInImage, ["Sidecar Person"])
    }
}
