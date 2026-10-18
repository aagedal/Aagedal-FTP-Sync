import Foundation
import XCTest
@testable import AagedalFTPSync

final class LocalOrdinaryPublicationTests: XCTestCase {
    func testFreshRawSidecarPublicationPreservesBytesDatesAndRemovesRecovery() async throws {
        for onlyIfAbsent in [false, true] {
            let f = try fixture()
            let outputs = try pair(f)
            let session = try LocalEndpointSession(endpoint: f.endpoint)
            try await publish(outputs, session: session, onlyIfAbsent: onlyIfAbsent)
            for output in outputs {
                let visible = f.root.appendingPathComponent(output.file.relativePath)
                XCTAssertEqual(try Data(contentsOf: visible), try Data(contentsOf: output.localURL))
                XCTAssertEqual(try visible.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                               output.file.modifiedAt)
            }
            XCTAssertTrue(try recoveryDirectories(f).isEmpty)
            try LocalEndpointSession(endpoint: f.endpoint).validateMetadataRecoveryIsResolved()
        }
    }

    func testOrdinaryReplacementPublishesWholePairAndRemovesRecovery() async throws {
        let f = try fixture()
        try seedOriginals(f)
        let session = try LocalEndpointSession(endpoint: f.endpoint)
        let existing = try await session.listFiles()
        let outputs = try pair(f)
        try await session.importFilesTransactionally(outputs, replacing: existing, preserveDate: true, verifySize: true)
        XCTAssertEqual(try read("nested/photo.cr3", f), "new RAW bytes")
        XCTAssertEqual(try read("nested/photo.xmp", f), "new sidecar")
        XCTAssertTrue(try recoveryDirectories(f).isEmpty)
    }

