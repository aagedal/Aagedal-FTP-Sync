import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataGeocodingSyncIntegrationTests: XCTestCase {
    private struct Fixture { let root: URL; let source: URL; let destination: URL; let processed: URL; var job: SyncJob }
    private func endpoint(_ url: URL) throws -> Endpoint {
        let bookmark = try FolderBookmark.create(for: url)
        return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("geo-sync-\(UUID())")
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        let processed = root.appendingPathComponent("processed")
        for folder in [source, destination, processed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var job = try SyncJob(name: "Standalone geocoding", left: endpoint(source), right: endpoint(destination),
            direction: .leftToRight, filter: FileFilter(preset: .photos), intervalSeconds: 5, isEnabled: false)
        job.startsOnAppLaunch = false
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        job.metadataGeocoding = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en_US")
        return Fixture(root: root, source: source, destination: destination, processed: processed, job: job)
    }
    private func jpeg(at file: URL, gps: Bool = true) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 100, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        if gps {
            var metadata = try ImageMetadata.read(from: file)
            metadata.setGPS(latitude: 59.5, longitude: 10.25)
            try metadata.write(to: file)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
    }
    private func rawPair(at folder: URL, stem: String = "photo") throws -> (URL, URL) {
        let raw = folder.appendingPathComponent(stem + ".cr3"), sidecar = folder.appendingPathComponent(stem + ".xmp")
        try Data("opaque fixture RAW".utf8).write(to: raw)
        var xmp = XMPData(); xmp.exifGPSLatitude = "59,30N"; xmp.exifGPSLongitude = "10,15E"
        xmp.headline = "Keep headline"
        try XMPSidecar.write(xmp, to: sidecar)
        return (raw, sidecar)
    }
    private func engine(_ fixture: Fixture, failure: Bool = false, forbidSourceSessions: Bool = false) -> SyncEngine {
        let service = MetadataGeocodingService(identity: .init(provider: "injected", version: "1", dataset: "fixture")) { _ in
            failure ? .failure(retryAfter: nil) : .found(.init(city: "Oslo", country: "Norway", source: "local fixture", distanceMeters: 25))
        }
        return SyncEngine(geocodingService: service,
            sourceSignatureRepository: SourceSignatureRepository(fileURL: fixture.root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: fixture.root.appendingPathComponent("manifest.json")),
            sessionFactory: { endpoint, password, managed in
                if forbidSourceSessions { XCTFail("Standalone local reprocessing must not open source endpoint sessions"); throw CancellationError() }
                return try EndpointSessionFactory.make(endpoint: endpoint, password: password, managedFolder: managed)
            }, now: { Date(timeIntervalSince1970: 1_704_153_600) })
    }

    func testStandaloneJPEGWritesPlacesRetainsOriginalAndDoesNotTransferAgain() async throws {
        let f = try fixture()
        let source = f.source.appendingPathComponent("photo.jpg")
        try jpeg(at: source)
        let original = try Data(contentsOf: source)
        let engine = engine(f)
        let first = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(first.transferred, 1)
        let metadata = try ImageMetadata.read(from: f.destination.appendingPathComponent("photo.jpg"))
        XCTAssertEqual(metadata.iptc.city, "Oslo")
        XCTAssertEqual(metadata.xmp?.country, "Norway")
        XCTAssertEqual(try Data(contentsOf: source), original)
        let second = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(second.transferred, 0)
    }

    func testOpaqueRAWUsesGPSFromSidecarAndPreservesOriginalPair() async throws {
        let f = try fixture()
        let (raw, sidecar) = try rawPair(at: f.source)
        let originals = try [raw, sidecar].map { try Data(contentsOf: $0) }
        let result = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("photo.cr3")), originals[0])
        let xmp = try XMPSidecar.read(from: f.destination.appendingPathComponent("photo.xmp"))
        XCTAssertEqual(xmp.city, "Oslo")
        XCTAssertEqual(xmp.country, "Norway")
        XCTAssertEqual(xmp.headline, "Keep headline")
        XCTAssertEqual(try [raw, sidecar].map { try Data(contentsOf: $0) }, originals)
    }

    func testMissingGPSOrProviderFailureDeliversOriginalRetainsSourceAndRecordsStableReceipt() async throws {
        for providerFailure in [false, true] {
            var f = try fixture()
            f.job.processedFolder = try endpoint(f.processed)
            let source = f.source.appendingPathComponent("photo.jpg")
            try jpeg(at: source, gps: providerFailure)
            let original = try Data(contentsOf: source)
            let engine = engine(f, failure: providerFailure)
            let first = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(first.transferred, 1)
            XCTAssertEqual(first.processed, 0)
            XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("photo.jpg")), original)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.processed.appendingPathComponent("photo.jpg").path))
            let second = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(second.transferred, 0)
        }
    }

    func testCustomAndManagedProcessedSuccessMovesRAWPairWithoutPhotographerFolder() async throws {
        for managed in [false, true] {
            var f = try fixture()
            if managed { f.job.processedFilesLocation = .processedSubfolder }
            else { f.job.processedFolder = try endpoint(f.processed) }
            f.job.sortsProcessedFilesByPhotographer = true
            let (raw, sidecar) = try rawPair(at: f.source)
            let originalRaw = try Data(contentsOf: raw)
            let result = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(result.processed, 1)
            let destination = managed ? f.destination.appendingPathComponent("Synced Files") : f.destination
            let processed = managed ? f.destination.appendingPathComponent("Processed Files") : f.processed
            for folder in [destination, processed] {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("photo.cr3")), originalRaw)
                XCTAssertEqual(try XMPSidecar.read(from: folder.appendingPathComponent("photo.xmp")).city, "Oslo")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: processed.path)), ["photo.cr3", "photo.xmp"])
        }
    }

    func testStandaloneLocalReprocessingNeverOpensSourceAndPreservesRAWIdentity() async throws {
        let f = try fixture()
        let (raw, _) = try rawPair(at: f.destination)
        let before = try FileManager.default.attributesOfItem(atPath: raw.path)
        let bytes = try Data(contentsOf: raw)
        let result = try await engine(f, forbidSourceSessions: true).reprocessExistingLocalFiles(job: f.job)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(try XMPSidecar.read(from: f.destination.appendingPathComponent("photo.xmp")).country, "Norway")
        XCTAssertEqual(try Data(contentsOf: raw), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: raw.path)[.systemFileNumber] as? NSNumber, before[.systemFileNumber] as? NSNumber)
    }

    func testStandaloneReprocessingCreatesSidecarForEmbeddedGPSWithoutTouchingRAWBytes() async throws {
        let f = try fixture()
        let file = f.destination.appendingPathComponent("photo.cr3")
        // Construct writable JPEG metadata first, then exercise the RAW route
        // using its readable embedded GPS payload without modifying that payload.
        let prepared = f.root.appendingPathComponent("prepared.jpg")
        try jpeg(at: prepared)
        try FileManager.default.moveItem(at: prepared, to: file)
        let bytes = try Data(contentsOf: file)
        let result = try await engine(f, forbidSourceSessions: true).reprocessExistingLocalFiles(job: f.job)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(try XMPSidecar.read(from: f.destination.appendingPathComponent("photo.xmp")).city, "Oslo")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testDuplicateRAWStemsAbortReprocessingBeforeWritingSharedSidecar() async throws {
        let f = try fixture()
        let (raw, sidecar) = try rawPair(at: f.destination)
        let secondRaw = f.destination.appendingPathComponent("photo.nef")
        try Data("second opaque RAW".utf8).write(to: secondRaw)
        let original = try [raw, sidecar, secondRaw].map { try Data(contentsOf: $0) }
        do {
            _ = try await engine(f, forbidSourceSessions: true).reprocessExistingLocalFiles(job: f.job)
            XCTFail("A shared generated-sidecar owner must be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(try [raw, sidecar, secondRaw].map { try Data(contentsOf: $0) }, original)
    }

    func testProcessedCollisionKeepsSourceAndRetryPublishesAfterFixtureCollisionRemoval() async throws {
        var f = try fixture()
        f.job.processedFolder = try endpoint(f.processed)
        let (raw, sidecar) = try rawPair(at: f.source)
        let originalRaw = try Data(contentsOf: raw)
        let collision = f.processed.appendingPathComponent("photo.xmp")
        let collisionBytes = Data("owned test collision".utf8)
        try collisionBytes.write(to: collision)
        let engine = engine(f)
        do {
            _ = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTFail("Processed collision should reject publication")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.partialResult.processed, 0)
        }
        XCTAssertEqual(try Data(contentsOf: collision), collisionBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        try FileManager.default.removeItem(at: collision)
        let retry = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(retry.processed, 1)
        XCTAssertEqual(try Data(contentsOf: f.processed.appendingPathComponent("photo.cr3")), originalRaw)
        XCTAssertEqual(try XMPSidecar.read(from: collision).city, "Oslo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }
    func testChangedSidecarWithUnchangedRAWIsRetriedAfterProcessedPublicationFailure() async throws {
        var f = try fixture()
        let (raw, sidecar) = try rawPair(at: f.source)
        let originalRaw = try Data(contentsOf: raw)
        let engine = engine(f)
        let first = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(first.transferred, 1)
        let steady = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(steady.transferred, 0)

        // Only the companion file changes after both initial receipts were recorded.
        var edited = try XMPSidecar.read(from: sidecar)
        edited.exifGPSLatitude = "60,30N"
        edited.headline = "Changed sidecar requires a new processed publication"
        try XMPSidecar.write(edited, to: sidecar)
        XCTAssertEqual(try Data(contentsOf: raw), originalRaw)
        f.job.processedFolder = try endpoint(f.processed)
        let collision = f.processed.appendingPathComponent("photo.xmp")
        let collisionBytes = Data("second owned fixture collision".utf8)
        try collisionBytes.write(to: collision)
        do {
            _ = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTFail("Changed sidecar publication must encounter the processed collision")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.partialResult.processed, 0)
            XCTAssertEqual(failure.partialResult.transferred, 1)
        }
        XCTAssertEqual(try Data(contentsOf: collision), collisionBytes)
        XCTAssertEqual(try Data(contentsOf: raw), originalRaw)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        try FileManager.default.removeItem(at: collision)
        let retry = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(retry.processed, 1, "A new sidecar receipt must not hide the failed processed publication")
        XCTAssertEqual(try XMPSidecar.read(from: collision).headline, edited.headline)
        XCTAssertEqual(try Data(contentsOf: f.processed.appendingPathComponent("photo.cr3")), originalRaw)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

}
