import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class TransactionalRemovalTests: XCTestCase {
    func testFirstDeletionFailureRestoresEveryStagedSource() async throws {
        let sources = ["first.source", "second.source"]
        let holdings = ["first.hold", "second.hold"]
        var locations = Set(sources)

        do {
            try await TransactionalRemoval.stageAndDelete(
                sources: sources,
                holdings: holdings,
                labels: ["first.raw", "second.xmp"],
                move: { source, destination in
                    guard locations.remove(source) != nil else {
                        throw AppError.transferFailed("Missing \(source)")
                    }
                    locations.insert(destination)
                },
                delete: { _ in
                    throw AppError.transferFailed("Injected delete failure")
                }
            )
            XCTFail("The injected deletion failure should be reported.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No source files were deleted"))
            XCTAssertTrue(error.localizedDescription.contains("restored to its original name"))
        }

        XCTAssertEqual(locations, Set(sources))
        XCTAssertTrue(locations.isDisjoint(with: holdings))
    }

    func testLaterDeletionFailureRestoresRemainingSourceAndReportsRemovedItem() async throws {
        let sources = ["first.source", "second.source"]
        let holdings = ["first.hold", "second.hold"]
        var locations = Set(sources)
        var deletionCount = 0

        do {
            try await TransactionalRemoval.stageAndDelete(
                sources: sources,
                holdings: holdings,
                labels: ["first.raw", "second.xmp"],
                move: { source, destination in
                    guard locations.remove(source) != nil else {
                        throw AppError.transferFailed("Missing \(source)")
                    }
                    locations.insert(destination)
                },
                delete: { holding in
                    deletionCount += 1
                    if deletionCount == 2 {
                        throw AppError.transferFailed("Injected second delete failure")
                    }
                    guard locations.remove(holding) != nil else {
                        throw AppError.transferFailed("Missing \(holding)")
                    }
                }
            )
            XCTFail("The injected second deletion failure should be reported.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already removed: first.raw"))
            XCTAssertTrue(error.localizedDescription.contains("restored to its original name"))
        }

        XCTAssertFalse(locations.contains(sources[0]))
        XCTAssertTrue(locations.contains(sources[1]))
        XCTAssertTrue(locations.isDisjoint(with: holdings))
    }
}

