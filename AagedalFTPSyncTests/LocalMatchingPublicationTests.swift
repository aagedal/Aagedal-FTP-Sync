import Darwin
import Foundation
import XCTest
@testable import AagedalFTPSync

final class LocalMatchingPublicationTests: XCTestCase {
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
        let root = base.appendingPathComponent("destination")
        let inputs = base.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let bookmark = try FolderBookmark.create(for: root)
        return (Fixture(root: root, inputs: inputs, endpoint: Endpoint(kind: .local,
            localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)), phase)
    }

    func testProcessInterruptionWorker() async throws {
        let (f, requestedPhase) = try interruptionFixture()
        try write("original RAW", "nested/photo.cr3", fixture: f)
        try write("original XMP", "nested/photo.xmp", fixture: f)
        let raw = try staged("nested/photo.cr3", contents: "original RAW", fixture: f, prefix: "raw")
        let xmp = try staged("nested/photo.xmp", contents: "original XMP", fixture: f, prefix: "xmp")
        let output = try staged("nested/photo.xmp", contents: "processed XMP", fixture: f, prefix: "output")
        let marker = f.inputs.appendingPathComponent("interrupted-phase")
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
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
            // Signal delivery can follow the syscall return. Do not race it with
            // exit(), which would obscure whether SIGKILL actually killed us.
            while true { pause() }
        })
        try await session.importFilesTransactionallyMatching([output], replacing: [raw, xmp],
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
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.originals.map(\.relativePath), ["nested/photo.cr3", "nested/photo.xmp"])
        XCTAssertEqual(manifest.originals.map(\.isReplaced), [false, true])
        XCTAssertEqual(manifest.outputs.map(\.relativePath), ["nested/photo.xmp"])
        let held = phase != "prepared"
        let published = phase == "published-0" || phase == "beforeCommit"
        for (index, original) in manifest.originals.enumerated() {
            let expected = Data((index == 0 ? "original RAW" : "original XMP").utf8)
            XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(original.snapshotFilename)), expected)
            XCTAssertEqual(FileManager.default.fileExists(atPath: recovery.appendingPathComponent(original.heldFilename).path), held)
            if held {
                XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(original.heldFilename)), expected)
            }
            let exists = FileManager.default.fileExists(atPath: f.root.appendingPathComponent(original.relativePath).path)
            XCTAssertEqual(exists, !held || (index == 1 && published))
        }
        if published { XCTAssertEqual(try read("nested/photo.xmp", fixture: f), "processed XMP") }
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        XCTAssertThrowsError(try session.validateMetadataRecoveryIsResolved()) { error in
            XCTAssertTrue(error.localizedDescription.contains(recovery.path))
        }
        // Follow the documented manual choice: retain the published XMP if present,
        // otherwise restore the originals. Guard-only RAW must always be restored.
        for original in manifest.originals {
            let destination = f.root.appendingPathComponent(original.relativePath)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: recovery.appendingPathComponent(original.heldFilename), to: destination)
            }
        }
        XCTAssertEqual(try read("nested/photo.cr3", fixture: f), "original RAW")
        XCTAssertEqual(try read("nested/photo.xmp", fixture: f), published ? "processed XMP" : "original XMP")
        try FileManager.default.removeItem(at: recovery)
        try session.validateMetadataRecoveryIsResolved()
        let raw = try staged("nested/photo.cr3", contents: "original RAW", fixture: f, prefix: "retry-raw")
        let xmp = try staged("nested/photo.xmp", contents: published ? "processed XMP" : "original XMP", fixture: f, prefix: "retry-xmp")
        let output = try staged("nested/photo.xmp", contents: "retried XMP", fixture: f, prefix: "retry-output")
        try await session.importFilesTransactionallyMatching([output], replacing: [raw, xmp],
            preserveDate: true, verifySize: true)
        XCTAssertEqual(try read("nested/photo.cr3", fixture: f), "original RAW")
        XCTAssertEqual(try read("nested/photo.xmp", fixture: f), "retried XMP")
        XCTAssertTrue(try recoveryFiles(f).isEmpty)
        try Data(phase.utf8).write(to: f.inputs.appendingPathComponent("recovery-verified"), options: .atomic)
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
