import Darwin
import AppKit
import ImageIO
import Foundation
import XCTest
import SwiftMediaMetadata
@testable import AagedalFTPSync

final class LocalMatchingPublicationTests: XCTestCase {
    func testLocalListingPreservesNestedAndHiddenFilesButNeverFollowsLinks() async throws {
        let f = try fixture()
        let directories = ["Nested folder/Åse", ".hidden", ".aagedal-sync-test.transaction", "Fixture.bundle"]
        for directory in directories {
            try FileManager.default.createDirectory(at: f.root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let expected = ["plain.jpg", "Nested folder/Åse/photo.cr3", "Nested folder/Åse/photo.xmp", ".hidden/photo.jpg"]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for name in expected + [".aagedal-sync-test.transaction/held.jpg", ".aagedal-sync-test.part", "Fixture.bundle/ignored.jpg"] {
            try write("fixture", name, fixture: f)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: f.root.appendingPathComponent(name).path)
        }
        try Data("outside".utf8).write(to: f.inputs.appendingPathComponent("outside.jpg"))
        for (name, target) in [
            ("outside-directory", f.inputs),
            ("inside-directory", f.root.appendingPathComponent("Nested folder")),
            ("linked.jpg", f.inputs.appendingPathComponent("outside.jpg")),
            ("dangling.jpg", f.inputs.appendingPathComponent("missing.jpg")),
        ] {
            try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent(name), withDestinationURL: target)
        }
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        let listing = try await session.listFiles()
        XCTAssertEqual(Set(listing.keys), Set(expected))
        for file in listing.values {
            XCTAssertEqual(file.size, 7)
            XCTAssertEqual(file.modifiedAt, date)
        }
        // Listing evidence never authorizes following a later replacement link.
        let original = try XCTUnwrap(listing["Nested folder/Åse/photo.cr3"])
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Nested folder"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("Nested folder"), withDestinationURL: f.inputs)
        do {
            try await session.exportFile(original, to: f.inputs.appendingPathComponent("exported"))
            XCTFail("A changed ancestor must not be followed after listing")
        } catch { XCTAssertTrue(error.localizedDescription.contains("symbolic link")) }
    }

