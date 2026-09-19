import AppKit
import Foundation
import MetadataTemplates
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class ActivatedMetadataSyncIntegrationTests: XCTestCase {
    private struct Fixture { let root: URL; let source: URL; let destination: URL; let job: SyncJob }
    private func fixture(headline: String = "{date:YYYY-MM-DD}") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("active-sync-\(UUID())")
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func endpoint(_ url: URL) throws -> Endpoint {
            let bookmark = try FolderBookmark.create(for: url)
            return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
        }
        var job = try SyncJob(name: "Active fixture", left: endpoint(source), right: endpoint(destination),
            direction: .leftToRight, filter: FileFilter(preset: .photos), intervalSeconds: 5, isEnabled: false)
        job.startsOnAppLaunch = false
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "")
        var fields = ScheduledMetadataFields(); fields.setHeadline(try .activated(headline))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        job.metadataAutomation = MetadataAutomation(isEnabled: true, timestampPolicy: .sourceModification,
            existingFieldPolicy: .init(overwriteFields: []), photographers: [profile],
            clips: [MetadataScheduleClip(photographerID: profile.id, name: "Fixture", startsAt: date.addingTimeInterval(-60),
                endsAt: date.addingTimeInterval(60), fields: fields)])
        return Fixture(root: root, source: source, destination: destination, job: job)
    }
    private func jpeg() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 100, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }
    private func write(_ data: Data, name: String, root: URL) throws {
        let file = root.appendingPathComponent(name)
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
    }
    private func engine(
        _ f: Fixture,
        faceRecognitionContext: MetadataFaceRecognitionContext? = nil
    ) -> SyncEngine {
        SyncEngine(faceRecognitionContext: faceRecognitionContext,
            sourceSignatureRepository: SourceSignatureRepository(fileURL: f.root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: f.root.appendingPathComponent("manifest.json")),
            now: { Date(timeIntervalSince1970: 1_704_153_600) })
    }

    private func faceContext(
        name: String,
        libraryRevision: Character = "a"
    ) throws -> MetadataFaceRecognitionContext {
        var values = [Float](repeating: 0, count: FaceRecognitionEmbedding.dimension)
        values[0] = 1
        let embedding = try FaceRecognitionEmbedding(validatingNormalized: values)
        let gallery = try FaceRecognitionGallery(people: [
            try FaceRecognitionPerson(id: UUID(), name: name, examples: [embedding]),
        ])
        let service = FaceRecognitionAnalysisService { _, _ in
            [.init(ordinal: 0, embedding: embedding, captureQuality: 1)]
        }
        let policy = try FaceRecognitionAcceptancePolicy(
            maximumCosineDistance: 0.5,
            minimumRunnerUpGap: 0.1,
            minimumCaptureQuality: 0.5,
            unavailableQualityPolicy: .reject
        )
        return try MetadataFaceRecognitionContext(
            service: service,
            gallery: gallery,
            libraryRevision: String(repeating: libraryRevision, count: 64),
            runtimeRevision: String(repeating: "b", count: 64),
            acceptancePolicy: policy
        )
    }

    func testActiveMissingProcessingZoneFailsBeforeOpeningAnyEndpoint() async throws {
        let f = try fixture()
        var job = f.job
        job.metadataProcessingTimeZoneIdentifier = nil
        let engine = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: f.root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: f.root.appendingPathComponent("manifest.json")),
            sessionFactory: { _, _, _ in
                XCTFail("Missing persisted processing zone must be rejected before opening endpoints")
                throw CancellationError()
            })
        do {
            _ = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTFail("Active jobs require an explicitly persisted processing zone")
        } catch let error as MetadataTemplateRecordError {
            XCTAssertEqual(error, .invalidSource)
        } catch { XCTFail("Expected missing-context validation, got \(error)") }
    }

    func testTransferResolutionFailureCopiesOriginalAndContinuesNextImage() async throws {
        let f = try fixture()
        let invalid = Data("not a JPEG".utf8)
        try write(invalid, name: "FX_BAD.jpg", root: f.source)
        try write(jpeg(), name: "FX_GOOD.jpg", root: f.source)
        let result = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(result.transferred, 2)
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("FX_BAD.jpg")), invalid)
        XCTAssertEqual(try ImageMetadata.read(from: f.destination.appendingPathComponent("FX_GOOD.jpg")).iptc.headline, "2024-01-02")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("FX_BAD.jpg").path))
        let successfulEntry = try XCTUnwrap(result.metadataReport.entries.first {
            $0.relativePath == "FX_GOOD.jpg" && $0.status == .applied
        })
        XCTAssertNotNil(successfulEntry.processingFingerprint)
        XCTAssertNil(result.metadataReport.entries.first {
            $0.relativePath == "FX_BAD.jpg"
        }?.processingFingerprint)
    }

    func testAlreadyAppliedReprocessBootstrapsCompleteFingerprintFromDurableSourceEvidence() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_READY.jpg", root: f.source)
        _ = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
        let target = f.destination.appendingPathComponent("FX_READY.jpg")
        let before = try FileManager.default.attributesOfItem(atPath: target.path)

        let result = try await engine(f).reprocessExistingLocalFiles(job: f.job)

        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.skipped, 1)
        let entry = try XCTUnwrap(result.metadataReport.entries.first)
        XCTAssertEqual(entry.status, .skipped)
        XCTAssertNotNil(entry.processingFingerprint)
        XCTAssertTrue(entry.detail?.contains("bootstrapped from durable source evidence") == true)
        let after = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
    }

    func testAlreadyAppliedLegacyDestinationWithoutDurableSourceEvidenceRemainsIncomplete() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_UNOWNED.jpg", root: f.source)
        _ = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
        let target = f.destination.appendingPathComponent("FX_UNOWNED.jpg")
        let before = try FileManager.default.attributesOfItem(atPath: target.path)
        let emptyEvidenceEngine = SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(
                fileURL: f.root.appendingPathComponent("empty-signatures.sqlite")
            ),
            downloadManifestRepository: DownloadManifestRepository(
                fileURL: f.root.appendingPathComponent("empty-manifest.json")
            ),
            now: { Date(timeIntervalSince1970: 1_704_153_600) }
        )

        let result = try await emptyEvidenceEngine.reprocessExistingLocalFiles(
            job: f.job, filter: .staleOrIncomplete
        )

        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 1)
        let entry = try XCTUnwrap(result.metadataReport.entries.first)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertNil(entry.processingFingerprint)
        XCTAssertTrue(entry.detail?.contains("no durable source receipt") == true)
        let after = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testReceiptFilteredReprocessSkipsCurrentOutputWithoutRewriting() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_CURRENT.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let target = f.destination.appendingPathComponent("FX_CURRENT.jpg")
        let before = try FileManager.default.attributesOfItem(atPath: target.path)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })

        let result = try await engine.reprocessExistingLocalFiles(
            job: f.job, filter: .staleOrIncomplete, latestOutcomes: latest
        )

        XCTAssertEqual(result, MetadataReprocessResult(
            scanned: 1, applied: 0, skipped: 1,
            metadataReport: result.metadataReport
        ))
        XCTAssertTrue(result.metadataReport.entries[0].detail?.contains("receipt is current") == true)
        XCTAssertEqual(result.metadataReport.entries[0].processingFingerprint,
                       transfer.metadataReport.entries[0].processingFingerprint)
        let after = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testReceiptFilteredReprocessAppliesSettingsChange() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_STALE.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })
        var changedJob = f.job
        var automation = try XCTUnwrap(changedJob.metadataAutomation)
        automation.existingFieldPolicy = .init(overwriteFields: [.headline])
        automation.clips[0].fields.setHeadline(try .activated("Updated"))
        changedJob.metadataAutomation = automation

        let result = try await engine.reprocessExistingLocalFiles(
            job: changedJob, filter: .staleOrIncomplete, latestOutcomes: latest
        )

        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(try ImageMetadata.read(
            from: f.destination.appendingPathComponent("FX_STALE.jpg")
        ).iptc.headline, "Updated")
        XCTAssertNotEqual(result.metadataReport.entries[0].processingFingerprint?.settingsRevision,
                          transfer.metadataReport.entries[0].processingFingerprint?.settingsRevision)
    }

    func testAdmittedRecognitionWritesNamesAndDurableEvidenceDuringTransfer() async throws {
        let f = try fixture(headline: "People: {persons}")
        try write(jpeg(), name: "FX_FACE.jpg", root: f.source)
        var job = f.job
        job.metadataFaceRecognition = .init(appendToKeywords: true)
        let result = try await engine(
            f,
            faceRecognitionContext: faceContext(name: "Alice Example")
        ).run(job: job, leftPassword: nil, rightPassword: nil)

        XCTAssertEqual(result.transferred, 1)
        let target = f.destination.appendingPathComponent("FX_FACE.jpg")
        let metadata = try ImageMetadata.read(from: target)
        XCTAssertEqual(metadata.iptc.headline, "People: Alice Example")
        XCTAssertEqual(metadata.xmp?.personInImage, ["Alice Example"])
        XCTAssertTrue(metadata.iptc.keywords.contains("Alice Example"))
        let entry = try XCTUnwrap(result.metadataReport.entries.first)
        XCTAssertEqual(entry.recognitionEvidence?.status, .completed)
        XCTAssertEqual(entry.recognitionEvidence?.outcomes?.accepted, 1)
        XCTAssertNotNil(entry.processingFingerprint)
    }

    func testChangedPeopleLibraryMakesReceiptStaleAndAddsNewAcceptedName() async throws {
        let f = try fixture(headline: "People: {persons}")
        try write(jpeg(), name: "FX_LIBRARY.jpg", root: f.source)
        var job = f.job
        job.metadataFaceRecognition = .init()
        let firstEngine = engine(
            f,
            faceRecognitionContext: try faceContext(name: "Alice Example", libraryRevision: "a")
        )
        let transfer = try await firstEngine.run(job: job, leftPassword: nil, rightPassword: nil)
        let firstEntry = try XCTUnwrap(transfer.metadataReport.entries.first)

        let secondEngine = engine(
            f,
            faceRecognitionContext: try faceContext(name: "Bob Example", libraryRevision: "c")
        )
        let result = try await secondEngine.reprocessExistingLocalFiles(
            job: job,
            filter: .staleOrIncomplete,
            latestOutcomes: ["FX_LIBRARY.jpg": firstEntry]
        )

        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.conflicts, [])
        let metadata = try ImageMetadata.read(
            from: f.destination.appendingPathComponent("FX_LIBRARY.jpg")
        )
        XCTAssertEqual(metadata.xmp?.personInImage, ["Alice Example", "Bob Example"])
        let secondEntry = try XCTUnwrap(result.metadataReport.entries.first)
        XCTAssertNotEqual(
            secondEntry.processingFingerprint?.dependencyRevision,
            firstEntry.processingFingerprint?.dependencyRevision
        )
        XCTAssertEqual(secondEntry.recognitionEvidence?.outcomes?.accepted, 1)
    }

    func testFaceOnlyReprocessingSupportsPreflightReceiptsAndIdleRepeat() async throws {
        let f = try fixture()
        let name = "INDEPENDENT.jpg"
        try write(jpeg(), name: name, root: f.destination)
        let target = f.destination.appendingPathComponent(name)
        let before = try Data(contentsOf: target)
        let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var job = f.job
        job.metadataAutomation = nil
        job.metadataGeocoding = nil
        job.metadataFaceRecognition = .init(appendToKeywords: true)
        let engine = engine(f, faceRecognitionContext: try faceContext(name: "Alice Example"))

        let preflight = try await engine.reprocessExistingLocalFiles(job: job, isPreflight: true)
        XCTAssertEqual(preflight.applied, 1)
        XCTAssertEqual(try Data(contentsOf: target), before)

        let result = try await engine.reprocessExistingLocalFiles(job: job)
        XCTAssertEqual(result.applied, 1)
        let metadata = try ImageMetadata.read(from: target)
        XCTAssertEqual(metadata.xmp?.personInImage, ["Alice Example"])
        XCTAssertTrue(metadata.iptc.keywords.contains("Alice Example"))
        XCTAssertTrue(metadata.iptc.headline?.isEmpty != false)
        XCTAssertEqual(try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        let entry = try XCTUnwrap(result.metadataReport.entries.first)
        XCTAssertEqual(entry.recognitionEvidence?.status, .completed)
        XCTAssertNotNil(entry.processingFingerprint)

        // A disabled saved schedule must also leave independent recognition usable.
        job.metadataAutomation = f.job.metadataAutomation
        job.metadataAutomation?.isEnabled = false
        let processed = try Data(contentsOf: target)
        let repeatResult = try await engine.reprocessExistingLocalFiles(
            job: job, filter: .staleOrIncomplete, latestOutcomes: [name: entry]
        )
        XCTAssertEqual(repeatResult.applied, 0)
        XCTAssertEqual(repeatResult.failed, 0)
        XCTAssertEqual(repeatResult.metadataReport.entries.first?.status, .skipped)
        XCTAssertNotNil(repeatResult.metadataReport.entries.first?.processingFingerprint)
        XCTAssertEqual(try Data(contentsOf: target), processed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.source.path).isEmpty)
    }

    func testReceiptProtectedOutputEditIsReportedAndPreserved() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_EDITED.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })
        let target = f.destination.appendingPathComponent("FX_EDITED.jpg")
        let edit = Data("external destination edit".utf8)
        try edit.write(to: target)
        var changedJob = f.job
        var automation = try XCTUnwrap(changedJob.metadataAutomation)
        automation.existingFieldPolicy = .init(overwriteFields: [.headline])
        automation.clips[0].fields.setHeadline(try .activated("New settings must not win"))
        changedJob.metadataAutomation = automation

        let result = try await engine.reprocessExistingLocalFiles(
            job: changedJob, filter: .all, latestOutcomes: latest
        )

        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.conflicts, ["FX_EDITED.jpg"])
        XCTAssertEqual(try Data(contentsOf: target), edit)
        XCTAssertTrue(result.metadataReport.entries[0].detail?.contains("manual review") == true)
        XCTAssertEqual(result.metadataReport.entries[0].processingFingerprint,
                       transfer.metadataReport.entries[0].processingFingerprint)
    }

    func testReprocessPreflightCountsChangesWithoutPublishingThem() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_PREFLIGHT.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })
        let target = f.destination.appendingPathComponent("FX_PREFLIGHT.jpg")
        let before = try Data(contentsOf: target)
        var changedJob = f.job
        var automation = try XCTUnwrap(changedJob.metadataAutomation)
        automation.existingFieldPolicy = .init(overwriteFields: [.headline])
        automation.clips[0].fields.setHeadline(try .activated("Ready after confirmation"))
        changedJob.metadataAutomation = automation

        let result = try await engine.preflightExistingLocalFiles(
            job: changedJob, filter: .staleOrIncomplete, latestOutcomes: latest
        )

        XCTAssertEqual(result, MetadataReprocessPreflight(
            scanned: 1, ready: 1, skipped: 0, failed: 0, conflicts: []
        ))
        XCTAssertEqual(try Data(contentsOf: target), before)
        XCTAssertEqual(try ImageMetadata.read(from: target).iptc.headline, "2024-01-02")
    }

    func testReprocessPreflightReportsEditedOutputAndExplicitReplacementApplies() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_REPLACE.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })
        let target = f.destination.appendingPathComponent("FX_REPLACE.jpg")
        try jpeg().write(to: target)
        var changedJob = f.job
        var automation = try XCTUnwrap(changedJob.metadataAutomation)
        automation.existingFieldPolicy = .init(overwriteFields: [.headline])
        automation.clips[0].fields.setHeadline(try .activated("Explicit replacement"))
        changedJob.metadataAutomation = automation

        let preflight = try await engine.preflightExistingLocalFiles(
            job: changedJob, filter: .staleOrIncomplete, latestOutcomes: latest
        )
        XCTAssertEqual(preflight.conflicts, ["FX_REPLACE.jpg"])
        XCTAssertEqual(preflight.ready, 0)

        let result = try await engine.reprocessExistingLocalFiles(
            job: changedJob,
            filter: .staleOrIncomplete,
            conflictPolicy: .processEditedOutputs(preflight.conflictOutputRevisions),
            latestOutcomes: latest
        )

        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(try ImageMetadata.read(from: target).iptc.headline, "Explicit replacement")
    }

    func testConflictApprovalDoesNotIncludeOutputsEditedAfterPreflight() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_APPROVED.jpg", root: f.source)
        try write(jpeg(), name: "FX_LATE.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })
        let approvedTarget = f.destination.appendingPathComponent("FX_APPROVED.jpg")
        let lateTarget = f.destination.appendingPathComponent("FX_LATE.jpg")
        try jpeg().write(to: approvedTarget)
        var changedJob = f.job
        var automation = try XCTUnwrap(changedJob.metadataAutomation)
        automation.existingFieldPolicy = .init(overwriteFields: [.headline])
        automation.clips[0].fields.setHeadline(try .activated("Approved settings"))
        changedJob.metadataAutomation = automation

        let preflight = try await engine.preflightExistingLocalFiles(
            job: changedJob, filter: .staleOrIncomplete, latestOutcomes: latest
        )
        XCTAssertEqual(preflight.conflicts, ["FX_APPROVED.jpg"])
        let lateEdit = try jpeg()
        try lateEdit.write(to: lateTarget)

        let result = try await engine.reprocessExistingLocalFiles(
            job: changedJob,
            filter: .staleOrIncomplete,
            conflictPolicy: .processEditedOutputs(preflight.conflictOutputRevisions),
            latestOutcomes: latest
        )

        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.conflicts, ["FX_LATE.jpg"])
        XCTAssertEqual(try ImageMetadata.read(from: approvedTarget).iptc.headline, "Approved settings")
        XCTAssertEqual(try Data(contentsOf: lateTarget), lateEdit)
    }

    func testReviewedOutputChangedAgainAfterPreflightIsPreserved() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_REVIEWED.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })
        let target = f.destination.appendingPathComponent("FX_REVIEWED.jpg")
        try jpeg().write(to: target)
        var changedJob = f.job
        var automation = try XCTUnwrap(changedJob.metadataAutomation)
        automation.existingFieldPolicy = .init(overwriteFields: [.headline])
        automation.clips[0].fields.setHeadline(try .activated("Approved settings"))
        changedJob.metadataAutomation = automation

        let preflight = try await engine.preflightExistingLocalFiles(
            job: changedJob, filter: .staleOrIncomplete, latestOutcomes: latest
        )
        XCTAssertEqual(preflight.conflicts, ["FX_REVIEWED.jpg"])
        XCTAssertNotNil(preflight.conflictOutputRevisions["FX_REVIEWED.jpg"])
        let laterEdit = Data("changed again after review".utf8)
        try laterEdit.write(to: target)

        let result = try await engine.reprocessExistingLocalFiles(
            job: changedJob,
            filter: .staleOrIncomplete,
            conflictPolicy: .processEditedOutputs(preflight.conflictOutputRevisions),
            latestOutcomes: latest
        )

        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.conflicts, ["FX_REVIEWED.jpg"])
        XCTAssertEqual(try Data(contentsOf: target), laterEdit)
    }

    func testChangedSourceIsReprocessedInsteadOfMisclassifiedAsOutputEdit() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_RESEND.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let latest = Dictionary(uniqueKeysWithValues: transfer.metadataReport.entries.map { ($0.relativePath, $0) })
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)],
            ofItemAtPath: f.source.appendingPathComponent("FX_RESEND.jpg").path
        )

        let result = try await engine.reprocessExistingLocalFiles(
            job: f.job, filter: .staleOrIncomplete, latestOutcomes: latest
        )

        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.skipped, 1)
        XCTAssertNotEqual(result.metadataReport.entries[0].processingFingerprint?.sourceRevision,
                          transfer.metadataReport.entries[0].processingFingerprint?.sourceRevision)
    }

    func testChangedSourceAndEditedDestinationRemainAConflict() async throws {
        let f = try fixture()
        try write(jpeg(), name: "FX_BOTH.jpg", root: f.source)
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let previousEntry = try XCTUnwrap(transfer.metadataReport.entries.first)
        let target = f.destination.appendingPathComponent("FX_BOTH.jpg")
        let destinationEdit = Data("external destination edit".utf8)
        try destinationEdit.write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)],
            ofItemAtPath: f.source.appendingPathComponent("FX_BOTH.jpg").path
        )
        var changedJob = f.job
        var automation = try XCTUnwrap(changedJob.metadataAutomation)
        automation.existingFieldPolicy = .init(overwriteFields: [.headline])
        automation.clips[0].fields.setHeadline(try .activated("New source and settings"))
        changedJob.metadataAutomation = automation

        let preflight = try await engine.preflightExistingLocalFiles(
            job: changedJob, filter: .staleOrIncomplete,
            latestOutcomes: ["FX_BOTH.jpg": previousEntry]
        )
        XCTAssertEqual(preflight.conflicts, ["FX_BOTH.jpg"])
        XCTAssertEqual(preflight.ready, 0)
        XCTAssertEqual(try Data(contentsOf: target), destinationEdit)

        let result = try await engine.reprocessExistingLocalFiles(
            job: changedJob, filter: .staleOrIncomplete,
            latestOutcomes: ["FX_BOTH.jpg": previousEntry]
        )
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.conflicts, ["FX_BOTH.jpg"])
        XCTAssertEqual(result.metadataReport.entries.first?.processingFingerprint,
                       previousEntry.processingFingerprint)
        XCTAssertEqual(try Data(contentsOf: target), destinationEdit)
    }

    func testRemovedSourceSidecarMakesReceiptStaleInsteadOfReusingSavedCompanionEvidence() async throws {
        let f = try fixture()
        try write(Data("synthetic RAW".utf8), name: "FX_REMOVED.cr3", root: f.source)
        let sourceSidecar = f.source.appendingPathComponent("FX_REMOVED.xmp")
        try XMPSidecar.write(XMPData(), to: sourceSidecar)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: sourceSidecar.path
        )
        let engine = engine(f)
        let transfer = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        let previousEntry = try XCTUnwrap(transfer.metadataReport.entries.first)
        try FileManager.default.removeItem(at: sourceSidecar)

        let result = try await engine.reprocessExistingLocalFiles(
            job: f.job,
            filter: .staleOrIncomplete,
            latestOutcomes: ["FX_REMOVED.cr3": previousEntry]
        )

        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertNotEqual(
            result.metadataReport.entries.first?.processingFingerprint?.sourceRevision,
            previousEntry.processingFingerprint?.sourceRevision
        )
        XCTAssertEqual(
            try XMPSidecar.read(from: f.destination.appendingPathComponent("FX_REMOVED.xmp")).headline,
            "2024-01-02"
        )
    }

    func testReprocessResolutionFailureIsPerFileAndOtherFilePublishes() async throws {
        let f = try fixture()
        for root in [f.source, f.destination] {
            try write(Data("not a JPEG".utf8), name: "FX_BAD.jpg", root: root)
            try write(jpeg(), name: "FX_GOOD.jpg", root: root)
        }
        let result = try await engine(f).reprocessExistingLocalFiles(job: f.job)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("FX_BAD.jpg")), Data("not a JPEG".utf8))
        XCTAssertEqual(try ImageMetadata.read(from: f.destination.appendingPathComponent("FX_GOOD.jpg")).iptc.headline, "2024-01-02")
        let successfulEntry = try XCTUnwrap(result.metadataReport.entries.first {
            $0.relativePath == "FX_GOOD.jpg" && $0.status == .applied
        })
        let fingerprint = try XCTUnwrap(successfulEntry.processingFingerprint)
        XCTAssertEqual(fingerprint.sourceRevision.utf8.count, 64)
        XCTAssertEqual(fingerprint.settingsRevision.utf8.count, 64)
        XCTAssertEqual(fingerprint.dependencyRevision.utf8.count, 64)
        XCTAssertEqual(fingerprint.outputRevision.utf8.count, 64)
        XCTAssertNil(result.metadataReport.entries.first {
            $0.relativePath == "FX_BAD.jpg"
        }?.processingFingerprint)
    }

    func testUnresolvedRawWithPreservedCreatorDoesNotRewriteExistingSidecar() async throws {
        let f = try fixture(headline: "{gps:city}")
        for root in [f.source, f.destination] {
            try write(Data("synthetic RAW".utf8), name: "FX_RAW.cr3", root: root)
            let sidecar = root.appendingPathComponent("FX_RAW.xmp")
            var xmp = XMPData(); xmp.creator = ["Existing creator"]
            try XMPSidecar.write(xmp, to: sidecar)
        }
        let sidecar = f.destination.appendingPathComponent("FX_RAW.xmp")
        let before = try Data(contentsOf: sidecar)
        let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.path)
        let result = try await engine(f).reprocessExistingLocalFiles(job: f.job)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.applied, 0)
        XCTAssertNil(result.metadataReport.entries.first?.processingFingerprint)
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.systemFileNumber] as? NSNumber,
                       attributes[.systemFileNumber] as? NSNumber)
    }

    func testActiveRawReprocessCreatesSidecarWithoutReplacingOriginalRawInode() async throws {
        let f = try fixture()
        for root in [f.source, f.destination] { try write(Data("synthetic RAW".utf8), name: "FX_RAW.cr3", root: root) }
        let raw = f.destination.appendingPathComponent("FX_RAW.cr3")
        let before = try FileManager.default.attributesOfItem(atPath: raw.path)
        let result = try await engine(f).reprocessExistingLocalFiles(job: f.job)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(try XMPSidecar.read(from: f.destination.appendingPathComponent("FX_RAW.xmp")).headline, "2024-01-02")
        let after = try FileManager.default.attributesOfItem(atPath: raw.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(try Data(contentsOf: raw), Data("synthetic RAW".utf8))
    }

    func testConcurrentDestinationEditDuringActiveReprocessIsNotOverwritten() async throws {
        let f = try fixture()
        for root in [f.source, f.destination] { try write(jpeg(), name: "FX_EDIT.jpg", root: root) }
        let target = f.destination.appendingPathComponent("FX_EDIT.jpg")
        let hookCalled = expectation(description: "Active reprocess reached held-original transaction phase")
        hookCalled.assertForOverFulfill = true
        let engine = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: f.root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: f.root.appendingPathComponent("manifest.json")),
            now: { Date(timeIntervalSince1970: 1_704_153_600) },
            localReprocessSessionFactory: { endpoint, managed in
                try LocalEndpointSession(endpoint: endpoint, managedFolder: managed, matchingImportHook: { phase in
                    if case .originalsHeld = phase {
                        hookCalled.fulfill()
                        try Data("concurrent edit".utf8).write(to: target)
                    }
                })
            })
        let result = try await engine.reprocessExistingLocalFiles(job: f.job)
        await fulfillment(of: [hookCalled], timeout: 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(try Data(contentsOf: target), Data("concurrent edit".utf8))
    }
}
