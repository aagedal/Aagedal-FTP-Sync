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