    func testLocalListingRejectsRemovedRootAndCancelledEmptyScan() async throws {
        let f = try fixture()
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.listFiles()
        }
        do {
            _ = try await cancelled.value
            XCTFail("An empty listing must still observe cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        try FileManager.default.removeItem(at: f.root)
        do {
            _ = try await session.listFiles()
            XCTFail("An unavailable root must not appear to be an empty folder")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testLocalListingRejectsRootReplacedWithSymlink() async throws {
        let f = try fixture()
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        try Data("outside".utf8).write(to: f.inputs.appendingPathComponent("outside.jpg"))
        try FileManager.default.removeItem(at: f.root)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: f.inputs)
        do {
            _ = try await session.listFiles()
            XCTFail("A redirected root must not expose another folder's files")
        } catch { XCTAssertTrue(error.localizedDescription.contains("symbolic link")) }
    }

    func testLocalListingRejectsUnreadableSubtreeInsteadOfReturningPartialFiles() async throws {
        let f = try fixture()
        try write("visible", "photo.jpg", fixture: f)
        let blocked = f.root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("hidden by permissions".utf8).write(to: blocked.appendingPathComponent("photo.jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        do {
            _ = try await session.listFiles()
            XCTFail("An unreadable subtree must fail the complete scan")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testRecoveryAdmissionScansPastCancellationBatchesAndChecksFreshState() throws {
        let f = try fixture()
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        for index in 0..<600 {
            try write("background", "background-\(index).txt", fixture: f)
            try write("hidden background", ".unrelated-hidden-file-\(index).txt", fixture: f)
        }
        XCTAssertNoThrow(try session.validateMetadataRecoveryIsResolved())
        let recovery = f.root.appendingPathComponent(".aagedal-sync-late.transaction")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        XCTAssertThrowsError(try session.validateMetadataRecoveryIsResolved()) { error in
            XCTAssertTrue(error.localizedDescription.contains(recovery.path), error.localizedDescription)
        }
        try FileManager.default.removeItem(at: recovery)
        XCTAssertNoThrow(try session.validateMetadataRecoveryIsResolved())
    }

    func testNativeRecoveryFixtureUsesRealAdmissionAndDoesNotReseedAfterReconciliation() async throws {
        try await verifyNativeRecoveryFixture(managed: false)
    }

    func testManagedNativeRecoveryFixtureUsesRealAdmissionAndDoesNotReseedAfterReconciliation() async throws {
        try await verifyNativeRecoveryFixture(managed: true)
    }

    private func verifyNativeRecoveryFixture(managed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var job = SyncJob(name: "Disposable native recovery")
        try UITestSupport.seedMetadataRecoveryFixture(job: &job, rootURL: root, managed: managed)
        let repository = try UITestSupport.recoveryFixtureRepository(job: job, rootURL: root)
        job = try XCTUnwrap(repository.load().first)
        XCTAssertEqual(job.metadataProcessingTimeZoneIdentifier, "Etc/UTC")
        let engine = SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")))
        do {
            _ = try await engine.preflightExistingLocalFiles(job: job)
            XCTFail("Native fixture must fail preflight while recovery is retained")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Recover the retained files"))
        }
        let source = try LocalEndpointSession(endpoint: job.left)
        XCTAssertNoThrow(try source.validateMetadataRecoveryIsResolved())
        let destination = try LocalEndpointSession(endpoint: job.right, managedFolder: managed ? .syncedFiles : nil)
        let folder = root.appendingPathComponent(managed ? "Destination/Synced Files" : "Destination")
        let recovery = folder.appendingPathComponent(".aagedal-sync-ui-fixture.transaction")
        let original = recovery.appendingPathComponent("original-held-0")
        let visible = folder.appendingPathComponent("preserved.txt")
        let originalBytes = try Data(contentsOf: original)
        let visibleBytes = try Data(contentsOf: visible)
        XCTAssertThrowsError(try destination.validateMetadataRecoveryIsResolved()) { error in
            XCTAssertTrue(error.localizedDescription.contains(recovery.lastPathComponent))
        }
        let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self,
            from: Data(contentsOf: recovery.appendingPathComponent("recovery.json")))
        XCTAssertEqual(manifest.originals.map(\.relativePath), ["preserved.txt"])
        XCTAssertEqual(manifest.outputs.map(\.relativePath), ["preserved.txt"])
        // A repeated launch must preserve any edits made while inspecting recovery.
        try Data("reviewed visible bytes".utf8).write(to: visible)
        try UITestSupport.seedMetadataRecoveryFixture(job: &job, rootURL: root, managed: managed)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertNotEqual(try Data(contentsOf: visible), visibleBytes)
        // Reconcile by keeping the current output and moving the retained original
        // outside the transaction before removing its remaining snapshots.
        let rescued = root.appendingPathComponent("rescued-original.txt")
        try FileManager.default.moveItem(at: original, to: rescued)
        try FileManager.default.removeItem(at: recovery)
        try UITestSupport.seedMetadataRecoveryFixture(job: &job, rootURL: root, managed: managed)
        XCTAssertNoThrow(try destination.validateMetadataRecoveryIsResolved())
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertEqual(try Data(contentsOf: rescued), originalBytes)
        XCTAssertEqual(try Data(contentsOf: visible), Data("reviewed visible bytes".utf8))
        job.name = "Reviewed recovery job"
        try repository.save([job])
        let reopened = try UITestSupport.recoveryFixtureRepository(job: SyncJob(name: "Must not replace"), rootURL: root)
        XCTAssertEqual(try reopened.load().first?.name, "Reviewed recovery job")
        job = try XCTUnwrap(reopened.load().first)
        let preflight = try await engine.preflightExistingLocalFiles(job: job)
        XCTAssertEqual(preflight.scanned, 0)
        XCTAssertEqual(preflight.ready, 0)
        XCTAssertEqual(preflight.failed, 0)
        XCTAssertEqual(try Data(contentsOf: rescued), originalBytes)
        XCTAssertEqual(try Data(contentsOf: visible), Data("reviewed visible bytes".utf8))
        let storeURL = root.appendingPathComponent("jobs-v2.json")
        let damaged = Data("invalid fixture store".utf8)
        try damaged.write(to: storeURL)
        XCTAssertThrowsError(try UITestSupport.recoveryFixtureRepository(job: job, rootURL: root))
        XCTAssertEqual(try Data(contentsOf: storeURL), damaged)
    }

    func testNativeRecoveryReconciliationLaunchStepPreservesSnapshotsAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-reconcile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var job = SyncJob(name: "Disposable recovery")
        try UITestSupport.seedMetadataRecoveryFixture(job: &job, rootURL: root)
        try UITestSupport.reconcileMetadataRecoveryFixture(rootURL: root)
        let rescued = root.appendingPathComponent("rescued-original.txt")
        XCTAssertEqual(try Data(contentsOf: rescued), Data("retained original fixture bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("reconciled-recovery/recovery.json").path))
        let visible = root.appendingPathComponent("Destination/preserved.txt")
        XCTAssertEqual(try Data(contentsOf: visible), Data("reviewed visible fixture bytes".utf8))
        try Data("later review edit".utf8).write(to: visible)
        try UITestSupport.seedMetadataRecoveryFixture(job: &job, rootURL: root)
        try UITestSupport.reconcileMetadataRecoveryFixture(rootURL: root)
        XCTAssertEqual(try Data(contentsOf: visible), Data("later review edit".utf8))
        XCTAssertNoThrow(try LocalEndpointSession(endpoint: job.right).validateMetadataRecoveryIsResolved())
    }

    func testNativeImageRecoveryFixturePublishesAfterReconciliationAndRetainsReceipts() async throws {
        for managed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-image-recovery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            var job = SyncJob(name: "Disposable image recovery")
            try UITestSupport.seedMetadataRecoveryFixture(job: &job, rootURL: root, managed: managed, images: true)
            let repository = try UITestSupport.recoveryFixtureRepository(job: job, rootURL: root)
            job = try XCTUnwrap(repository.load().first)
            let destination = root.appendingPathComponent(managed ? "Destination/Synced Files" : "Destination")
            let image = destination.appendingPathComponent("nested/recovery.jpg")
            let before = try Data(contentsOf: image)
            let date = try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let engine = SyncEngine(
                sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")))
            do {
                _ = try await engine.preflightExistingLocalFiles(job: job)
                XCTFail("Retained recovery must prevent image admission")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Recover the retained files")) }
            XCTAssertEqual(try Data(contentsOf: image), before)
            try UITestSupport.reconcileMetadataRecoveryFixture(rootURL: root, managed: managed)
            let preflight = try await engine.preflightExistingLocalFiles(job: job)
            XCTAssertEqual(preflight.scanned, 1)
            XCTAssertEqual(preflight.ready, 1)
            XCTAssertEqual(preflight.failed, 0)
            XCTAssertEqual(try Data(contentsOf: image), before)
            let result = try await engine.reprocessExistingLocalFiles(job: job)
            XCTAssertEqual(result.applied, 1)
            XCTAssertEqual(result.failed, 0)
            XCTAssertEqual(try ImageMetadata.read(from: image).iptc.city, "Recovery Venue")
            XCTAssertEqual(try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Source/recovery.jpg")), before)
            let published = try Data(contentsOf: image)
            let auditURL = root.appendingPathComponent("audit.json")
            try MetadataAuditRepository(fileURL: auditURL).append(result.metadataReport)
            // A fresh launch must retain both the published image and its receipt.
            try UITestSupport.seedMetadataRecoveryFixture(job: &job, rootURL: root, managed: managed, images: true)
            try UITestSupport.reconcileMetadataRecoveryFixture(rootURL: root, managed: managed)
            let receipts = try MetadataAuditRepository(fileURL: auditURL).latestEntries(jobID: job.id)
            XCTAssertEqual(receipts.count, 1)
            XCTAssertNotNil(receipts["nested/recovery.jpg"]?.processingFingerprint)
            let repeated = try await engine.reprocessExistingLocalFiles(job: job,
                filter: .staleOrIncomplete, latestOutcomes: receipts)
            XCTAssertEqual(repeated.applied, 0)
            XCTAssertEqual(repeated.skipped, 1)
            XCTAssertEqual(repeated.failed, 0)
            XCTAssertEqual(try Data(contentsOf: image), published)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("rescued-original.txt")),
                           Data("retained original fixture bytes".utf8))
        }
    }

    private struct Fixture {
        let root: URL
        let inputs: URL
        let endpoint: Endpoint
    }
    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("matching-import-\(UUID())")
        let root = base.appendingPathComponent("destination"), inputs = base.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let bookmark = try FolderBookmark.create(for: root)
        return Fixture(root: root, inputs: inputs, endpoint: Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data))
    }
    private func staged(_ name: String, contents: String, fixture: Fixture, prefix: String) throws -> EndpointFileImport {
        let url = fixture.inputs.appendingPathComponent(prefix + UUID().uuidString)
        let data = Data(contents.utf8)
        try data.write(to: url)
        return EndpointFileImport(localURL: url, file: SyncFile(relativePath: name, size: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }
    private func write(_ contents: String, _ name: String, fixture: Fixture) throws {
        try Data(contents.utf8).write(to: fixture.root.appendingPathComponent(name))
    }
    private func read(_ name: String, fixture: Fixture) throws -> String {
        String(decoding: try Data(contentsOf: fixture.root.appendingPathComponent(name)), as: UTF8.self)
    }
    private func recoveryFiles(_ fixture: Fixture) throws -> [URL] {
        let directories = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".transaction") }
        return try directories.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
    }

    // Invoked only by Scripts/test-metadata-process-interruption.py. The worker
    // intentionally dies without Swift cleanup; the verifier runs in a fresh host.
    private func interruptionFixture() throws -> (Fixture, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["AAGEDAL_INTERRUPTION_ROOT"],
              let phase = environment["AAGEDAL_INTERRUPTION_PHASE"] else {
            throw XCTSkip("Opt-in subprocess interruption harness")
        }
        let base = URL(fileURLWithPath: path)
        guard base.lastPathComponent.hasPrefix("aagedal-interruption-") else {
            throw AppError.transferFailed("Interruption fixtures must use a disposable harness directory.")
        }
        let destination = base.appendingPathComponent("destination")
        let root = interruptionManaged ? destination.appendingPathComponent("Synced Files") : destination
        let inputs = base.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let bookmark = try FolderBookmark.create(for: destination)
        return (Fixture(root: root, inputs: inputs, endpoint: Endpoint(kind: .local,
            localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)), phase)
    }

    private var interruptionManaged: Bool {
        ProcessInfo.processInfo.environment["AAGEDAL_INTERRUPTION_MANAGED"] == "1"
    }

    private let interruptionDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func interruptionXMP(_ headline: String) -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" photoshop:Headline="\(headline)"/></rdf:RDF></x:xmpmeta>
        """.utf8)
    }

    private func interruptionImport(_ path: String, bytes: Data, fixture: Fixture) throws -> EndpointFileImport {
        let url = fixture.inputs.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return EndpointFileImport(localURL: url, file: SyncFile(relativePath: path,
            size: Int64(bytes.count), modifiedAt: interruptionDate))
    }

    private func interruptionJPEG(fixture: Fixture) throws -> (Data, Data) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) { pixels[index] = UInt8(index % 251) }
        let url = fixture.inputs.appendingPathComponent("source.jpg")
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
        _ = try MetadataWriter.apply(ResolvedMetadataChanges(headline: "Original JPEG"), to: url)
        let original = try Data(contentsOf: url)
        _ = try MetadataWriter.apply(ResolvedMetadataChanges(headline: "Processed JPEG",
            existingFieldPolicy: .overwrite), to: url)
        let processed = try Data(contentsOf: url)
        XCTAssertEqual(try JPEGParser.parse(original).scanData, try JPEGParser.parse(processed).scanData)
        try original.write(to: fixture.inputs.appendingPathComponent("original.jpg"))
        try processed.write(to: fixture.inputs.appendingPathComponent("processed.jpg"))
        return (original, processed)
    }

    private var interruptionIsJPEG: Bool {
        ProcessInfo.processInfo.environment["AAGEDAL_INTERRUPTION_MEDIA"] == "jpeg"
    }

    private var interruptionPaths: [String] {
        interruptionIsJPEG ? ["nested/image.jpg"] : ["nested/photo.cr3", "nested/photo.xmp"]
    }

    func testProcessInterruptionWorker() async throws {
        let (f, requestedPhase) = try interruptionFixture()
        let paths = interruptionPaths
        let bytes: [Data]
        let outputBytes: Data
        if interruptionIsJPEG {
            let (original, processed) = try interruptionJPEG(fixture: f)
            bytes = [original]
            outputBytes = processed
        } else {
            bytes = [Data("synthetic RAW payload".utf8), interruptionXMP("Original XMP")]
            outputBytes = interruptionXMP("Processed XMP")
        }
        var originals: [EndpointFileImport] = []
        for (path, data) in zip(paths, bytes) {
            let destination = f.root.appendingPathComponent(path)
            try data.write(to: destination)
            try FileManager.default.setAttributes([.modificationDate: interruptionDate], ofItemAtPath: destination.path)
            originals.append(try interruptionImport(path, bytes: data, fixture: f))
        }
        let output = try interruptionImport(try XCTUnwrap(paths.last), bytes: outputBytes, fixture: f)
        let marker = f.inputs.appendingPathComponent("interrupted-phase")
        let session = try LocalEndpointSession(endpoint: f.endpoint,
            managedFolder: interruptionManaged ? .syncedFiles : nil, matchingImportHook: { phase in
            let name: String
            switch phase {
            case .prepared: name = "prepared"
            case .originalsHeld: name = "originalsHeld"
            case .published(let index): name = "published-\(index)"
            case .beforeCommit: name = "beforeCommit"
            }
            guard name == requestedPhase else { return }
            try Data(name.utf8).write(to: marker, options: .atomic)
            guard kill(getpid(), SIGKILL) == 0 else { _exit(99) }
            // Wait for signal delivery instead of racing it with ordinary exit.
            while true { pause() }
        })
        try await session.importFilesTransactionallyMatching([output], replacing: originals,
            preserveDate: true, verifySize: true)
        XCTFail("The requested interruption phase was never reached")
    }

    func testProcessInterruptionRecovery() async throws {
        let (f, phase) = try interruptionFixture()
        XCTAssertEqual(try String(contentsOf: f.inputs.appendingPathComponent("interrupted-phase"), encoding: .utf8), phase)
        let manifestURL = try XCTUnwrap(recoveryFiles(f).first { $0.lastPathComponent == "recovery.json" })
        let recovery = manifestURL.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self,
            from: Data(contentsOf: manifestURL))
        let paths = interruptionPaths
        let originals: [Data]
        let processed: Data
        if interruptionIsJPEG {
            originals = [try Data(contentsOf: f.inputs.appendingPathComponent("original.jpg"))]
            processed = try Data(contentsOf: f.inputs.appendingPathComponent("processed.jpg"))
            XCTAssertEqual(try JPEGParser.parse(originals[0]).scanData, try JPEGParser.parse(processed).scanData)
        } else {
            originals = [Data("synthetic RAW payload".utf8), interruptionXMP("Original XMP")]
            processed = interruptionXMP("Processed XMP")
        }
        let held = phase != "prepared"
        let published = phase == "published-0" || phase == "beforeCommit"
        var expected = originals
        if published { expected[expected.count - 1] = processed }
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.originals.map(\.relativePath), paths)
        XCTAssertEqual(manifest.originals.map(\.isReplaced), interruptionIsJPEG ? [true] : [false, true])
        XCTAssertEqual(manifest.outputs.map(\.relativePath), [try XCTUnwrap(paths.last)])
        for (index, original) in manifest.originals.enumerated() {
            XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(original.snapshotFilename)), originals[index])
            let holding = recovery.appendingPathComponent(original.heldFilename)
            XCTAssertEqual(FileManager.default.fileExists(atPath: holding.path), held)
            if held { XCTAssertEqual(try Data(contentsOf: holding), originals[index]) }
            let destination = f.root.appendingPathComponent(original.relativePath)
            let exists = !held || (index == paths.count - 1 && published)
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), exists)
            if exists { XCTAssertEqual(try Data(contentsOf: destination), expected[index]) }
        }
        let output = try XCTUnwrap(manifest.outputs.first)
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(output.snapshotFilename)), processed)
        let session = try LocalEndpointSession(endpoint: f.endpoint,
            managedFolder: interruptionManaged ? .syncedFiles : nil)
        XCTAssertThrowsError(try session.validateMetadataRecoveryIsResolved()) { error in
            XCTAssertTrue(error.localizedDescription.contains(recovery.path))
        }
        // Explicitly retain published outputs, restore missing originals, then
        // remove the resolved recovery directory. This is not automatic replay.
        for original in manifest.originals {
            let destination = f.root.appendingPathComponent(original.relativePath)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: recovery.appendingPathComponent(original.heldFilename), to: destination)
            }
        }
        for (path, bytes) in zip(paths, expected) {
            let destination = f.root.appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date,
                           interruptionDate)
        }
        if interruptionIsJPEG {
            try verifyInterruptionJPEG(at: f.root.appendingPathComponent(paths[0]),
                headline: published ? "Processed JPEG" : "Original JPEG")
        } else {
            XCTAssertEqual(try MetadataWriter.readExistingGeocodingSidecar(at: f.root.appendingPathComponent(paths[0]))?.headline,
                           published ? "Processed XMP" : "Original XMP")
        }
        try FileManager.default.removeItem(at: recovery)
        try session.validateMetadataRecoveryIsResolved()
        let snapshots = try zip(paths, expected).map { try interruptionImport($0.0, bytes: $0.1, fixture: f) }
        let retryBytes = interruptionIsJPEG ? processed : interruptionXMP("Retried XMP")
        let retry = try interruptionImport(try XCTUnwrap(paths.last), bytes: retryBytes, fixture: f)
        try await session.importFilesTransactionallyMatching([retry], replacing: snapshots,
            preserveDate: true, verifySize: true)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(try XCTUnwrap(paths.last))), retryBytes)
        if interruptionIsJPEG {
            try verifyInterruptionJPEG(at: f.root.appendingPathComponent(paths[0]), headline: "Processed JPEG")
        } else {
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(paths[0])), originals[0])
            XCTAssertEqual(try MetadataWriter.readExistingGeocodingSidecar(at: f.root.appendingPathComponent(paths[0]))?.headline,
                           "Retried XMP")
        }
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
        try Data(phase.utf8).write(to: f.inputs.appendingPathComponent("recovery-verified"), options: .atomic)
    }

    private func verifyInterruptionJPEG(at url: URL, headline: String) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = try XCTUnwrap(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCHeadline as String] as? String, headline)
    }

    func testReadOnlySnapshotValidationDetectsNewCompanionAndPrimaryEdits() throws {
        let f = try fixture()
        try write("RAW bytes", "photo.cr3", fixture: f)
        let original = try staged("photo.cr3", contents: "RAW bytes", fixture: f, prefix: "original")
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        XCTAssertNoThrow(try session.validateMetadataSnapshot(primary: original,
            sidecar: nil, absentSidecarPath: "photo.xmp"))
        try write("User sidecar", "photo.xmp", fixture: f)
        XCTAssertThrowsError(try session.validateMetadataSnapshot(primary: original,
            sidecar: nil, absentSidecarPath: "photo.xmp"))
        XCTAssertEqual(try read("photo.xmp", fixture: f), "User sidecar")
        try write("NEW bytes", "photo.cr3", fixture: f)
        XCTAssertThrowsError(try session.validateMetadataSnapshot(primary: original,
            sidecar: nil, absentSidecarPath: nil))
        XCTAssertEqual(try read("photo.cr3", fixture: f), "NEW bytes")
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
    }

    func testRecoveryScanIncludesHiddenFilesAndDanglingLinksAndFailsForMissingRoot() throws {
        let f = try fixture()
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        try write("unrelated", ".ordinary-hidden-file", fixture: f)
        for name in ["aagedal-sync-visible.transaction", "Åse.jpg", ".aagedal-sync-photo.jpg",
                     ".aagedal-sync-reset-photo.jpg", ".aagedal-sync-other.trash"] {
            try write("unrelated", name, fixture: f)
        }
        try session.validateMetadataRecoveryIsResolved()
        let name = ".aagedal-sync-Åse.transaction"
        try write("retained", name, fixture: f)
        XCTAssertThrowsError(try session.validateMetadataRecoveryIsResolved())
        XCTAssertEqual(try read(name, fixture: f), "retained")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(name))
        let link = f.root.appendingPathComponent(".aagedal-sync-reset-interrupted.trash")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.inputs.appendingPathComponent("missing"))
        XCTAssertThrowsError(try session.validateMetadataRecoveryIsResolved())
        try FileManager.default.removeItem(at: link)
        try session.validateMetadataRecoveryIsResolved()
        try FileManager.default.removeItem(at: f.root)
        XCTAssertThrowsError(try session.validateMetadataRecoveryIsResolved()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
    }

    func testCancelledRecoveryScanDoesNotAdmitOrChangeDestination() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try session.validateMetadataRecoveryIsResolved()
        }
        do {
            try await task.value
            XCTFail("Cancelled recovery admission must fail")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try read("photo.jpg", fixture: f), "original")
    }

    func testLargeFolderRecoveryScanBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AAGEDAL_RECOVERY_SCAN_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in disposable 100,000-file recovery scan benchmark")
        }
        let f = try fixture()
        for index in 0..<100_000 {
            try Data().write(to: f.root.appendingPathComponent("photo-\(index).jpg"))
        }
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        var previous: [Double] = [], streaming: [Double] = []
        for _ in 0..<20 {
            let oldStart = Date()
            try autoreleasepool {
                let names = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
                XCTAssertFalse(names.contains(where: LocalEndpointSession.isRecoveryArtifact(named:)))
            }
            previous.append(Date().timeIntervalSince(oldStart))
            let start = Date()
            try session.validateMetadataRecoveryIsResolved()
            streaming.append(Date().timeIntervalSince(start))
        }
        print("RECOVERY_SCAN_BENCHMARK files=100000 samples=20 previousSeconds=\(previous) streamingSeconds=\(streaming)")
        // A new recovery name must still be found after repeated successful scans.
        try write("retained", ".aagedal-sync-late.transaction", fixture: f)
        XCTAssertThrowsError(try session.validateMetadataRecoveryIsResolved())
        XCTAssertEqual(try read(".aagedal-sync-late.transaction", fixture: f), "retained")
    }

    func testLargeFolderRecoveryPublicationBatchBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["AAGEDAL_RECOVERY_BATCH_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in disposable recovery publication batch benchmark")
        }
        for backgroundCount in [0, 100_000] {
            let f = try fixture()
            for index in 0..<backgroundCount {
                try Data().write(to: f.root.appendingPathComponent("background-\(index).jpg"))
            }
            try FileManager.default.createDirectory(at: f.root.appendingPathComponent("photos"), withIntermediateDirectories: false)
            var batch: [(EndpointFileImport, EndpointFileImport)] = []
            for index in 0..<50 {
                let rawPath = "photos/photo-\(index).cr3"
                try write("unchanged RAW \(index)", rawPath, fixture: f)
                let original = try staged(rawPath, contents: "unchanged RAW \(index)", fixture: f, prefix: "original")
                let output = try staged("photos/photo-\(index).xmp", contents: "processed metadata \(index)", fixture: f, prefix: "output")
                batch.append((original, output))
            }
            let session = try LocalEndpointSession(endpoint: f.endpoint)
            let clock = ContinuousClock()
            let started = clock.now
            try session.validateMetadataRecoveryIsResolved()
            var durations: [Double] = []
            for (original, output) in batch {
                let start = clock.now
                try session.validateMetadataSnapshot(primary: original, sidecar: nil,
                    absentSidecarPath: output.file.relativePath)
                try await session.importFilesTransactionallyMatching([output], replacing: [original],
                    preserveDate: true, verifySize: true)
                let elapsed = start.duration(to: clock.now).components
                durations.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            }
            let elapsed = started.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print("RECOVERY_BATCH_BENCHMARK backgroundFiles=\(backgroundCount) images=50 admissionScans=101 totalSeconds=\(seconds) imageSeconds=\(durations)")
            // Timing excludes these integrity checks and the fixture setup/cleanup.
            for (original, output) in batch {
                XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(original.file.relativePath)),
                    try Data(contentsOf: original.localURL))
                XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(output.file.relativePath)),
                    try Data(contentsOf: output.localURL))
            }
            XCTAssertTrue(try recoveryFiles(f).isEmpty)
            // No successful scan may be reused after a later recovery artifact appears.
            try write("retained original", ".aagedal-sync-late.transaction", fixture: f)
            let (original, output) = batch[0]
            XCTAssertThrowsError(try session.validateMetadataSnapshot(primary: original,
                sidecar: output, absentSidecarPath: nil))
            do {
                try await session.importFilesTransactionallyMatching([output], replacing: [original, output],
                    preserveDate: true, verifySize: true)
                XCTFail("Recovery created after the batch must block publication")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(".aagedal-sync-late.transaction"))
            }
            XCTAssertEqual(try read(".aagedal-sync-late.transaction", fixture: f), "retained original")
        }
    }

    func testRecoveryAppearingAfterAdmissionBlocksSnapshotAndPublication() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        try session.validateMetadataRecoveryIsResolved()
        let recovery = f.root.appendingPathComponent(".aagedal-sync-interrupted.transaction")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        let held = recovery.appendingPathComponent("original-held-0")
        try Data("retained original".utf8).write(to: held)
        // Older/incomplete transactions need protection even without a manifest.
        XCTAssertThrowsError(try session.validateMetadataSnapshot(primary: original,
            sidecar: nil, absentSidecarPath: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains(recovery.path))
        }
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: [original],
                preserveDate: true, verifySize: true)
            XCTFail("Recovery appearing during resolution must block publication")
        } catch { XCTAssertTrue(error.localizedDescription.contains(recovery.path)) }
        XCTAssertEqual(try read("photo.jpg", fixture: f), "original")
        XCTAssertEqual(try Data(contentsOf: held), Data("retained original".utf8))
        XCTAssertEqual(try recoveryFiles(f).map { $0.resolvingSymlinksInPath() }, [held.resolvingSymlinksInPath()])
        try FileManager.default.removeItem(at: recovery)
        try await session.importFilesTransactionallyMatching([output], replacing: [original],
            preserveDate: true, verifySize: true)
        XCTAssertEqual(try read("photo.jpg", fixture: f), "processed")
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
    }

    func testRecoveryManifestPrecedesMovesAndPreparationFailureLeavesOriginalsIntact() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        let root = f.root
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
            guard case .prepared = phase else { return }
            let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".transaction") })
            let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self,
                from: Data(contentsOf: recovery.appendingPathComponent("recovery.json")))
            XCTAssertEqual(manifest.schemaVersion, 1)
            XCTAssertEqual(manifest.originals.first?.relativePath, "photo.jpg")
            XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("original-held-0").path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.jpg")), Data("original".utf8))
            throw CancellationError()
        })
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: [original], preserveDate: true, verifySize: true)
            XCTFail("Preparation cancellation must abort publication")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try read("photo.jpg", fixture: f), "original")
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
    }

    func testRetainedManifestMapsNestedRawAndSidecarWithoutExposingInputPaths() async throws {
        let f = try fixture()
        let directory = "Pictures/Åse's event"
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent(directory), withIntermediateDirectories: true)
        let rawPath = directory + "/photo.cr3", sidecarPath = directory + "/photo.xmp"
        try write("RAW", rawPath, fixture: f)
        try write("old sidecar", sidecarPath, fixture: f)
        let originals = try [staged(rawPath, contents: "RAW", fixture: f, prefix: "raw"),
                             staged(sidecarPath, contents: "old sidecar", fixture: f, prefix: "old")]
        let output = try staged(sidecarPath, contents: "processed", fixture: f, prefix: "new")
        let target = f.root.appendingPathComponent(sidecarPath)
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
            if case .published = phase { try Data("concurrent edit".utf8).write(to: target) }
        })
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: originals, preserveDate: true, verifySize: true)
            XCTFail("Concurrent edit must retain the original backup")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Recover retained files")) }
        let files = try recoveryFiles(f)
        let manifestURL = try XCTUnwrap(files.first { $0.lastPathComponent == "recovery.json" })
        let data = try Data(contentsOf: manifestURL)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(f.inputs.path))
        let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self, from: data)
        XCTAssertEqual(manifest.originals.map(\.relativePath), [rawPath, sidecarPath])
        XCTAssertEqual(manifest.originals.map(\.isReplaced), [false, true])
        XCTAssertEqual(manifest.outputs.map(\.relativePath), [sidecarPath])
        let backup = try XCTUnwrap(manifest.originals.last)
        let recovery = manifestURL.deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(backup.heldFilename)), Data("old sidecar".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(backup.snapshotFilename)), Data("old sidecar".utf8))
        let published = try XCTUnwrap(manifest.outputs.first)
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(published.snapshotFilename)), Data("processed".utf8))
        XCTAssertEqual(published.stagedFilename, "output-stage-0")
        XCTAssertEqual(published.rollbackFilename, "rollback-output-0")
        XCTAssertEqual(try read(rawPath, fixture: f), "RAW")
        XCTAssertEqual(try read(sidecarPath, fixture: f), "concurrent edit")
        let listing = try await session.listFiles()
        XCTAssertEqual(Set(listing.keys), Set([rawPath, sidecarPath]))
    }

    func testPublishedReplacementReportsRecoveryCleanupFailureAndBlocksRetry() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingRecoveryRemoval: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: [original],
                preserveDate: true, verifySize: true)
            XCTFail("Cleanup failure must not report successful processing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Replacement was published"))
            XCTAssertTrue(error.localizedDescription.contains("recovery folder cleanup failed"))
            XCTAssertTrue(error.localizedDescription.contains(f.root.path))
        }
        XCTAssertEqual(try read("photo.jpg", fixture: f), "processed")
        let retained = try recoveryFiles(f)
        XCTAssertTrue(retained.contains { $0.lastPathComponent == "recovery.json" })
        XCTAssertFalse(retained.contains { $0.lastPathComponent == "original-held-0" })
        let reopened = try LocalEndpointSession(endpoint: f.endpoint)
        XCTAssertThrowsError(try reopened.validateMetadataRecoveryIsResolved())
        // Reconciliation keeps the published output and removes only this test's recovery folder.
        let manifest = try XCTUnwrap(retained.first { $0.lastPathComponent == "recovery.json" })
        try FileManager.default.removeItem(at: manifest.deletingLastPathComponent())
        try reopened.validateMetadataRecoveryIsResolved()
        XCTAssertEqual(try read("photo.jpg", fixture: f), "processed")
    }

    func testRolledBackReplacementReportsRecoveryCleanupFailureAndPreservesOriginal() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingRecoveryRemoval: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }, matchingImportHook: { phase in
            if case .published = phase { throw CancellationError() }
        })
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: [original],
                preserveDate: true, verifySize: true)
            XCTFail("Cancelled publication must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("originals were preserved or restored"))
            XCTAssertTrue(error.localizedDescription.contains("recovery folder cleanup failed"))
            XCTAssertTrue(error.localizedDescription.contains(f.root.path))
        }
        XCTAssertEqual(try read("photo.jpg", fixture: f), "original")
        XCTAssertTrue(try recoveryFiles(f).contains { $0.lastPathComponent == "recovery.json" })
        XCTAssertThrowsError(try LocalEndpointSession(endpoint: f.endpoint).validateMetadataRecoveryIsResolved())
    }

    func testMatchingEmbeddedReplacementPublishesAndRemovesPrivateHoldings() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        try await LocalEndpointSession(endpoint: f.endpoint).importFilesTransactionallyMatching([output], replacing: [original], preserveDate: true, verifySize: true)
        XCTAssertEqual(try read("photo.jpg", fixture: f), "processed")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("photo.jpg").path)[.modificationDate] as? Date, output.file.modifiedAt)
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
    }

    func testSameSizeSameDateChangedOriginalRefusesAndRestoresActualBytes() async throws {
        let f = try fixture()
        try write("changed!", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        try FileManager.default.setAttributes([.modificationDate: original.file.modifiedAt], ofItemAtPath: f.root.appendingPathComponent("photo.jpg").path)
        do {
            try await LocalEndpointSession(endpoint: f.endpoint).importFilesTransactionallyMatching([output], replacing: [original], preserveDate: true, verifySize: true)
            XCTFail("A stat-identical content change must fail")
        } catch {}
        XCTAssertEqual(try read("photo.jpg", fixture: f), "changed!")
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
    }

    func testRawGuardReturnsSameInodeAndDateWhileCreatingAbsentSidecar() async throws {
        let f = try fixture()
        try write("RAW bytes", "photo.cr3", fixture: f)
        let path = f.root.appendingPathComponent("photo.cr3").path
        let before = try FileManager.default.attributesOfItem(atPath: path)
        let original = try staged("photo.cr3", contents: "RAW bytes", fixture: f, prefix: "raw")
        let output = try staged("photo.xmp", contents: "new sidecar", fixture: f, prefix: "xmp")
        try await LocalEndpointSession(endpoint: f.endpoint).importFilesTransactionallyMatching([output], replacing: [original], preserveDate: true, verifySize: true)
        let after = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(try read("photo.cr3", fixture: f), "RAW bytes")
        XCTAssertEqual(try read("photo.xmp", fixture: f), "new sidecar")
    }

    func testNewSidecarCollisionNeverOverwritesConcurrentFileAndRestoresRaw() async throws {
        let f = try fixture()
        try write("RAW", "photo.cr3", fixture: f)
        let original = try staged("photo.cr3", contents: "RAW", fixture: f, prefix: "raw")
        let output = try staged("photo.xmp", contents: "new", fixture: f, prefix: "new")
        let target = f.root.appendingPathComponent("photo.xmp")
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
            if case .originalsHeld = phase { try Data("concurrent".utf8).write(to: target) }
        })
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: [original], preserveDate: false, verifySize: true)
            XCTFail("Concurrent sidecar must block publication")
        } catch {}
        XCTAssertEqual(try read("photo.xmp", fixture: f), "concurrent")
        XCTAssertEqual(try read("photo.cr3", fixture: f), "RAW")
    }

    func testConcurrentEditOfPublishedOutputIsPreservedAndOriginalBackupRetained() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        let target = f.root.appendingPathComponent("photo.jpg")
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
            if case .published = phase { try Data("concurrent edit".utf8).write(to: target) }
        })
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: [original], preserveDate: false, verifySize: true)
            XCTFail("Concurrent edit must stop commit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Recover retained files"))
        }
        XCTAssertEqual(try read("photo.jpg", fixture: f), "concurrent edit")
        let backups = try recoveryFiles(f).filter { $0.lastPathComponent.hasPrefix("original-held") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: XCTUnwrap(backups.first)), as: UTF8.self), "original")
    }

    func testFinalHeldOriginalRecheckRejectsLateMutation() async throws {
        let f = try fixture()
        try write("original", "photo.jpg", fixture: f)
        let original = try staged("photo.jpg", contents: "original", fixture: f, prefix: "old")
        let output = try staged("photo.jpg", contents: "processed", fixture: f, prefix: "new")
        let root = f.root
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
            if case .beforeCommit = phase {
                let recovery = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasSuffix(".transaction") }!
                try Data("late original edit".utf8).write(to: recovery.appendingPathComponent("original-held-0"))
            }
        })
        do {
            try await session.importFilesTransactionallyMatching([output], replacing: [original], preserveDate: true, verifySize: true)
            XCTFail("Late original mutation must prevent commit")
        } catch {}
        XCTAssertEqual(try read("photo.jpg", fixture: f), "late original edit")
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
    }

    func testFailureAfterFirstOutputRollsBackWholeImageSidecarPair() async throws {
        let f = try fixture()
        try write("image old", "photo.jpg", fixture: f)
        try write("xmp old", "photo.xmp", fixture: f)
        let originals = try [staged("photo.jpg", contents: "image old", fixture: f, prefix: "old"), staged("photo.xmp", contents: "xmp old", fixture: f, prefix: "old")]
        let outputs = try [staged("photo.jpg", contents: "image new", fixture: f, prefix: "new"), staged("photo.xmp", contents: "xmp new", fixture: f, prefix: "new")]
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
            if case .published(0) = phase { throw CancellationError() }
        })
        do {
            try await session.importFilesTransactionallyMatching(outputs, replacing: originals, preserveDate: true, verifySize: true)
            XCTFail("Injected cancellation must abort the group")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try read("photo.jpg", fixture: f), "image old")
        XCTAssertEqual(try read("photo.xmp", fixture: f), "xmp old")
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
    }
}
