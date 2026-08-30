import AppKit
import Foundation
import SwiftExif
import XCTest
@testable import AagedalFTPSync

final class MetadataPreviewAndRecoveryTests: XCTestCase {
    func testDisabledAutomationCanPreviewFolderWithoutMutatingFiles() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let pathsAndDates = [
            ("nested/JAD_APPLY.jpg", timestamp),
            ("JAD_GAP.jpg", timestamp.addingTimeInterval(7_200)),
            ("OTHER.jpg", timestamp),
        ]
        for (path, date) in pathsAndDates {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("original-\(path)".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("JAD_NOT_A_PHOTO.txt"))

        let snapshots = try pathsAndDates.reduce(into: [String: (Data, Date)]()) { result, value in
            let url = folder.appendingPathComponent(value.0)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            result[value.0] = (
                try Data(contentsOf: url),
                try XCTUnwrap(attributes[.modificationDate] as? Date)
            )
        }
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Assignment",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "Preview only")
        )
        let automation = MetadataAutomation(
            isEnabled: false,
            photographers: [photographer],
            clips: [clip]
        )

        let result = try MetadataPreviewService.previewLocalFolder(
            at: folder,
            automation: automation,
            filter: FileFilter(preset: .photos),
            arrivalDate: timestamp
        )

        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.willApply, 1)
        XCTAssertEqual(result.skipped, 2)
        let itemsByPath = Dictionary(uniqueKeysWithValues: result.items.map { ($0.relativePath, $0) })
        XCTAssertEqual(itemsByPath["JAD_GAP.jpg"]?.status, .noScheduledClip)
        XCTAssertEqual(itemsByPath["OTHER.jpg"]?.status, .noMatchingPhotographer)
        XCTAssertEqual(itemsByPath["nested/JAD_APPLY.jpg"]?.status, .willApply)
        XCTAssertEqual(itemsByPath["nested/JAD_APPLY.jpg"]?.photographerName, "Jane Doe")
        XCTAssertEqual(itemsByPath["nested/JAD_APPLY.jpg"]?.clipName, "Assignment")

        for (path, snapshot) in snapshots {
            let url = folder.appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: url), snapshot.0)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(
                (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                snapshot.1.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    func testPreviewReportsMissingCameraCaptureTimePerFile() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("JAD_NO_EXIF.jpg")
        try Data("not an image".utf8).write(to: file)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "",
            copyrightNotice: ""
        )
        let automation = MetadataAutomation(
            timestampPolicy: .cameraCapture,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "All day",
                startsAt: timestamp.addingTimeInterval(-86_400),
                endsAt: timestamp.addingTimeInterval(86_400)
            )]
        )

        let result = try MetadataPreviewService.previewLocalFolder(
            at: folder,
            automation: automation
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].status, .captureTimeUnavailable)
        XCTAssertEqual(result.items[0].photographerName, "Jane Doe")
        XCTAssertNil(result.items[0].scheduledAt)
    }

    func testPreviewRecognizesMetadataThatIsAlreadyApplied() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let file = folder.appendingPathComponent("JAD_APPLIED.jpg")
        try XCTUnwrap(makeImageData(type: .jpeg)).write(to: file)

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "© Example News"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Assignment",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(
                headline: "Already tagged",
                description: "Preview should recognize this.",
                keywords: ["fixture", "applied"]
            )
        )
        let automation = MetadataAutomation(
            isEnabled: true,
            existingFieldPolicy: .overwrite,
            photographers: [photographer],
            clips: [clip]
        )
        let assignment = try XCTUnwrap(
            automation.assignment(for: file.lastPathComponent, scheduledAt: timestamp)
        )
        try MetadataWriter.apply(assignment, to: file)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)

        let result = try MetadataPreviewService.previewLocalFolder(
            at: folder,
            automation: automation,
            filter: FileFilter(preset: .photos),
            arrivalDate: timestamp
        )

        XCTAssertEqual(result.scanned, 1)
        XCTAssertEqual(result.willApply, 0)
        XCTAssertEqual(result.alreadyApplied, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.items.first?.status, .alreadyApplied)
    }

    func testLocalImportVerificationFailureLeavesExistingDestinationUntouched() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("JAD_EXISTING.jpg")
        let replacement = folder.appendingPathComponent("replacement.tmp")
        try Data("original destination".utf8).write(to: destination)
        try Data("replacement".utf8).write(to: replacement)
        let endpoint = try localEndpoint(for: folder)
        let session = try LocalEndpointSession(endpoint: endpoint)

        do {
            try await session.importFile(
                from: replacement,
                as: SyncFile(
                    relativePath: destination.lastPathComponent,
                    size: 999,
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                preserveDate: true,
                verifySize: true
            )
            XCTFail("A mismatched staged copy should fail verification")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Size verification failed"))
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("original destination".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .contains { PathSafety.isInternalStagingPath($0) }
        )
    }

    func testSyncMetadataFailureTransfersOriginalAndReportsFailure() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFolder = folder.appendingPathComponent("source")
        let destinationFolder = folder.appendingPathComponent("destination")
        let processedFolder = folder.appendingPathComponent("processed")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processedFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("JAD_BROKEN.jpg")
        let original = Data("not valid image data".utf8)
        try original.write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = SyncJob(
            name: "Metadata fallback test",
            left: try localEndpoint(for: sourceFolder),
            right: try localEndpoint(for: destinationFolder),
            direction: .leftToRight,
            filter: FileFilter(preset: .photos),
            intervalSeconds: 5,
            isEnabled: false
        )
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Cannot be embedded")
            )]
        )
        job.processedFolder = try localEndpoint(for: processedFolder)
        let signatureRepository = SourceSignatureRepository(
            fileURL: folder.appendingPathComponent("state/signatures.json")
        )

        let result = try await SyncEngine(sourceSignatureRepository: signatureRepository).run(
            job: job,
            leftPassword: nil,
            rightPassword: nil
        )

        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(result.metadataReport.applied, 0)
        XCTAssertEqual(result.metadataReport.failed, 1)
        XCTAssertEqual(result.metadataReport.entries.first?.photographerName, "Jane Doe")
        XCTAssertNotNil(result.metadataReport.entries.first?.detail)
        XCTAssertEqual(
            try Data(contentsOf: destinationFolder.appendingPathComponent(source.lastPathComponent)),
            original
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: processedFolder.appendingPathComponent(source.lastPathComponent).path
            )
        )
    }

    func testSyncReportsSkippedMetadataDecisionsWithMatchedContext() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFolder = folder.appendingPathComponent("source")
        let destinationFolder = folder.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for filename in ["JAD_GAP.jpg", "OTHER.jpg"] {
            let url = sourceFolder.appendingPathComponent(filename)
            try Data(filename.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        }

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = SyncJob(
            name: "Metadata skip test",
            left: try localEndpoint(for: sourceFolder),
            right: try localEndpoint(for: destinationFolder),
            direction: .leftToRight,
            filter: FileFilter(preset: .photos),
            intervalSeconds: 5,
            isEnabled: false
        )
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Later assignment",
                startsAt: timestamp.addingTimeInterval(3_600),
                endsAt: timestamp.addingTimeInterval(7_200)
            )]
        )
        let signatureRepository = SourceSignatureRepository(
            fileURL: folder.appendingPathComponent("state/signatures.json")
        )

        let result = try await SyncEngine(sourceSignatureRepository: signatureRepository).run(
            job: job,
            leftPassword: nil,
            rightPassword: nil
        )

        XCTAssertEqual(result.transferred, 2)
        XCTAssertEqual(result.metadataReport.skipped, 2)
        XCTAssertEqual(result.metadataReport.applied, 0)
        XCTAssertEqual(result.metadataReport.failed, 0)
        let entries = Dictionary(uniqueKeysWithValues: result.metadataReport.entries.map { ($0.relativePath, $0) })
        XCTAssertEqual(entries["JAD_GAP.jpg"]?.photographerName, "Jane Doe")
        XCTAssertTrue(entries["JAD_GAP.jpg"]?.detail?.contains("No scheduled") == true)
        XCTAssertNil(entries["OTHER.jpg"]?.photographerName)
        XCTAssertTrue(entries["OTHER.jpg"]?.detail?.contains("No photographer") == true)
    }

    func testReprocessMetadataFailureLeavesExistingDestinationUntouched() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFolder = folder.appendingPathComponent("source")
        let destinationFolder = folder.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let destination = destinationFolder.appendingPathComponent("JAD_BROKEN.jpg")
        let original = Data("not valid image data".utf8)
        try original.write(to: destination)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: destination.path)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = SyncJob(
            name: "Recovery test",
            left: try localEndpoint(for: sourceFolder),
            right: try localEndpoint(for: destinationFolder),
            direction: .leftToRight,
            filter: FileFilter(preset: .photos),
            intervalSeconds: 5,
            isEnabled: false
        )
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Must not damage destination")
            )]
        )

        let result = try await SyncEngine().reprocessExistingLocalFiles(job: job)

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.metadataReport.failed, 1)
        XCTAssertEqual(result.metadataReport.entries.first?.relativePath, "JAD_BROKEN.jpg")
        XCTAssertNotNil(result.metadataReport.entries.first?.detail)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(
            (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testTIFFAndHEICFixturesRoundTripScheduledMetadata() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "© Fixture Desk"
        )
        let automation = MetadataAutomation(
            isEnabled: true,
            existingFieldPolicy: .overwrite,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Round trip",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(
                    headline: "Fixture headline",
                    description: "Fixture description",
                    keywords: ["fixture", "round-trip"]
                )
            )]
        )
        let tiffName = "JAD_FIXTURE.tiff"
        let tiffURL = folder.appendingPathComponent(tiffName)
        try XCTUnwrap(makeImageData(type: .tiff), "Could not create TIFF fixture").write(to: tiffURL)
        let tiffAssignment = try XCTUnwrap(
            automation.assignment(for: tiffName, scheduledAt: timestamp)
        )
        try MetadataWriter.apply(tiffAssignment, to: tiffURL)

        let tiffMetadata = try ImageMetadata.read(from: tiffURL)
        XCTAssertEqual(tiffMetadata.iptc.headline, "Fixture headline")
        XCTAssertEqual(tiffMetadata.iptc.caption, "Fixture description")
        XCTAssertEqual(tiffMetadata.iptc.keywords, ["fixture", "round-trip"])
        XCTAssertEqual(tiffMetadata.iptc.byline, "Jane Doe")
        XCTAssertEqual(tiffMetadata.iptc.copyright, "© Fixture Desk")
        XCTAssertEqual(tiffMetadata.xmp?.headline, "Fixture headline")
        XCTAssertEqual(tiffMetadata.xmp?.description, "Fixture description")

        // HEIF has no IPTC-IIM segment, so the synchronized values round-trip
        // in the container's XMP metadata item.
        let heicName = "JAD_FIXTURE.heic"
        let heicURL = folder.appendingPathComponent(heicName)
        try makeMinimalHEIF().write(to: heicURL)
        let heicAssignment = try XCTUnwrap(
            automation.assignment(for: heicName, scheduledAt: timestamp)
        )
        try MetadataWriter.apply(heicAssignment, to: heicURL)

        let heicMetadata = try ImageMetadata.read(from: heicURL)
        XCTAssertEqual(heicMetadata.xmp?.headline, "Fixture headline")
        XCTAssertEqual(heicMetadata.xmp?.description, "Fixture description")
        XCTAssertEqual(heicMetadata.xmp?.subject, ["fixture", "round-trip"])
        XCTAssertEqual(heicMetadata.xmp?.creator, ["Jane Doe"])
        XCTAssertEqual(heicMetadata.xmp?.rights, "© Fixture Desk")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func localEndpoint(for url: URL) throws -> Endpoint {
        let bookmark = try FolderBookmark.create(for: url)
        return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
    }

    private func makeImageData(type: NSBitmapImageRep.FileType) -> Data? {
        makeBitmap()?.representation(using: type, properties: [:])
    }

    private func makeMinimalHEIF() -> Data {
        var payload = Data("heic".utf8)
        payload.append(contentsOf: [0, 0, 0, 0])
        return makeISOBMFFBox(type: "ftyp", payload: payload)
    }

    private func makeISOBMFFBox(type: String, payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        var data = Data([
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff),
        ])
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private func makeBitmap() -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }
}
