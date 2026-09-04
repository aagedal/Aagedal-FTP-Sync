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

        let returningSource = try Data(contentsOf: sourceURL)
        try FileManager.default.removeItem(at: sourceURL)
        try await repository.reconcile(
            jobID: job.id,
            sourceEndpoint: job.left,
            sourceRelativePaths: [],
            destinationRelativePaths: [sourceURL.lastPathComponent],
            observedAt: Date().addingTimeInterval(SourceSignatureRepository.missingSourceRetention + 1)
        )
        let expiredSignature = try await repository.signature(
            jobID: job.id,
            sourceEndpoint: job.left,
            relativePath: sourceURL.lastPathComponent
        )
        XCTAssertNil(expiredSignature)

        try returningSource.write(to: sourceURL)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: sourceURL.path)
        let returnResult = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        let settledResult = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(returnResult.transferred, 1, "An expired signature must use the safe bootstrap transfer.")
        XCTAssertEqual(settledResult.transferred, 0)
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

    func testMetadataRunPersistsMultipleSourceSignaturesInOneBatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-signature-batch-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for filename in ["JAD_0001.jpg", "JAD_0002.jpg"] {
            let url = sourceFolder.appendingPathComponent(filename)
            try makeJPEG(width: 2, height: 2).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        }
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = SyncJob(
            name: "Signature batch test",
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
                fields: ScheduledMetadataFields(headline: "Batch test")
            )]
        )
        let signatureURL = root.appendingPathComponent("state/signatures.json")
        let repository = SourceSignatureRepository(fileURL: signatureURL)

        let result = try await SyncEngine(sourceSignatureRepository: repository).run(
            job: job,
            leftPassword: nil,
            rightPassword: nil
        )

        XCTAssertEqual(result.transferred, 2)
        let savedSignatures = try await repository.signatures(jobID: job.id, sourceEndpoint: job.left)
        XCTAssertEqual(savedSignatures.count, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: signatureURL.appendingPathExtension("backup").path),
            "A single batched persistence should not create an intermediate backup."
        )
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

    func testPrunesOnlySupersededSourceEndpointIdentities() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let jobID = UUID()
        let otherJobID = UUID()
        let oldEndpoint = Endpoint(kind: .ftp, host: "old.example.com", username: "desk")
        let retainedEndpoint = Endpoint(kind: .ftp, host: "new.example.com", username: "desk")
        let file = SyncFile(relativePath: "photo.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))

        try await repository.record(file, jobID: jobID, sourceEndpoint: oldEndpoint)
        try await repository.record(file, jobID: jobID, sourceEndpoint: retainedEndpoint)
        try await repository.record(file, jobID: otherJobID, sourceEndpoint: oldEndpoint)
        try await repository.pruneSignatures(jobID: jobID, retainingSourceEndpoints: [retainedEndpoint])

        let removed = try await repository.signature(
            jobID: jobID,
            sourceEndpoint: oldEndpoint,
            relativePath: file.relativePath
        )
        let retained = try await repository.signature(
            jobID: jobID,
            sourceEndpoint: retainedEndpoint,
            relativePath: file.relativePath
        )
        let otherJob = try await repository.signature(
            jobID: otherJobID,
            sourceEndpoint: oldEndpoint,
            relativePath: file.relativePath
        )
        XCTAssertNil(removed)
        XCTAssertNotNil(retained)
        XCTAssertNotNil(otherJob)
    }

    func testMigratesLegacyJSONAtomically() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let jobID = UUID()
        let endpoint = Endpoint(kind: .sftp, host: "photos.example.com", username: "desk", remotePath: "/incoming")
        let file = SyncFile(relativePath: "first.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))
        try writeLegacyJSON(to: fixture.fileURL, jobID: jobID, endpoint: endpoint, files: [file])

        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let migrated = try await repository.signature(
            jobID: jobID,
            sourceEndpoint: endpoint,
            relativePath: file.relativePath
        )

        XCTAssertEqual(migrated, SourceFileSignature(file: file))
        XCTAssertEqual(try databaseHeader(at: fixture.fileURL), Data("SQLite format 3\0".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.fileURL.appendingPathExtension("pre-sqlite-backup").path
            ),
            "The original JSON should remain recoverable after the atomic replacement."
        )
    }

    func testMigratesLegacyBackupWhenPrimaryJSONIsCorrupt() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let jobID = UUID()
        let endpoint = Endpoint(kind: .local, localPath: "/source")
        let recoverable = SyncFile(relativePath: "first.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))
        try writeLegacyJSON(
            to: fixture.fileURL.appendingPathExtension("backup"),
            jobID: jobID,
            endpoint: endpoint,
            files: [recoverable]
        )
        try Data("not valid JSON".utf8).write(to: fixture.fileURL, options: .atomic)

        let reader = SourceSignatureRepository(fileURL: fixture.fileURL)
        let recovered = try await reader.signatures(jobID: jobID, sourceEndpoint: endpoint)

        XCTAssertEqual(recovered[recoverable.relativePath]?.size, recoverable.size)
        XCTAssertEqual(try databaseHeader(at: fixture.fileURL), Data("SQLite format 3\0".utf8))
    }

    func testRestartsAnInterruptedLegacyMigrationFromTheIntactJSON() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let jobID = UUID()
        let endpoint = Endpoint(kind: .ftp, host: "photos.example.com", username: "desk")
        let file = SyncFile(relativePath: "first.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))
        try writeLegacyJSON(to: fixture.fileURL, jobID: jobID, endpoint: endpoint, files: [file])
        let interruptedURL = fixture.fileURL.appendingPathExtension("migration-in-progress")
        try Data("partial SQLite migration".utf8).write(to: interruptedURL)

        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let recovered = try await repository.signature(
            jobID: jobID,
            sourceEndpoint: endpoint,
            relativePath: file.relativePath
        )

        XCTAssertEqual(recovered, SourceFileSignature(file: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedURL.path))
    }

    func testPathLimitedLookupDoesNotMaterializeUnrequestedHistory() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let jobID = UUID()
        let endpoint = Endpoint(kind: .ftps, host: "photos.example.com", username: "desk")
        let files = (0..<100).map { index in
            SyncFile(
                relativePath: "archive/photo-\(index).jpg",
                size: Int64(index),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        try await repository.record(files, jobID: jobID, sourceEndpoint: endpoint)

        let selected = try await repository.signatures(
            jobID: jobID,
            sourceEndpoint: endpoint,
            relativePaths: [files[7].relativePath, "not-present.jpg"]
        )

        XCTAssertEqual(selected, [files[7].relativePath: SourceFileSignature(file: files[7])])
        XCTAssertEqual(try databaseHeader(at: fixture.fileURL), Data("SQLite format 3\0".utf8))
    }

    func testReconciliationPrunesIrrelevantPathsAndRetainsTemporaryDisappearances() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let jobID = UUID()
        let endpoint = Endpoint(kind: .ftp, host: "photos.example.com", username: "desk")
        let irrelevant = SyncFile(relativePath: "gone.jpg", size: 100, modifiedAt: Date(timeIntervalSince1970: 100))
        let temporarilyMissing = SyncFile(relativePath: "published.jpg", size: 200, modifiedAt: Date(timeIntervalSince1970: 200))
        try await repository.record([irrelevant, temporarilyMissing], jobID: jobID, sourceEndpoint: endpoint)
        let now = Date()

        try await repository.reconcile(
            jobID: jobID,
            sourceEndpoint: endpoint,
            sourceRelativePaths: [],
            destinationRelativePaths: [temporarilyMissing.relativePath],
            observedAt: now
        )

        let removedIrrelevant = try await repository.signature(
            jobID: jobID,
            sourceEndpoint: endpoint,
            relativePath: irrelevant.relativePath
        )
        let retainedMissing = try await repository.signature(
            jobID: jobID,
            sourceEndpoint: endpoint,
            relativePath: temporarilyMissing.relativePath
        )
        XCTAssertNil(removedIrrelevant)
        XCTAssertNotNil(retainedMissing)

        try await repository.reconcile(
            jobID: jobID,
            sourceEndpoint: endpoint,
            sourceRelativePaths: [],
            destinationRelativePaths: [temporarilyMissing.relativePath],
            observedAt: now.addingTimeInterval(SourceSignatureRepository.missingSourceRetention + 1)
        )

        let expiredMissing = try await repository.signature(
            jobID: jobID,
            sourceEndpoint: endpoint,
            relativePath: temporarilyMissing.relativePath
        )
        XCTAssertNil(expiredMissing)
    }

    func testOneMillionRecordIndexedStore() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SOURCE_SIGNATURE_SCALE_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_SOURCE_SIGNATURE_SCALE_TESTS=1 to run the one-million-record persistence test.")
        }
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let repository = SourceSignatureRepository(fileURL: fixture.fileURL)
        let jobID = UUID()
        let endpoint = Endpoint(kind: .sftp, host: "scale.example.com", username: "desk")
        let batchSize = 10_000
        for batchStart in stride(from: 0, to: 1_000_000, by: batchSize) {
            let files = (batchStart..<(batchStart + batchSize)).map { index in
                SyncFile(
                    relativePath: String(format: "archive/%07d.jpg", index),
                    size: Int64(index),
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }
            try await repository.record(files, jobID: jobID, sourceEndpoint: endpoint)
        }

        let requested = ["archive/0000000.jpg", "archive/0500000.jpg", "archive/0999999.jpg"]
        let signatures = try await repository.signatures(
            jobID: jobID,
            sourceEndpoint: endpoint,
            relativePaths: requested
        )
        XCTAssertEqual(signatures.count, requested.count)
        XCTAssertEqual(signatures[requested[1]]?.size, 500_000)
    }

    private func makeFixture() -> (fileURL: URL, cleanUp: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-signature-tests-\(UUID().uuidString)", isDirectory: true)
        return (
            root.appendingPathComponent("signatures.json"),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func writeLegacyJSON(
        to url: URL,
        jobID: UUID,
        endpoint: Endpoint,
        files: [SyncFile]
    ) throws {
        let source: [String: Any]
        switch endpoint.kind {
        case .local:
            source = [
                "kind": endpoint.kind.rawValue,
                "localPath": URL(fileURLWithPath: endpoint.localPath).standardizedFileURL.path,
                "host": "",
                "port": 0,
                "username": "",
                "remotePath": ""
            ]
        case .ftp, .ftps, .sftp:
            let trimmedPath = endpoint.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            source = [
                "kind": endpoint.kind.rawValue,
                "localPath": "",
                "host": endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                "port": endpoint.port,
                "username": endpoint.username,
                "remotePath": trimmedPath.count > 1 && trimmedPath.hasSuffix("/")
                    ? String(trimmedPath.dropLast())
                    : trimmedPath
            ]
        }
        let records: [[String: Any]] = files.map { file in
            [
                "jobID": jobID.uuidString,
                "source": source,
                "relativePath": file.relativePath,
                "signature": [
                    "size": file.size,
                    "modifiedAt": file.modifiedAt.timeIntervalSince1970 * 1_000
                ]
            ]
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func databaseHeader(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 16) ?? Data()
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