final class LocalSyncIntegrationTests: XCTestCase {
    func testLocalArrivalDateIsSetForNewAndReplacementPublication() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let input = fixture.outside.appendingPathComponent("arrival-input.jpg")
        try Data("new contents".utf8).write(to: input)
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: input.path)
        let session = try LocalEndpointSession(endpoint: fixture.endpoint(for: fixture.right))
        let file = SyncFile(relativePath: "arrival.jpg", size: 12, modifiedAt: oldDate)

        let firstStart = Date()
        try await session.importFile(from: input, as: file, preserveDate: false, verifySize: true)
        let firstDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.right.appendingPathComponent("arrival.jpg").path)[.modificationDate] as? Date
        )
        XCTAssertGreaterThanOrEqual(firstDate, firstStart.addingTimeInterval(-1))

        try Data("replacement!".utf8).write(to: input)
        let replacement = SyncFile(relativePath: "arrival.jpg", size: 12, modifiedAt: oldDate)
        let replacementStart = Date()
        try await session.importFile(from: input, as: replacement, preserveDate: false, verifySize: true)
        let replacementDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.right.appendingPathComponent("arrival.jpg").path)[.modificationDate] as? Date
        )
        XCTAssertGreaterThanOrEqual(replacementDate, replacementStart.addingTimeInterval(-1))
    }

    func testTransactionalLocalPairRemovalRollsBackWhenSecondStageFails() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let raw = fixture.left.appendingPathComponent("PAIR.CR3")
        let xmp = fixture.left.appendingPathComponent("PAIR.xmp")
        let rawData = Data("raw".utf8)
        let xmpData = Data("xmp".utf8)
        try rawData.write(to: raw)
        try xmpData.write(to: xmp)
        let sharedHolding = fixture.left.appendingPathComponent(".aagedal-sync-injected.hold")
        let session = try LocalEndpointSession(
            endpoint: fixture.endpoint(for: fixture.left),
            holdingURLFactory: { _ in sharedHolding }
        )
        let timestamp = Date()

        do {
            try await session.removeFilesTransactionally([
                SyncFile(relativePath: "PAIR.CR3", size: 3, modifiedAt: timestamp),
                SyncFile(relativePath: "PAIR.xmp", size: 3, modifiedAt: timestamp),
            ])
            XCTFail("The injected second staging move should fail")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: raw), rawData)
        XCTAssertEqual(try Data(contentsOf: xmp), xmpData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedHolding.path))
    }

    func testFastStartDestinationLookupRejectsCaseEquivalentCollision() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let existingURL = fixture.right.appendingPathComponent("NEWS_001.JPG")
        try Data("existing".utf8).write(to: existingURL)
        let session = try LocalEndpointSession(endpoint: fixture.endpoint(for: fixture.right))

        let existing = try await session.fileInfo(relativePath: "NEWS_001.JPG")
        XCTAssertEqual(existing?.size, 8)
        do {
            _ = try await session.fileInfo(relativePath: "news_001.jpg")
            XCTFail("Expected the case-equivalent destination path to be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot safely coexist"))
        }
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("existing".utf8))
    }

    @MainActor
    func testResetJobClearsPersistedDownloadHistory() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let downloadedFile = fixture.right.appendingPathComponent("incoming/JAD_HISTORY.jpg")
        try FileManager.default.createDirectory(
            at: downloadedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("downloaded".utf8).write(to: downloadedFile)

        let persistenceRoot = fixture.root.appendingPathComponent("persistence", isDirectory: true)
        let jobRepository = JobRepository(fileURL: persistenceRoot.appendingPathComponent("jobs.json"))
        let auditRepository = MetadataAuditRepository(fileURL: persistenceRoot.appendingPathComponent("audit.json"))
        let failureRepository = SyncFailureRepository(fileURL: persistenceRoot.appendingPathComponent("failures.json"))
        let signatureRepository = SourceSignatureRepository(
            fileURL: persistenceRoot.appendingPathComponent("signatures.json")
        )
        let job = try fixture.job(direction: .leftToRight)
        try jobRepository.save([job])

        let auditEntry = MetadataAuditEntry(
            runID: UUID(),
            jobID: job.id,
            operation: .transfer,
            relativePath: "incoming/JAD_HISTORY.jpg",
            status: .applied,
            timestampPolicy: .sourceModification,
            scheduledAt: Date()
        )
        try auditRepository.append(MetadataRunReport(entries: [auditEntry]))
        try failureRepository.append(SyncFailureRecord(jobID: job.id, message: "Previous failure"))
        try await signatureRepository.record(
            SyncFile(
                relativePath: "incoming/JAD_HISTORY.jpg",
                size: 10,
                modifiedAt: Date()
            ),
            jobID: job.id,
            sourceEndpoint: job.left
        )

        let store = AppStore(
            repository: jobRepository,
            metadataPresetRepository: MetadataPresetRepository(
                fileURL: persistenceRoot.appendingPathComponent("presets.json")
            ),
            photographerProfileRepository: PhotographerProfileRepository(
                fileURL: persistenceRoot.appendingPathComponent("photographers.json")
            ),
            metadataAuditRepository: auditRepository,
            syncFailureRepository: failureRepository,
            sourceSignatureRepository: signatureRepository
        )
        XCTAssertEqual(store.metadataAuditTrail(for: job.id).map(\.relativePath), [auditEntry.relativePath])
        XCTAssertEqual(store.syncFailureHistory(for: job.id).count, 1)

        store.resetJob(job.id)
        while store.resettingJobs.contains(job.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedFile.path))
        XCTAssertEqual(store.metadataAuditTrail(for: job.id), [])
        XCTAssertEqual(store.syncFailureHistory(for: job.id), [])
        let remainingSignatures = try await signatureRepository.signatures(
            jobID: job.id,
            sourceEndpoint: job.left
        )
        XCTAssertEqual(remainingSignatures, [:])
        XCTAssertFalse(try XCTUnwrap(store.jobs.first).isEnabled)
        XCTAssertFalse(try XCTUnwrap(store.jobs.first).startsOnAppLaunch)
        XCTAssertEqual(store.phases[job.id], .stopped)
        XCTAssertTrue(store.alertMessage?.contains("was reset") == true)
    }

    func testResetJobClearsOnlyManagedSyncedFiles() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let syncedRoot = fixture.right.appendingPathComponent("Synced Files", isDirectory: true)
        let processedRoot = fixture.right.appendingPathComponent("Processed Files", isDirectory: true)
        let syncedFiles = [
            syncedRoot.appendingPathComponent("incoming/JAD_0001.jpg"),
            syncedRoot.appendingPathComponent("incoming/JAD_0002.xmp"),
        ]
        let processedFile = processedRoot.appendingPathComponent("Jane/incoming/JAD_0001.jpg")
        let sourceFile = fixture.left.appendingPathComponent("incoming/JAD_0001.jpg")
        for url in syncedFiles + [processedFile, sourceFile] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        var job = try fixture.job(direction: .leftToRight)
        job.processedFilesLocation = .processedSubfolder
        let result = try await JobResetService().resetDownloads(for: job)

        XCTAssertEqual(result.deletedFiles, 2)
        XCTAssertEqual(result.downloadFolderPath, syncedRoot.path)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: syncedRoot.path),
            []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: processedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    func testResetJobClearsEntireOrdinaryDestinationButKeepsFolder() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let downloadedFile = fixture.right.appendingPathComponent("incoming/JAD_0001.jpg")
        let unrelatedFile = fixture.right.appendingPathComponent("notes.txt")
        for url in [downloadedFile, unrelatedFile] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        let job = try fixture.job(direction: .leftToRight)
        let result = try await JobResetService().resetDownloads(for: job)

        XCTAssertEqual(result.deletedFiles, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.right.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.right.path),
            []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.left.path))
    }

    func testResetJobRejectsOverlappingLocalSourceAndDestination() throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let nestedDestination = fixture.left.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDestination, withIntermediateDirectories: true)
        let retainedFile = nestedDestination.appendingPathComponent("keep.jpg")
        try Data("keep".utf8).write(to: retainedFile)
        var job = try fixture.job(direction: .leftToRight)
        job.right = try fixture.endpoint(for: nestedDestination)

        XCTAssertEqual(
            JobResetService.validationMessage(for: job),
            "Reset Job is unavailable because the local source and download folders overlap."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedFile.path))
    }

    func testManagedStructureCreatesSiblingRootsAndSortsProcessedRawByPhotographer() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let relativePath = "incoming/JAD_2600.CR3"
        let source = fixture.left.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawData = Data("managed-structure-camera-data".utf8)
        try rawData.write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)

        let photographer = PhotographerProfile(
            name: "Jane/News: Desk",
            filenamePrefix: "JAD",
            creator: "Jane/News: Desk",
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Managed assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Managed RAW")
            )]
        )
        job.processedFilesLocation = .processedSubfolder
        job.sortsProcessedFilesByPhotographer = true

        let firstResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
        let secondResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(firstResult.processed, 1)
        XCTAssertEqual(secondResult, SyncResult(transferred: 0, deleted: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let syncedRoot = fixture.right.appendingPathComponent("Synced Files")
        let processedRoot = fixture.right
            .appendingPathComponent("Processed Files")
            .appendingPathComponent("Jane News Desk")
        let syncedRaw = syncedRoot.appendingPathComponent(relativePath)
        let syncedSidecar = syncedRoot.appendingPathComponent(
            MetadataWriter.sidecarRelativePath(for: relativePath)
        )
        let processedRaw = processedRoot.appendingPathComponent(relativePath)
        let processedSidecar = processedRoot.appendingPathComponent(
            MetadataWriter.sidecarRelativePath(for: relativePath)
        )

        XCTAssertEqual(try Data(contentsOf: syncedRaw), rawData)
        XCTAssertEqual(try Data(contentsOf: processedRaw), rawData)
        XCTAssertEqual(try XMPSidecar.read(from: syncedSidecar).headline, "Managed RAW")
        XCTAssertEqual(try XMPSidecar.read(from: processedSidecar).headline, "Managed RAW")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.right.appendingPathComponent(relativePath).path
            )
        )
    }

    func testIdenticalProcessedCopiesLetRetryFinishRemovingSource() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let relativePath = "incoming/JAD_RETRY.CR3"
        let source = fixture.left.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawData = Data("retry-after-source-delete-failure".utf8)
        try rawData.write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Retry assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Retry safely")
            )]
        )
        job.processedFilesLocation = .processedSubfolder
        job.sortsProcessedFilesByPhotographer = true

        let firstResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(firstResult.processed, 1)

        let processedRoot = fixture.right
            .appendingPathComponent("Processed Files")
            .appendingPathComponent("Jane Doe")
        let processedRaw = processedRoot.appendingPathComponent(relativePath)
        let processedSidecar = processedRoot.appendingPathComponent(
            MetadataWriter.sidecarRelativePath(for: relativePath)
        )
        let archivedRawData = try Data(contentsOf: processedRaw)
        let archivedSidecarData = try Data(contentsOf: processedSidecar)

        // Simulate an interrupted final cleanup: the processed outputs were
        // published, but the source file is still present for the next pass.
        try rawData.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)

        let retryResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(retryResult.processed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: processedRaw), archivedRawData)
        XCTAssertEqual(try Data(contentsOf: processedSidecar), archivedSidecarData)
    }

    func testManagedStructureReprocessingScansOnlySyncedFiles() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let relativePath = "JAD_REPROCESS.CR3"
        let syncedRoot = fixture.right.appendingPathComponent("Synced Files")
        let processedRoot = fixture.right.appendingPathComponent("Processed Files")
        try FileManager.default.createDirectory(at: syncedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processedRoot, withIntermediateDirectories: true)
        let syncedRaw = syncedRoot.appendingPathComponent(relativePath)
        let processedRaw = processedRoot.appendingPathComponent(relativePath)
        try Data("synced-raw".utf8).write(to: syncedRaw)
        try Data("processed-raw".utf8).write(to: processedRaw)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: syncedRaw.path)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: processedRaw.path)

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Reprocess managed download",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Synced only")
            )]
        )
        job.processedFilesLocation = .processedSubfolder

        let result = try await SyncEngine().reprocessExistingLocalFiles(job: job)

        XCTAssertEqual(result.scanned, 1)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(
            try XMPSidecar.read(
                from: syncedRoot.appendingPathComponent(
                    MetadataWriter.sidecarRelativePath(for: relativePath)
                )
            ).headline,
            "Synced only"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: processedRoot.appendingPathComponent(
                    MetadataWriter.sidecarRelativePath(for: relativePath)
                ).path
            )
        )
    }

    func testSuccessfulMetadataWriteMovesTaggedFileToPerJobProcessedFolder() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("incoming/JAD_0001.jpg")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            existingFieldPolicy: .overwrite,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Processed assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Ready for desk")
            )]
        )
        job.processedFolder = try fixture.endpoint(for: fixture.processed)

        let firstResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
        let secondResult = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(firstResult.processed, 1)
        XCTAssertEqual(firstResult.metadataReport.applied, 1)
        XCTAssertEqual(secondResult, SyncResult(transferred: 0, deleted: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let relativePath = "incoming/JAD_0001.jpg"
        let destination = fixture.right.appendingPathComponent(relativePath)
        let processed = fixture.processed.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: processed.path))
        XCTAssertEqual(try ImageMetadata.read(from: destination).iptc.headline, "Ready for desk")
        XCTAssertEqual(try ImageMetadata.read(from: processed).iptc.headline, "Ready for desk")
    }

    func testMetadataSkipLeavesSourceOutsideProcessedFolder() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let source = fixture.left.appendingPathComponent("JAD_UNSCHEDULED.jpg")
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
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Different day",
                startsAt: timestamp.addingTimeInterval(3_600),
                endsAt: timestamp.addingTimeInterval(7_200)
            )]
        )
        job.processedFolder = try fixture.endpoint(for: fixture.processed)

        let result = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(result.metadataReport.skipped, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.processed.appendingPathComponent(source.lastPathComponent).path
            )
        )
    }

    func testSuccessfulRawMetadataMovesRawAndGeneratedSidecarToProcessedFolder() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let relativePath = "incoming/JAD_0002.CR3"
        let source = fixture.left.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawData = Data("untouched-camera-data".utf8)
        try rawData.write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "RAW assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Processed RAW")
            )]
        )
        job.processedFolder = try fixture.endpoint(for: fixture.processed)

        let result = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result.processed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let processedRaw = fixture.processed.appendingPathComponent(relativePath)
        let processedSidecar = fixture.processed.appendingPathComponent(
            MetadataWriter.sidecarRelativePath(for: relativePath)
        )
        XCTAssertEqual(try Data(contentsOf: processedRaw), rawData)
        XCTAssertEqual(try XMPSidecar.read(from: processedSidecar).headline, "Processed RAW")
        XCTAssertEqual(
            try XMPSidecar.read(
                from: fixture.right.appendingPathComponent(
                    MetadataWriter.sidecarRelativePath(for: relativePath)
                )
            ).headline,
            "Processed RAW"
        )
    }

    func testProcessedSidecarCollisionDoesNotLeavePartialRawCopy() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let relativePath = "incoming/JAD_PARTIAL.CR3"
        let source = fixture.left.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("source-raw".utf8).write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)

        let processedRaw = fixture.processed.appendingPathComponent(relativePath)
        let processedSidecar = fixture.processed.appendingPathComponent(
            MetadataWriter.sidecarRelativePath(for: relativePath)
        )
        try FileManager.default.createDirectory(
            at: processedSidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingSidecarData = Data("existing-sidecar".utf8)
        try existingSidecarData.write(to: processedSidecar)

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Partial pair collision",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "New metadata")
            )]
        )
        job.processedFolder = try fixture.endpoint(for: fixture.processed)

        do {
            _ = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
            XCTFail("A processed sidecar collision should fail safely")
        } catch let failure as SyncRunFailure {
            XCTAssertTrue(failure.localizedDescription.contains("already contains a file"))
            XCTAssertEqual(failure.partialResult.transferred, 1)
            XCTAssertEqual(failure.partialResult.processed, 0)
            XCTAssertEqual(failure.partialResult.metadataReport.applied, 1)
        } catch {
            XCTFail("Expected a partial sync failure, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: processedRaw.path))
        XCTAssertEqual(try Data(contentsOf: processedSidecar), existingSidecarData)
    }

    func testRawFilesWithSameStemAreRejectedBeforeAnyOutputIsWritten() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let relativePaths = ["incoming/JAD_0099.CR3", "incoming/JAD_0099.DNG"]
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for relativePath in relativePaths {
            let source = fixture.left.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(relativePath.utf8).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        }

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Conflicting RAW sidecars",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Must not overwrite")
            )]
        )
        job.processedFolder = try fixture.endpoint(for: fixture.processed)

        do {
            _ = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
            XCTFail("RAW files that generate the same sidecar should be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("would both write"))
        }

        for relativePath in relativePaths {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.left.appendingPathComponent(relativePath).path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.right.appendingPathComponent(relativePath).path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.processed.appendingPathComponent(relativePath).path
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.right.appendingPathComponent("incoming/JAD_0099.xmp").path
            )
        )
    }

    func testProcessedFolderCollisionNeverOverwritesOrRemovesSource() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let filename = "JAD_COLLISION.jpg"
        let source = fixture.left.appendingPathComponent(filename)
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
        let existingProcessedData = Data("keep existing processed file".utf8)
        let processed = fixture.processed.appendingPathComponent(filename)
        try existingProcessedData.write(to: processed)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Collision assignment",
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60),
                fields: ScheduledMetadataFields(headline: "Do not archive over existing")
            )]
        )
        job.processedFolder = try fixture.endpoint(for: fixture.processed)

        do {
            _ = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)
            XCTFail("A processed-folder filename collision should fail safely")
        } catch let failure as SyncRunFailure {
            XCTAssertTrue(failure.localizedDescription.contains("already contains a file"))
            XCTAssertEqual(failure.partialResult.transferred, 1)
            XCTAssertEqual(failure.partialResult.processed, 0)
            XCTAssertEqual(failure.partialResult.metadataReport.applied, 1)
        } catch {
            XCTFail("Expected a partial sync failure, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: processed), existingProcessedData)
    }

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

        XCTAssertEqual(firstResult.transferred, 1)
        XCTAssertEqual(firstResult.deleted, 0)
        XCTAssertEqual(firstResult.metadataReport.applied, 1)
        XCTAssertEqual(firstResult.metadataReport.skipped, 0)
        XCTAssertEqual(firstResult.metadataReport.failed, 0)
        XCTAssertEqual(firstResult.metadataReport.entries.first?.photographerName, "Jane Doe")
        XCTAssertEqual(firstResult.metadataReport.entries.first?.clipName, "Political conference")
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

        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.metadataReport.applied, 1)
        XCTAssertEqual(result.metadataReport.entries.first?.timestampPolicy, .localArrival)
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

        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.metadataReport.applied, 1)
        XCTAssertEqual(result.metadataReport.entries.first?.timestampPolicy, .cameraCapture)
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

    func testOneWaySyncWritesXMPCompanionsForDNGAndCR3WithoutChangingRawData() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceFiles = [
            fixture.left.appendingPathComponent("selects/JAD_0001.DNG"),
            fixture.left.appendingPathComponent("selects/JAD_0002.CR3"),
        ]
        for (index, source) in sourceFiles.enumerated() {
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("untouched-camera-data-\(index)".utf8).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        }
        var existingXMP = XMPData()
        existingXMP.city = "Bergen"
        try XMPSidecar.write(
            existingXMP,
            to: sourceFiles[0].deletingPathExtension().appendingPathExtension("xmp")
        )

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "© Example News"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Political conference",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60),
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

        XCTAssertEqual(firstResult.transferred, 2)
        XCTAssertEqual(firstResult.deleted, 0)
        XCTAssertEqual(firstResult.metadataReport.applied, 2)
        XCTAssertEqual(firstResult.metadataReport.failed, 0)
        XCTAssertEqual(secondResult, SyncResult(transferred: 0, deleted: 0))
        for source in sourceFiles {
            let relativePath = "selects/\(source.lastPathComponent)"
            let destination = fixture.right.appendingPathComponent(relativePath)
            XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))

            let sidecar = fixture.right.appendingPathComponent(
                MetadataWriter.sidecarRelativePath(for: relativePath)
            )
            let xmp = try XMPSidecar.read(from: sidecar)
            XCTAssertEqual(xmp.headline, "Political conference")
            XCTAssertEqual(xmp.description, "Delegates gather in Oslo.")
            XCTAssertEqual(xmp.subject, ["politics", "Oslo"])
            XCTAssertEqual(xmp.creator, ["Jane Doe"])
            XCTAssertEqual(xmp.rights, "© Example News")
            if source == sourceFiles[0] {
                XCTAssertEqual(xmp.city, "Bergen")
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            XCTAssertEqual(
                (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                timestamp.timeIntervalSince1970,
                accuracy: 1
            )
        }
    }

    func testAllFilesFilterTreatsExistingXMPAsRawCompanion() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let relativePath = "selects/JAD_COMPANION.CR3"
        let source = fixture.left.appendingPathComponent(relativePath)
        let sourceSidecar = fixture.left.appendingPathComponent(
            MetadataWriter.sidecarRelativePath(for: relativePath)
        )
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawData = Data("raw-with-existing-companion".utf8)
        try rawData.write(to: source)
        var existingXMP = XMPData()
        existingXMP.city = "Bergen"
        try XMPSidecar.write(existingXMP, to: sourceSidecar)

        var job = try fixture.job(direction: .leftToRight)
        job.filter = FileFilter(preset: .all)

        let result = try await SyncEngine().run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result, SyncResult(transferred: 1, deleted: 0))
        XCTAssertEqual(
            try Data(contentsOf: fixture.right.appendingPathComponent(relativePath)),
            rawData
        )
        XCTAssertEqual(
            try XMPSidecar.read(
                from: fixture.right.appendingPathComponent(
                    MetadataWriter.sidecarRelativePath(for: relativePath)
                )
            ).city,
            "Bergen"
        )
    }

    func testEveryCameraRawFilterExtensionUsesXMPSidecars() throws {
        let rawExtensions = try XCTUnwrap(FilterPreset.raw.extensions)

        for fileExtension in rawExtensions {
            let relativePath = "incoming/JAD_0001.\(fileExtension.uppercased())"
            XCTAssertTrue(
                MetadataWriter.usesXMPSidecar(for: relativePath),
                "Expected .\(fileExtension) to use an XMP sidecar"
            )
            XCTAssertEqual(
                MetadataWriter.sidecarRelativePath(for: relativePath),
                "incoming/JAD_0001.xmp"
            )
        }
        XCTAssertFalse(MetadataWriter.usesXMPSidecar(for: "incoming/JAD_0001.jpg"))
    }

    func testReprocessExistingLocalJPEGAppliesMetadataAndPreservesModificationDate() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let destination = fixture.right.appendingPathComponent("archive/JAD_EXISTING.jpg")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
        try jpeg.write(to: destination)
        let source = fixture.left.appendingPathComponent("archive/JAD_EXISTING.jpg")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jpeg.write(to: source)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let shiftedDestinationTimestamp = timestamp.addingTimeInterval(-2 * 3_600)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        try FileManager.default.setAttributes(
            [.modificationDate: shiftedDestinationTimestamp],
            ofItemAtPath: destination.path
        )

        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "© Example News"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Archive assignment",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(
                headline: "Reprocessed headline",
                description: "Existing local file.",
                keywords: ["archive"]
            )
        )
        var job = try fixture.job(direction: .leftToRight)
        job.filter.recentHours = 1
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            existingFieldPolicy: .overwrite,
            photographers: [photographer],
            clips: [clip]
        )

        let result = try await SyncEngine().reprocessExistingLocalFiles(job: job)

        XCTAssertEqual(result.scanned, 1)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.metadataReport.applied, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let metadata = try ImageMetadata.read(from: destination)
        XCTAssertEqual(metadata.iptc.headline, "Reprocessed headline")
        XCTAssertEqual(metadata.iptc.caption, "Existing local file.")
        XCTAssertEqual(metadata.iptc.keywords, ["archive"])
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(
            (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            shiftedDestinationTimestamp.timeIntervalSince1970,
            accuracy: 1
        )

        let secondResult = try await SyncEngine().reprocessExistingLocalFiles(job: job)
        XCTAssertEqual(secondResult.scanned, 1)
        XCTAssertEqual(secondResult.applied, 0)
        XCTAssertEqual(secondResult.skipped, 1)
        XCTAssertEqual(secondResult.failed, 0)
        XCTAssertTrue(
            secondResult.metadataReport.entries.first?.detail?.contains("already applied") == true
        )
    }

    func testReprocessExistingRawCreatesSidecarWithoutRewritingRaw() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let destination = fixture.right.appendingPathComponent("JAD_EXISTING.CR3")
        let original = Data("existing-camera-data".utf8)
        try original.write(to: destination)
        var existingXMP = XMPData()
        existingXMP.description = "Existing description"
        try XMPSidecar.write(
            existingXMP,
            to: destination.deletingPathExtension().appendingPathExtension("xmp")
        )
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: destination.path)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "RAW assignment",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "RAW headline")
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [clip]
        )

        let result = try await SyncEngine().reprocessExistingLocalFiles(job: job)

        XCTAssertEqual(result.scanned, 1)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.metadataReport.applied, 1)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let xmp = try XMPSidecar.read(from: fixture.right.appendingPathComponent("JAD_EXISTING.xmp"))
        XCTAssertEqual(xmp.headline, "RAW headline")
        XCTAssertEqual(xmp.description, "Existing description")
        XCTAssertEqual(xmp.creator, ["Jane Doe"])
    }

    func testReprocessCanTargetOnePhotographerOrOneClip() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let firstTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let secondTimestamp = firstTimestamp.addingTimeInterval(3_600)
        let files: [(name: String, timestamp: Date)] = [
            ("JAD_FIRST.CR3", firstTimestamp),
            ("JAD_SECOND.CR3", secondTimestamp),
            ("SAM_FIRST.CR3", firstTimestamp)
        ]
        for file in files {
            let url = fixture.right.appendingPathComponent(file.name)
            try Data("camera-data-\(file.name)".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: file.timestamp],
                ofItemAtPath: url.path
            )
        }

        let jane = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        let sam = PhotographerProfile(
            name: "Sam Example",
            filenamePrefix: "SAM",
            creator: "Sam Example",
            copyrightNotice: ""
        )
        let janeFirstClip = MetadataScheduleClip(
            photographerID: jane.id,
            name: "Jane first assignment",
            startsAt: firstTimestamp.addingTimeInterval(-60),
            endsAt: firstTimestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "Jane first")
        )
        let janeSecondClip = MetadataScheduleClip(
            photographerID: jane.id,
            name: "Jane second assignment",
            startsAt: secondTimestamp.addingTimeInterval(-60),
            endsAt: secondTimestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "Jane second")
        )
        let samClip = MetadataScheduleClip(
            photographerID: sam.id,
            name: "Sam assignment",
            startsAt: firstTimestamp.addingTimeInterval(-60),
            endsAt: firstTimestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "Sam first")
        )
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .sourceModification,
            photographers: [jane, sam],
            clips: [janeFirstClip, janeSecondClip, samClip]
        )

        let photographerResult = try await SyncEngine().reprocessExistingLocalFiles(
            job: job,
            scope: .photographer(sam.id)
        )

        XCTAssertEqual(photographerResult.scanned, 1)
        XCTAssertEqual(photographerResult.applied, 1)
        XCTAssertEqual(
            try XMPSidecar.read(from: fixture.right.appendingPathComponent("SAM_FIRST.xmp")).headline,
            "Sam first"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.right.appendingPathComponent("JAD_FIRST.xmp").path))

        let clipResult = try await SyncEngine().reprocessExistingLocalFiles(
            job: job,
            scope: .clip(janeFirstClip.id)
        )

        XCTAssertEqual(clipResult.scanned, 1)
        XCTAssertEqual(clipResult.applied, 1)
        XCTAssertEqual(
            try XMPSidecar.read(from: fixture.right.appendingPathComponent("JAD_FIRST.xmp")).headline,
            "Jane first"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.right.appendingPathComponent("JAD_SECOND.xmp").path))
    }

    func testReprocessRejectsLocalArrivalPolicy() async throws {
        let fixture = try LocalFixture()
        defer { fixture.cleanUp() }
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "",
            copyrightNotice: ""
        )
        let now = Date()
        var job = try fixture.job(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            timestampPolicy: .localArrival,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Arrival",
                startsAt: now.addingTimeInterval(-60),
                endsAt: now.addingTimeInterval(60)
            )]
        )

        do {
            _ = try await SyncEngine().reprocessExistingLocalFiles(job: job)
            XCTFail("Local-arrival reprocessing should be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("arrival times were not recorded"))
        }
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
    let processed: URL
    let outside: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AagedalSyncTests-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        processed = root.appendingPathComponent("processed")
        outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func job(direction: SyncDirection) throws -> SyncJob {
        let leftEndpoint = try endpoint(for: left)
        let rightEndpoint = try endpoint(for: right)
        var job = SyncJob(
            name: "Test",
            left: leftEndpoint,
            right: rightEndpoint,
            direction: direction,
            filter: FileFilter(preset: .photos),
            intervalSeconds: 5,
            isEnabled: false
        )
        job.startsOnAppLaunch = false
        return job
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func endpoint(for url: URL) throws -> Endpoint {
        let bookmark = try FolderBookmark.create(for: url)
        return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
    }
}
