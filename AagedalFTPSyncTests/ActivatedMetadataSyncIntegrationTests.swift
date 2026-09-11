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
    private func engine(_ f: Fixture) -> SyncEngine {
        SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: f.root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: f.root.appendingPathComponent("manifest.json")),
            now: { Date(timeIntervalSince1970: 1_704_153_600) })
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