    func testFailureAfterFirstFreshOutputRollsBackWholePair() async throws {
        for onlyIfAbsent in [false, true] {
            let f = try fixture()
            let outputs = try pair(f)
            let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
                if case .published(0) = phase { throw CancellationError() }
            })
            do {
                try await publish(outputs, session: session, onlyIfAbsent: onlyIfAbsent)
                XCTFail("The injected cancellation must interrupt ordinary publication")
            } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
            for output in outputs {
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(output.file.relativePath).path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: output.localURL.path))
            }
            XCTAssertTrue(try recoveryDirectories(f).isEmpty)
        }
    }

    func testFailureAfterFirstReplacementRestoresOriginalPairAndDates() async throws {
        let f = try fixture()
        try seedOriginals(f)
        let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
            if case .published(0) = phase { throw CancellationError() }
        })
        let existing = try await session.listFiles()
        let originalInodes = try Dictionary(uniqueKeysWithValues: existing.keys.map { path in
            (path, try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent(path).path)[.systemFileNumber] as? NSNumber))
        })
        let outputs = try pair(f)
        do {
            try await session.importFilesTransactionally(outputs, replacing: existing, preserveDate: true, verifySize: true)
            XCTFail("The injected cancellation must interrupt replacement")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try read("nested/photo.cr3", f), "old RAW bytes")
        XCTAssertEqual(try read("nested/photo.xmp", f), "old sidecar")
        for file in existing.values {
            XCTAssertEqual(try f.root.appendingPathComponent(file.relativePath)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, file.modifiedAt)
            XCTAssertEqual(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent(file.relativePath).path)[.systemFileNumber] as? NSNumber),
                           try XCTUnwrap(originalInodes[file.relativePath]))
        }
        XCTAssertTrue(try recoveryDirectories(f).isEmpty)
    }

    func testFreshConcurrentEditedOutputRetainsRecoveryAndBlocksAdmission() async throws {
        for onlyIfAbsent in [false, true] {
            for replaceInode in [false, true] {
                let f = try fixture()
                let outputs = try pair(f)
                let target = f.root.appendingPathComponent("nested/photo.cr3")
                let edit = Data("reviewed fresh RAW edit".utf8)
                let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
                    if case .published(0) = phase {
                        if replaceInode { try edit.write(to: target, options: .atomic) }
                        else { try edit.write(to: target) }
                        throw CancellationError()
                    }
                })
                do {
                    try await publish(outputs, session: session, onlyIfAbsent: onlyIfAbsent)
                    XCTFail("A fresh concurrently edited publication must retain recovery")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Recover retained files"), error.localizedDescription)
                }
                XCTAssertEqual(try Data(contentsOf: target), edit)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("nested/photo.xmp").path))
                let recovery = try XCTUnwrap(recoveryDirectories(f).only)
                let manifestURL = recovery.appendingPathComponent("recovery.json")
                let manifestBytes = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self, from: manifestBytes)
                XCTAssertTrue(manifest.originals.isEmpty)
                XCTAssertEqual(manifest.outputs.map(\.relativePath), outputs.map(\.file.relativePath))
                for (record, output) in zip(manifest.outputs, outputs) {
                    XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(record.snapshotFilename)),
                                   try Data(contentsOf: output.localURL))
                }
                let reopened = try LocalEndpointSession(endpoint: f.endpoint)
                XCTAssertThrowsError(try reopened.validateMetadataRecoveryIsResolved()) { error in
                    assertRecoveryPath(error, equals: recovery)
                }
                XCTAssertEqual(try Data(contentsOf: target), edit)
                XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
            }
        }
    }

    func testConcurrentEditedOrReplacedPublicationPreservesEditAndRetainsOriginal() async throws {
        for replaceInode in [false, true] {
            let f = try fixture()
            try seedOriginals(f)
            let target = f.root.appendingPathComponent("nested/photo.cr3")
            let edit = Data("reviewed RAW edit".utf8)
            let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
                if case .published(0) = phase {
                    if replaceInode {
                        try edit.write(to: target, options: .atomic)
                    } else {
                        try edit.write(to: target)
                    }
                    throw CancellationError()
                }
            })
            let existing = try await session.listFiles()
            let outputs = try pair(f)
            do {
                try await session.importFilesTransactionally(outputs, replacing: existing, preserveDate: true, verifySize: true)
                XCTFail("A concurrent edit must prevent rollback from replacing it")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Recover retained files"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: target), edit)
            XCTAssertEqual(try read("nested/photo.xmp", f), "old sidecar")
            let recovery = try XCTUnwrap(recoveryDirectories(f).only)
            let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self,
                from: Data(contentsOf: recovery.appendingPathComponent("recovery.json")))
            let original = try XCTUnwrap(manifest.originals.first { $0.relativePath == "nested/photo.cr3" })
            XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(original.heldFilename)), Data("old RAW bytes".utf8))
            let output = try XCTUnwrap(manifest.outputs.first { $0.relativePath == "nested/photo.cr3" })
            XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(output.snapshotFilename)), Data("new RAW bytes".utf8))
            XCTAssertThrowsError(try LocalEndpointSession(endpoint: f.endpoint).validateMetadataRecoveryIsResolved())
        }
    }

    func testCleanupFailureRetainsManifestAndBlocksFreshSessionAdmission() async throws {
        for onlyIfAbsent in [false, true] {
            let f = try fixture()
            let outputs = try pair(f)
            let session = try LocalEndpointSession(endpoint: f.endpoint, matchingRecoveryRemoval: { _ in
                throw CocoaError(.fileWriteNoPermission)
            })
            do {
                try await publish(outputs, session: session, onlyIfAbsent: onlyIfAbsent)
                XCTFail("A retained recovery folder must not report success")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("cleanup failed"), error.localizedDescription)
            }
            let recovery = try XCTUnwrap(recoveryDirectories(f).only)
            let manifestBytes = try Data(contentsOf: recovery.appendingPathComponent("recovery.json"))
            let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self, from: manifestBytes)
            XCTAssertTrue(manifest.originals.isEmpty)
            XCTAssertEqual(manifest.outputs.map(\.relativePath), outputs.map(\.file.relativePath))
            let reopened = try LocalEndpointSession(endpoint: f.endpoint)
            XCTAssertThrowsError(try reopened.validateMetadataRecoveryIsResolved()) { error in
                assertRecoveryPath(error, equals: recovery)
            }
            for output in outputs {
                XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(output.file.relativePath)),
                               try Data(contentsOf: output.localURL))
            }
            XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("recovery.json")), manifestBytes)
        }
    }

    func testDuplicateOutputPathsAreRejectedBeforePublication() async throws {
        for onlyIfAbsent in [false, true] {
            let f = try fixture()
            let output = try XCTUnwrap(pair(f).first)
            let session = try LocalEndpointSession(endpoint: f.endpoint)
            do {
                try await publish([output, output], session: session, onlyIfAbsent: onlyIfAbsent)
                XCTFail("Duplicate destination paths must fail")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(output.file.relativePath).path))
            XCTAssertTrue(try recoveryDirectories(f).isEmpty)
        }
    }

    func testUnforeseenSidecarCollisionPreservesConcurrentFileAndRollsBackRaw() async throws {
        for onlyIfAbsent in [false, true] {
            let f = try fixture()
            let outputs = try pair(f)
            let collision = f.root.appendingPathComponent("nested/photo.xmp")
            let session = try LocalEndpointSession(endpoint: f.endpoint, matchingImportHook: { phase in
                if case .prepared = phase { try Data("concurrent sidecar".utf8).write(to: collision) }
            })
            do {
                try await publish(outputs, session: session, onlyIfAbsent: onlyIfAbsent)
                XCTFail("A destination absent from the listing must not be overwritten")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: collision), Data("concurrent sidecar".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("nested/photo.cr3").path))
            XCTAssertTrue(try recoveryDirectories(f).isEmpty)
        }
    }

    #if DEBUG
    func testOrdinaryRawReconciliationPreservesEvidenceAndIsIdempotent() throws {
        for managed in [false, true] {
            let f = try reconciliationFixture(managed: managed)
            let before = try fileEvidence(in: f.base)
            try UITestSupport.reconcileInterruptedOrdinarySyncFixture(rootURL: f.base, managed: managed, raw: true, rawExtension: "cr3")
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.recovery.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("recovery.cr3").path))
            for (path, bytes) in before {
                let moved: URL
                if path == f.destination.appendingPathComponent("recovery.cr3").path {
                    moved = f.base.appendingPathComponent("rescued-ordinary-publication")
                } else if path.hasPrefix(f.recovery.path + "/") {
                    moved = f.base.appendingPathComponent("reconciled-ordinary-sync")
                        .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                } else {
                    moved = URL(fileURLWithPath: path)
                }
                XCTAssertEqual(try Data(contentsOf: moved), bytes)
            }
            let reconciled = try fileEvidence(in: f.base)
            try UITestSupport.reconcileInterruptedOrdinarySyncFixture(rootURL: f.base, managed: managed, raw: true, rawExtension: "cr3")
            XCTAssertEqual(try fileEvidence(in: f.base), reconciled)
        }
    }

    func testOrdinaryRawReconciliationRejectsEitherChangedSourceBeforeMovingEvidence() throws {
        for managed in [false, true] {
            for changedName in ["recovery.cr3", "recovery.xmp"] {
                let f = try reconciliationFixture(managed: managed)
                try Data("changed source".utf8).write(to: f.base.appendingPathComponent("Source/" + changedName))
                let before = try fileEvidence(in: f.base)
                XCTAssertThrowsError(try UITestSupport.reconcileInterruptedOrdinarySyncFixture(
                    rootURL: f.base, managed: managed, raw: true, rawExtension: "cr3"))
                XCTAssertEqual(try fileEvidence(in: f.base), before)
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.recovery.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("rescued-ordinary-publication").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("reconciled-ordinary-sync").path))
            }
        }
    }

    private func reconciliationFixture(managed: Bool) throws -> (base: URL, destination: URL, recovery: URL) {
        let base = (try Version3StartupPaths.canonicalDirectory(FileManager.default.temporaryDirectory))
            .appendingPathComponent("ordinary-reconcile-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent(managed ? "Destination/Synced Files" : "Destination")
        let recovery = destination.appendingPathComponent(".aagedal-sync-test.transaction")
        for directory in [base.appendingPathComponent("Source"), destination.appendingPathComponent("nested"), recovery] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (name, contents) in [("recovery.cr3", "opaque camera RAW"), ("recovery.xmp", "original camera XMP")] {
            for directory in [base.appendingPathComponent("Source"), destination.appendingPathComponent("nested")] {
                try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        try Data("opaque camera RAW".utf8).write(to: destination.appendingPathComponent("recovery.cr3"))
        try Data("opaque camera RAW".utf8).write(to: recovery.appendingPathComponent("output-copy-0"))
        for filename in ["output-stage-1", "output-copy-1"] {
            try Data("enriched camera XMP".utf8).write(to: recovery.appendingPathComponent(filename))
        }
        let manifest = LocalEndpointSession.MatchingRecoveryManifest(schemaVersion: 1, originals: [],
            outputs: ["recovery.cr3", "recovery.xmp"].enumerated().map { index, path in
                .init(relativePath: path, stagedFilename: "output-stage-\(index)",
                      snapshotFilename: "output-copy-\(index)", rollbackFilename: "rollback-output-\(index)")
            })
        try JSONEncoder().encode(manifest).write(to: recovery.appendingPathComponent("recovery.json"))
        try Data("published-0".utf8).write(to: base.appendingPathComponent("native-image-interruption"))
        try Data("seeded".utf8).write(to: base.appendingPathComponent("metadata-recovery-fixture-seeded"))
        return (base, destination, recovery)
    }

    private func fileEvidence(in root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var evidence: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                evidence[url.path] = try Data(contentsOf: url)
            }
        }
        return evidence
    }
    #endif

    private func assertRecoveryPath(_ error: Error, equals recovery: URL) {
        do {
            let message = error.localizedDescription
            let start = try XCTUnwrap(message.range(of: "remains at "))
            let end = try XCTUnwrap(message.range(of: ". Recover the retained files"))
            let reported = URL(fileURLWithPath: String(message[start.upperBound..<end.lowerBound]))
            XCTAssertEqual(try Version3StartupPaths.canonicalDirectory(reported),
                           try Version3StartupPaths.canonicalDirectory(recovery))
        } catch { XCTFail("Invalid recovery path: \(error)") }
    }

    private struct Fixture {
        let root: URL
        let inputs: URL
        let endpoint: Endpoint
    }

    private func fixture() throws -> Fixture {
        let base = (try Version3StartupPaths.canonicalDirectory(FileManager.default.temporaryDirectory))
            .appendingPathComponent("ordinary-publication-\(UUID())")
        let root = base.appendingPathComponent("destination")
        let inputs = base.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let bookmark = try FolderBookmark.create(for: root)
        return Fixture(root: root, inputs: inputs,
            endpoint: Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data))
    }

    private func pair(_ f: Fixture) throws -> [EndpointFileImport] {
        try [("nested/photo.cr3", "new RAW bytes"), ("nested/photo.xmp", "new sidecar")].map { name, contents in
            let input = f.inputs.appendingPathComponent(UUID().uuidString)
            let bytes = Data(contents.utf8)
            try bytes.write(to: input)
            return EndpointFileImport(localURL: input,
                file: SyncFile(relativePath: name, size: Int64(bytes.count), modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        }
    }

    private func seedOriginals(_ f: Fixture) throws {
        for (name, contents) in [("nested/photo.cr3", "old RAW bytes"), ("nested/photo.xmp", "old sidecar")] {
            let target = f.root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: target)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: target.path)
        }
    }

    private func publish(_ outputs: [EndpointFileImport], session: LocalEndpointSession, onlyIfAbsent: Bool) async throws {
        if onlyIfAbsent {
            try await session.importFilesTransactionallyIfAbsent(outputs, preserveDate: true, verifySize: true)
        } else {
            try await session.importFilesTransactionally(outputs, replacing: [:], preserveDate: true, verifySize: true)
        }
    }

    private func read(_ name: String, _ f: Fixture) throws -> String {
        String(decoding: try Data(contentsOf: f.root.appendingPathComponent(name)), as: UTF8.self)
    }

    private func recoveryDirectories(_ f: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".transaction") }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
