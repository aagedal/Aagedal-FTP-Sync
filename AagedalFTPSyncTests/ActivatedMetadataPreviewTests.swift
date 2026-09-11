import AppKit
import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class ActivatedMetadataPreviewTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func image(at url: URL) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
    }
    private func automation(source: String) throws -> MetadataAutomation {
        let profile = PhotographerProfile(name: "Preview Author", filenamePrefix: "T", creator: "Preview Author", copyrightNotice: "")
        var fields = ScheduledMetadataFields()
        fields.setHeadline(try .activated(source))
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Preview", startsAt: date.addingTimeInterval(-60),
            endsAt: date.addingTimeInterval(60), fields: fields)
        return MetadataAutomation(isEnabled: false, timestampPolicy: .localArrival,
            existingFieldPolicy: .init(overwriteFields: []), photographers: [profile], clips: [clip])
    }
    private func preview(_ folder: URL, source: String) throws -> MetadataPreviewResult {
        try MetadataPreviewService.previewLocalFolder(at: folder, automation: automation(source: source), arrivalDate: date,
                                                      processingTimeZone: TimeZone(identifier: "Europe/Oslo")!)
    }

    func testBadImageDoesNotAbortOtherFilesAndAllBytesRemainUnchanged() throws {
        let root = try folder()
        let good = root.appendingPathComponent("T_good.jpg")
        let bad = root.appendingPathComponent("T_bad.jpg")
        try image(at: good)
        try Data("invalid jpeg".utf8).write(to: bad)
        let before = try [good, bad].map { try Data(contentsOf: $0) }
        let result = try preview(root, source: "{photographer}")
        XCTAssertEqual(result.scanned, 2)
        XCTAssertEqual(result.needsAttention, 1)
        let goodItem = try XCTUnwrap(result.items.first { $0.relativePath == good.lastPathComponent })
        let badItem = try XCTUnwrap(result.items.first { $0.relativePath == bad.lastPathComponent })
        XCTAssertEqual(goodItem.status, .willApply)
        XCTAssertEqual(goodItem.processing?.changes.headline, "Preview Author")
        XCTAssertEqual(badItem.status, .previewFailed)
        XCTAssertNotNil(badItem.detail)
        XCTAssertEqual(try [good, bad].map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testMissingDependencyIsIncompleteAndNeverCountedAsWillApply() throws {
        let root = try folder()
        try image(at: root.appendingPathComponent("T_missing.jpg"))
        let result = try preview(root, source: "{gps:city}")
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .resolutionIncomplete)
        XCTAssertEqual(item.processing?.fields[.headline], .omitted(.template(.missingValues([.city]))))
        XCTAssertEqual(result.willApply, 0)
        XCTAssertEqual(result.needsAttention, 1)
    }

    func testAllPreservedFieldsDoNotClaimAWrite() throws {
        let root = try folder()
        let file = root.appendingPathComponent("T_preserved.jpg")
        try image(at: file)
        _ = try MetadataWriter.apply(ResolvedMetadataChanges(headline: "Existing", creator: "Existing author", existingFieldPolicy: .overwrite), to: file)
        let before = try Data(contentsOf: file)
        let result = try preview(root, source: "{gps:city}")
        XCTAssertEqual(result.items.first?.status, .noChanges)
        XCTAssertEqual(result.willApply, 0)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
