import AppKit
import Foundation
import SwiftExif
import XCTest
@testable import AagedalFTPSync

final class LocalSyncIntegrationTests: XCTestCase {
    func testOneWaySyncAppliesScheduledMetadataAndDoesNotRepeatTransfer() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("JAD_0001.jpg")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("Could not create the JPEG fixture")
        }
        try jpeg.write(to: source)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "© Example News"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Political conference",
            startsAt: timestamp.addingTimeInterval(-3_600),
            endsAt: timestamp.addingTimeInterval(3_600),
            fields: ScheduledMetadataFields(
                headline: "Political conference",
                description: "Delegates gather in Oslo.",
                keywords: ["politics", "Oslo"]
            )
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            existingFieldPolicy: .overwrite,
            photographers: [photographer],
            clips: [clip]
        )

        let firstResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
        let secondResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(firstResult, SyncResult(transferred: 1, deleted: 0))
        XCTAssertEqual(secondResult, SyncResult(transferred: 0, deleted: 0))

        let destination = fixture.right.appendingPathComponent("JAD_0001.jpg")
        let metadata = try ImageMetadata.read(from: destination)
        XCTAssertEqual(metadata.iptc.headline, "Political conference")
        XCTAssertEqual(metadata.iptc.caption, "Delegates gather in Oslo.")
        XCTAssertEqual(metadata.iptc.byline, "Jane Doe")
        XCTAssertEqual(metadata.iptc.copyright, "© Example News")
        XCTAssertEqual(metadata.iptc.keywords, ["politics", "Oslo"])
    }

    func testMetadataWriterCanFillEmptyFieldsOrAlwaysOverwrite() throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let fillURL = fixture.left.appendingPathComponent("JAD_FILL.jpg")
        let overwriteURL = fixture.left.appendingPathComponent("JAD_OVERWRITE.jpg")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("Could not create the JPEG fixture")
        }
        var original = try ImageMetadata.read(from: jpeg)
        try original.iptc.setValue("Existing headline", for: .headline)
        try original.iptc.setValues(["existing"], for: .keywords)
        let originalData = try original.writeToData()
        try originalData.write(to: fillURL)
        try originalData.write(to: overwriteURL)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Programmed creator",
            copyrightNotice: "Programmed copyright"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Policy test",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(
                headline: "Programmed headline",
                description: "Programmed description",
                keywords: ["programmed"]
            )
        )

        let fillAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            existingFieldPolicy: .fillEmpty,
            photographers: [photographer],
            clips: [clip]
        )
        let overwriteAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            existingFieldPolicy: .overwrite,
            photographers: [photographer],
            clips: [clip]
        )
        let fillAssignment = try XCTUnwrap(fillAutomation.assignment(for: fillURL.lastPathComponent, scheduledAt: timestamp))
        let overwriteAssignment = try XCTUnwrap(overwriteAutomation.assignment(for: overwriteURL.lastPathComponent, scheduledAt: timestamp))

        try MetadataWriter.apply(fillAssignment, to: fillURL)
        try MetadataWriter.apply(overwriteAssignment, to: overwriteURL)

        let filled = try ImageMetadata.read(from: fillURL)
        XCTAssertEqual(filled.iptc.headline, "Existing headline")
        XCTAssertEqual(filled.iptc.keywords, ["existing"])
        XCTAssertEqual(filled.iptc.caption, "Programmed description")
        XCTAssertEqual(filled.iptc.byline, "Programmed creator")
        XCTAssertEqual(filled.iptc.copyright, "Programmed copyright")

        let overwritten = try ImageMetadata.read(from: overwriteURL)
        XCTAssertEqual(overwritten.iptc.headline, "Programmed headline")
        XCTAssertEqual(overwritten.iptc.keywords, ["programmed"])
    }

    func testOneWaySyncCanScheduleMetadataByLocalArrivalTime() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("JAD_ARRIVAL.jpg")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("Could not create the JPEG fixture")
        }
        try jpeg.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: source.path
        )

        let now = Date()
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Arrival window",
            startsAt: now.addingTimeInterval(-60),
            endsAt: now.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "Arrived now")
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .localArrival,
            photographers: [photographer],
            clips: [clip]
        )

        let result = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 1, deleted: 0))
        let destination = fixture.right.appendingPathComponent("JAD_ARRIVAL.jpg")
        let metadata = try ImageMetadata.read(from: destination)
        XCTAssertEqual(metadata.iptc.headline, "Arrived now")
    }

    func testOneWaySyncCanScheduleMetadataByExifCaptureTime() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("JAD_CAPTURE.jpg")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("Could not create the JPEG fixture")
        }
        try jpeg.write(to: source)

        let captureValue = "2026:08:29 14:30:45"
        var sourceMetadata = try ImageMetadata.read(from: source)
        var exif = ExifData(byteOrder: .bigEndian)
        let captureData = Data((captureValue + "\0").utf8)
        exif.exifIFD = IFD(entries: [
            IFDEntry(
                tag: ExifTag.dateTimeOriginal,
                type: .ascii,
                count: UInt32(captureData.count),
                valueData: captureData
            ),
        ])
        sourceMetadata.exif = exif
        try sourceMetadata.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: source.path
        )
        let captureDate = try XCTUnwrap(MetadataWriter.captureDate(from: source))

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Capture window",
            startsAt: captureDate.addingTimeInterval(-60),
            endsAt: captureDate.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "Captured then")
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .cameraCapture,
            photographers: [photographer],
            clips: [clip]
        )

        let result = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 1, deleted: 0))
        let destination = fixture.right.appendingPathComponent("JAD_CAPTURE.jpg")
        let metadata = try ImageMetadata.read(from: destination)
        XCTAssertEqual(metadata.iptc.headline, "Captured then")
    }

    func testOneWaySyncCopiesDataAndModificationDate() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("selects/NEWS_001.CR3")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("camera-data".utf8).write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)

        let result = try await SyncEngine().run(job: fixture.job(direction: .leftToRight), leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 1, deleted: 0))
        let destination = fixture.right.appendingPathComponent("selects/NEWS_001.CR3")
        XCTAssertEqual(try Data(contentsOf: destination), Data("camera-data".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 1)
    }

    func testOneWaySyncDoesNotTransferAnUnchangedFileAgain() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("NEWS_001.jpg")
        try Data("camera-data".utf8).write(to: source)
        let job = try fixture.job(direction: .leftToRight)

        let firstResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
        let secondResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(firstResult, SyncResult(transferred: 1, deleted: 0))
        XCTAssertEqual(secondResult, SyncResult(transferred: 0, deleted: 0))
    }

    func testTwoWaySyncCopiesUniqueFilesInBothDirections() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        try Data("left".utf8).write(to: fixture.left.appendingPathComponent("left.jpg"))
        try Data("right".utf8).write(to: fixture.right.appendingPathComponent("right.nef"))

        let result = try await SyncEngine().run(job: fixture.job(direction: .bidirectional), leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 2, deleted: 0))
        XCTAssertEqual(try Data(contentsOf: fixture.right.appendingPathComponent("left.jpg")), Data("left".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.left.appendingPathComponent("right.nef")), Data("right".utf8))
    }

    func testTwoWaySyncReportsAmbiguousSameTimestampConflict() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let leftFile = fixture.left.appendingPathComponent("conflict.jpg")
        let rightFile = fixture.right.appendingPathComponent("conflict.jpg")
        try Data("left".utf8).write(to: leftFile)
        try Data("different-right".utf8).write(to: rightFile)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [leftFile, rightFile] {
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        }

        let result = try await SyncEngine().run(
            job: fixture.job(direction: .bidirectional),
            leftPassword: nil,
            rightPassword: nil
        )

        XCTAssertEqual(result, SyncResult(transferred: 0, deleted: 0, conflicts: ["conflict.jpg"]))
        XCTAssertEqual(try Data(contentsOf: leftFile), Data("left".utf8))
        XCTAssertEqual(try Data(contentsOf: rightFile), Data("different-right".utf8))
    }

    func testCleanupDeletesOnlyOldMatchingFilesFromTarget() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let now = Date()
        let oldDate = now.addingTimeInterval(-3 * 3_600)
        let recentDate = now.addingTimeInterval(-30 * 60)
        let oldSource = fixture.left.appendingPathComponent("source-old.jpg")
        let recentSource = fixture.left.appendingPathComponent("source-new.jpg")
        let oldTarget = fixture.right.appendingPathComponent("target-old.jpg")
        let oldNonMatchingTarget = fixture.right.appendingPathComponent("keep-old.txt")
        let recentTarget = fixture.right.appendingPathComponent("keep-new.jpg")

        for url in [oldSource, recentSource, oldTarget, oldNonMatchingTarget, recentTarget] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        for url in [oldSource, oldTarget, oldNonMatchingTarget] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        for url in [recentSource, recentTarget] {
            try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: url.path)
        }

        var job = try fixture.job(direction: .leftToRight)
        job.filter = FileFilter(preset: .photos, recentHours: 1)
        job.targetCleanup = TargetCleanup(olderThanHours: 2)
        let result = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 1, deleted: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSource.path), "Cleanup must never touch the source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.right.appendingPathComponent("source-new.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldNonMatchingTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentTarget.path))
    }

    func testSyncRejectsSymlinkedDestinationDirectory() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("nested/escape.jpg")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("camera-data".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(
            at: fixture.right.appendingPathComponent("nested"),
            withDestinationURL: fixture.outside
        )

        do {
            _ = try await SyncEngine().run(
                job: fixture.job(direction: .leftToRight),
                leftPassword: nil,
                rightPassword: nil
            )
            XCTFail("The sync should reject a destination path containing a symbolic link")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("escape.jpg").path)
        )
    }
}

private final class LocalFixture {
    let root: URL
    let left: URL
    let right: URL
    let outside: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AagedalSyncTests-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func job(direction: SyncDirection) throws -> SyncJob {
        let leftEndpoint = try endpoint(for: left)
        let rightEndpoint = try endpoint(for: right)
        return SyncJob(
            name: "Test",
            left: leftEndpoint,
            right: rightEndpoint,
            direction: direction,
            filter: FileFilter(preset: .photos),
            intervalSeconds: 5,
            isEnabled: false
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private func endpoint(for url: URL) throws -> Endpoint {
        let bookmark = try FolderBookmark.create(for: url)
        return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
    }
}
