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
    private func engine(_ fixture: Fixture, failure: Bool = false, forbidSourceSessions: Bool = false,
                        services: MetadataProcessingServices? = nil) -> SyncEngine {
        let service = MetadataGeocodingService(identity: .init(provider: "injected", version: "1", dataset: "fixture")) { _ in
            failure ? .failure(retryAfter: nil) : .found(.init(city: "Oslo", country: "Norway", source: "local fixture", distanceMeters: 25))
        }
        return SyncEngine(geocodingService: services == nil ? service : nil, metadataServices: services ?? .shared,
            sourceSignatureRepository: SourceSignatureRepository(fileURL: fixture.root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: fixture.root.appendingPathComponent("manifest.json")),
            sessionFactory: { endpoint, password, managed in
                if forbidSourceSessions { XCTFail("Standalone local reprocessing must not open source endpoint sessions"); throw CancellationError() }
                return try EndpointSessionFactory.make(endpoint: endpoint, password: password, managedFolder: managed)
            }, now: { Date(timeIntervalSince1970: 1_704_153_600) })
    }

    private func namedArea() -> MetadataGeofence {
        .init(name: "My venue", vertices: [
            .init(latitude: 59.4, longitude: 10.2),
            .init(latitude: 59.4, longitude: 10.3),
            .init(latitude: 59.6, longitude: 10.3),
            .init(latitude: 59.6, longitude: 10.2)
        ])
    }

    func testJPEGInsideNamedAreaWritesCustomCityWithoutProviderAndOutsideFallsBack() async throws {
        var f = try fixture()
        f.job.metadataGeocoding = try .init(cityPolicy: .overwrite,
            localeIdentifier: "en_US", geofences: [namedArea()])
        let inside = f.source.appendingPathComponent("inside.jpg")
        try jpeg(at: inside)
        let original = try Data(contentsOf: inside)
        let forbidden = MetadataGeocodingService(identity: .init(provider: "forbidden", version: "1", dataset: "fixture")) { _ in
            XCTFail("A City-only named area must not call the selected provider")
            return .failure(retryAfter: nil)
        }
        let services = MetadataProcessingServices(offlineGeocoding: forbidden, appleGeocoding: nil)
        let first = try await engine(f, services: services).run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(first.transferred, 1)
        XCTAssertEqual(try ImageMetadata.read(from: f.destination.appendingPathComponent("inside.jpg")).iptc.city,
                       "My venue")
        XCTAssertEqual(try Data(contentsOf: inside), original)

        let outside = f.source.appendingPathComponent("outside.jpg")
        try jpeg(at: outside)
        var metadata = try ImageMetadata.read(from: outside)
        metadata.setGPS(latitude: 60.0, longitude: 10.25)
        try metadata.write(to: outside)
        let second = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(second.transferred, 1)
        XCTAssertEqual(try ImageMetadata.read(from: f.destination.appendingPathComponent("outside.jpg")).iptc.city,
                       "Oslo")
    }

    func testNamedAreaCityAndProviderCountryCanBeWrittenTogether() async throws {
        var f = try fixture()
        f.job.metadataGeocoding = try .init(cityPolicy: .overwrite, countryPolicy: .overwrite,
            localeIdentifier: "en_US", geofences: [namedArea()])
        try jpeg(at: f.source.appendingPathComponent("photo.jpg"))
        let result = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(result.transferred, 1)
        let output = try ImageMetadata.read(from: f.destination.appendingPathComponent("photo.jpg"))
        XCTAssertEqual(output.iptc.city, "My venue")
        XCTAssertEqual(output.xmp?.country, "Norway")
    }

    func testSelectedAppleRoutesTransferAndReprocessingWithoutOfflineFallback() async throws {
        for failure in [false, true] {
            var f = try fixture()
            f.job.metadataGeocoding = try MetadataGeocodingSettings(cityPolicy: .overwrite,
                countryPolicy: .overwrite, localeIdentifier: "en_US", provider: .apple,
                allowSendingCoordinatesToApple: true)
            f.job.processedFolder = try endpoint(f.processed)
            let source = f.source.appendingPathComponent("photo.jpg")
            try jpeg(at: source)
            let original = try Data(contentsOf: source)
            let offline = MetadataGeocodingService(identity: OfflineMetadataGeocodingProvider.identity) { _ in
                XCTFail("An Apple job must never silently use the offline provider")
                return .noResult
            }
            let apple = MetadataGeocodingService(identity: AppleMetadataGeocodingProvider.identity) { query in
                XCTAssertEqual(query.locale, "en_US")
                return failure ? .failure(retryAfter: nil) : .found(.init(city: "Apple fixture", country: "Norway",
                    source: "injected Apple fixture", distanceMeters: nil))
            }
            let services = MetadataProcessingServices(offlineGeocoding: offline, appleGeocoding: apple)
            let selected = engine(f, services: services)
            let result = try await selected.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(result.transferred, 1)
            XCTAssertEqual(result.processed, failure ? 0 : 1)
            let output = f.destination.appendingPathComponent("photo.jpg")
            if failure {
                XCTAssertEqual(try Data(contentsOf: output), original)
                XCTAssertEqual(try Data(contentsOf: source), original)
            } else {
                XCTAssertEqual(try ImageMetadata.read(from: output).iptc.city, "Apple fixture")
                let reprocessed = try await engine(f, forbidSourceSessions: true, services: services)
                    .reprocessExistingLocalFiles(job: f.job)
                XCTAssertEqual(reprocessed.failed, 0)
                XCTAssertEqual(try ImageMetadata.read(from: output).iptc.city, "Apple fixture")
            }
            let repeated = try await selected.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(repeated.transferred, 0)
        }
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

    func testDestinationEditDuringNoChangeReprocessingCannotReceiveCompleteReceipt() async throws {
        for preflight in [false, true] {
            for filter in [MetadataReprocessFilter.all, .staleOrIncomplete] {
                var f = try fixture()
                _ = try rawPair(at: f.source)
                let initial = try await engine(f).run(job: f.job, leftPassword: nil, rightPassword: nil)
                let previous = try XCTUnwrap(initial.metadataReport.entries.first)
                XCTAssertNotNil(previous.processingFingerprint)
                f.job.metadataGeocoding = try .init(cityPolicy: .overwrite,
                    countryPolicy: .overwrite, localeIdentifier: "en_US")
                let target = f.destination.appendingPathComponent("photo.xmp")
                let original = try Data(contentsOf: target)
                let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date)
                let provider = MetadataGeocodingService(
                    identity: .init(provider: "injected", version: "1", dataset: "fixture")
                ) { _ in
                    do {
                        var xmp = try XMPSidecar.read(from: target)
                        xmp.headline = "Swap headline"
                        try XMPSidecar.write(xmp, to: target)
                        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
                        XCTAssertEqual(try Data(contentsOf: target).count, original.count)
                    } catch { XCTFail("Could not edit fixture: \(error)") }
                    return .found(.init(city: "Oslo", country: "Norway", source: "local fixture", distanceMeters: 25))
                }
                let resolver = SyncEngine(geocodingService: provider,
                    sourceSignatureRepository: SourceSignatureRepository(fileURL: f.root.appendingPathComponent("signatures.sqlite")),
                    downloadManifestRepository: DownloadManifestRepository(fileURL: f.root.appendingPathComponent("manifest.json")))
                let result = try await resolver.reprocessExistingLocalFiles(job: f.job,
                    filter: filter, latestOutcomes: ["photo.cr3": previous], isPreflight: preflight)
                XCTAssertEqual(result.failed, 1)
                XCTAssertEqual(result.applied, 0)
                let outcome = try XCTUnwrap(result.metadataReport.entries.first)
                XCTAssertEqual(outcome.status, .failed)
                XCTAssertNil(outcome.processingFingerprint)
                XCTAssertTrue(outcome.detail?.contains("destination changed") == true)
                XCTAssertEqual(try XMPSidecar.read(from: target).headline, "Swap headline")
            }
        }
    }

    func testSourceSidecarChangedDuringGeocodingDoesNotPublishStaleProcessedPair() async throws {
        var f = try fixture()
        f.job.processedFolder = try endpoint(f.processed)
        let (raw, sidecar) = try rawPair(at: f.source)
        let originalRAW = try Data(contentsOf: raw)
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: sidecar.path)
        let originalSidecarSize = try Data(contentsOf: sidecar).count
        let service = MetadataGeocodingService(
            identity: .init(provider: "injected", version: "1", dataset: "source-mutation-\(UUID())")
        ) { _ in
            do {
                var changed = try XMPSidecar.read(from: sidecar)
                changed.headline = "Swap headline"
                try XMPSidecar.write(changed, to: sidecar)
                try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: sidecar.path)
                XCTAssertEqual(try Data(contentsOf: sidecar).count, originalSidecarSize)
            } catch {
                XCTFail("Could not mutate the disposable source sidecar: \(error)")
            }
            return .found(.init(city: "Oslo", country: "Norway",
                source: "injected source mutation", distanceMeters: 25))
        }
        let engine = SyncEngine(geocodingService: service,
            sourceSignatureRepository: SourceSignatureRepository(fileURL: f.root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: f.root.appendingPathComponent("manifest.json")),
            now: { Date(timeIntervalSince1970: 1_704_153_600) })

        do {
            _ = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTFail("The changed source companion must stop processed publication")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.partialResult.processed, 0)
        }
        XCTAssertEqual(try Data(contentsOf: raw), originalRAW)
        XCTAssertEqual(try XMPSidecar.read(from: sidecar).headline, "Swap headline")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.processed.path), [])

        let retry = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(retry.processed, 1)
        XCTAssertEqual(try Data(contentsOf: f.processed.appendingPathComponent("photo.cr3")), originalRAW)
        XCTAssertEqual(try XMPSidecar.read(from: f.processed.appendingPathComponent("photo.xmp")).headline,
            "Swap headline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testNewSidecarForUnchangedRAWCompletesCustomAndManagedProcessedPublication() async throws {
        for managed in [false, true] {
            var f = try fixture()
            if managed {
                f.job.processedFilesLocation = .processedSubfolder
            } else {
                f.job.processedFolder = try endpoint(f.processed)
            }
            let sourceRAW = f.source.appendingPathComponent("photo.cr3")
            let sourceSidecar = f.source.appendingPathComponent("photo.xmp")
            let originalRAW = Data("opaque fixture RAW".utf8)
            try originalRAW.write(to: sourceRAW)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: sourceRAW.path
            )
            let engine = engine(f)
            let first = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(first.transferred, 1)
            XCTAssertEqual(first.processed, 0, "Incomplete geocoding must leave the RAW source available")
            XCTAssertEqual(try Data(contentsOf: sourceRAW), originalRAW)

            var xmp = XMPData()
            xmp.exifGPSLatitude = "59,30N"
            xmp.exifGPSLongitude = "10,15E"
            xmp.headline = "Retain source headline"
            try XMPSidecar.write(xmp, to: sourceSidecar)
            let second = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(second.transferred, 1, "The new companion must retry the unchanged RAW")
            XCTAssertEqual(second.processed, 1)
            let destination = managed ? f.destination.appendingPathComponent("Synced Files") : f.destination
            let processed = managed ? f.destination.appendingPathComponent("Processed Files") : f.processed
            for folder in [destination, processed] {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("photo.cr3")), originalRAW)
                let delivered = try XMPSidecar.read(from: folder.appendingPathComponent("photo.xmp"))
                XCTAssertEqual(delivered.city, "Oslo")
                XCTAssertEqual(delivered.country, "Norway")
                XCTAssertEqual(delivered.headline, "Retain source headline")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRAW.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceSidecar.path))
            let idle = try await engine.run(job: f.job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(idle.transferred, 0)
            XCTAssertEqual(idle.processed, 0)
        }
    }

}
