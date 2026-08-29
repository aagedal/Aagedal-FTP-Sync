import AppKit
import Foundation
import XCTest
@testable import AagedalFTPSync

final class SourceSignatureRepositoryTests: XCTestCase {
    func testSyncRetransfersMetadataDestinationWhenSourceSizeChangesAtSameTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-signature-sync-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let sourceURL = sourceFolder.appendingPathComponent("JAD_0001.jpg")
        try makeJPEG(width: 2, height: 2).write(to: sourceURL)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: sourceURL.path)
        let originalSourceSize = try fileSize(at: sourceURL)

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = SyncJob(
            name: "Signature test",
            left: try localEndpoint(for: sourceFolder),
            right: try localEndpoint(for: destinationFolder),
            direction: .leftToRight,
            filter: FileFilter(preset: .photos),
            intervalSeconds: 5,
            isEnabled: false
        )
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            existingFieldPolicy: .overwrite,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Signature test")
            )]
        )
        let repository = SourceSignatureRepository(
            fileURL: root.appendingPathComponent("state/signatures.json")
        )
        let engine = SyncEngine(sourceSignatureRepository: repository)

        let firstResult = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(firstResult.transferred, 1)
        let destinationURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)
        XCTAssertNotEqual(
            try fileSize(at: destinationURL),
            originalSourceSize,
            "Embedded metadata should make destination size unsuitable as the original source signature."
        )
        try FileManager.default.setAttributes(
            [.modificationDate: timestamp.addingTimeInterval(3_600)],
            ofItemAtPath: destinationURL.path
        )

        try makeJPEG(width: 20, height: 20).write(to: sourceURL)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: sourceURL.path)
        let replacementSourceSize = try fileSize(at: sourceURL)
        XCTAssertNotEqual(replacementSourceSize, originalSourceSize)

        let secondResult = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        let thirdResult = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(secondResult.transferred, 1)
        XCTAssertEqual(thirdResult.transferred, 0)
        let savedSignature = try await repository.signature(
            jobID: job.id,
            sourceEndpoint: job.left,
            relativePath: sourceURL.lastPathComponent
        )
        XCTAssertEqual(savedSignature?.size, replacementSourceSize)
    }

    func testPersistsOriginalSourceSignatureAcrossRepositoryInstances() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let jobID = UUID()
        let source = Endpoint(kind: .sftp, host: " Photos.Example.COM ", username: "desk", remotePath: "/incoming/")
        let file = SyncFile(
            relativePath: "selects/JAD_0001.jpg",
            size: 12_345,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )

        let writer = SourceSignatureRepository(fileURL: fixture.fileURL)
        try await writer.record(file, jobID: jobID, sourceEndpoint: source)

        let reader = SourceSignatureRepository(fileURL: fixture.fileURL)
        let equivalentSource = Endpoint(
            kind: .sftp,
            host: "photos.example.com",
            username: "desk",
            remotePath: "/incoming"
        )
        let signature = try await reader.signature(
            jobID: jobID,
            sourceEndpoint: equivalentSource,
            relativePath: file.relativePath
        )

        XCTAssertEqual(signature?.size, file.size)
        XCTAssertEqual(
            try XCTUnwrap(signature).modifiedAt.timeIntervalSince1970,
            file.modifiedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertTrue(try XCTUnwrap(signature).matches(file))
    }

    func testKeepsSignaturesSeparateByJobEndpointAndPath() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let firstJobID = UUID()
        let secondJobID = UUID()
        let firstEndpoint = Endpoint(kind: .ftp, host: "one.example.com", username: "desk")
        let secondEndpoint = Endpoint(kind: .ftp, host: "two.example.com", username: "desk")
        let first = SyncFile(relativePath: "photo.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))
        let second = SyncFile(relativePath: "photo.jpg", size: 200, modifiedAt: Date(timeIntervalSince1970: 100))

        try await repository.record(first, jobID: firstJobID, sourceEndpoint: firstEndpoint)
        try await repository.record(second, jobID: firstJobID, sourceEndpoint: secondEndpoint)
        try await repository.record(second, jobID: secondJobID, sourceEndpoint: firstEndpoint)

        let firstJobFirstEndpoint = try await repository.signature(
            jobID: firstJobID,
            sourceEndpoint: firstEndpoint,
            relativePath: "photo.jpg"
        )
        let firstJobSecondEndpoint = try await repository.signature(
            jobID: firstJobID,
            sourceEndpoint: secondEndpoint,
            relativePath: "photo.jpg"
        )
        let secondJobFirstEndpoint = try await repository.signature(
            jobID: secondJobID,
            sourceEndpoint: firstEndpoint,
            relativePath: "photo.jpg"
        )

        XCTAssertEqual(firstJobFirstEndpoint?.size, 100)
        XCTAssertEqual(firstJobSecondEndpoint?.size, 200)
        XCTAssertEqual(secondJobFirstEndpoint?.size, 200)
    }

    func testDetectsSizeChangeThatRetainsModificationTimestamp() {
        let original = SourceFileSignature(
            size: 100,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let changed = SyncFile(
            relativePath: "photo.jpg",
            size: 101,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertFalse(original.matches(changed))
    }

    func testRemovesEverySignatureForDeletedJob() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let removedJobID = UUID()
        let retainedJobID = UUID()
        let endpoint = Endpoint(kind: .ftps, host: "photos.example.com", username: "desk")
        let file = SyncFile(relativePath: "photo.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))

        try await repository.record(file, jobID: removedJobID, sourceEndpoint: endpoint)
        try await repository.record(file, jobID: retainedJobID, sourceEndpoint: endpoint)
        try await repository.removeSignatures(jobID: removedJobID)

        let removed = try await repository.signature(
            jobID: removedJobID,
            sourceEndpoint: endpoint,
            relativePath: file.relativePath
        )
        let retained = try await repository.signature(
            jobID: retainedJobID,
            sourceEndpoint: endpoint,
            relativePath: file.relativePath
        )

        XCTAssertNil(removed)
        XCTAssertNotNil(retained)
    }

    func testRecoversSignaturesFromBackupWhenPrimaryFileIsCorrupt() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let jobID = UUID()
        let endpoint = Endpoint(kind: .local, localPath: "/source")
        let recoverable = SyncFile(relativePath: "first.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))
        let newer = SyncFile(relativePath: "second.jpg", size: 200, modifiedAt: Date(timeIntervalSince1970: 200))
        let writer = SourceSignatureRepository(fileURL: fixture.fileURL)
        try await writer.record(recoverable, jobID: jobID, sourceEndpoint: endpoint)
        try await writer.record(newer, jobID: jobID, sourceEndpoint: endpoint)
        try Data("not valid JSON".utf8).write(to: fixture.fileURL, options: .atomic)

        let reader = SourceSignatureRepository(fileURL: fixture.fileURL)
        let recovered = try await reader.signatures(jobID: jobID, sourceEndpoint: endpoint)

        XCTAssertEqual(recovered[recoverable.relativePath]?.size, recoverable.size)
        XCTAssertNil(recovered[newer.relativePath])
    }

    private func makeFixture() -> (fileURL: URL, cleanUp: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-signature-tests-\(UUID().uuidString)", isDirectory: true)
        return (
            root.appendingPathComponent("signatures.json"),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = bitmap.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private func localEndpoint(for folder: URL) throws -> Endpoint {
        let bookmark = try FolderBookmark.create(for: folder)
        return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }
}
