import CryptoKit
import Foundation
import XCTest
@testable import AagedalFTPSync

final class PeopleLibraryRepositoryTests: XCTestCase {
    private enum Injected: Error { case failure }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func fixture(in parent: URL, name: String, library: String, person: String,
                         exportedAt: String = "2026-09-12T10:00:00.000Z", reverseFiles: Bool = false) throws -> URL {
        let source = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("embeddings"), withIntermediateDirectories: true)
        let libraryID = UUID(uuidString: library)!, personID = UUID(uuidString: person)!
        let exampleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var raw = [Float](repeating: 0, count: 512); raw[0] = 1
        let vector = FaceRecognitionEmbeddingCodec.encode(try .init(validatingNormalized: raw))
        let embeddingPath = "embeddings/\(exampleID.uuidString.lowercased()).fem2"
        try vector.write(to: source.appendingPathComponent(embeddingPath))
        let example = try PeopleLibraryPayload.Example(id: exampleID, embeddingPath: embeddingPath)
        let payload = try PeopleLibraryPayload(people: [.init(id: personID, name: "Person \(person)", examples: [example])])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadBytes = try encoder.encode(payload)
        try payloadBytes.write(to: source.appendingPathComponent("people.json"))
        var files: [PeopleLibraryManifest.FileDeclaration] = [
            try .init(path: "people.json", byteCount: payloadBytes.count, sha256: sha(payloadBytes)),
            try .init(path: embeddingPath, byteCount: vector.count, sha256: sha(vector)),
        ]
        if reverseFiles { files.reverse() }
        let manifest = try PeopleLibraryManifest(libraryID: libraryID, exportedAt: exportedAt,
            exporter: .init(app: "Photo Agent", version: "3", sourceRevision: String(repeating: "c", count: 40)),
            peopleCount: 1, embeddingCount: 1, files: files)
        try encoder.encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        return source
    }

    func testImportReplaceRemoveAndHeldSnapshotLifetime() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("people-library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("installed", isDirectory: true)
        let repository = PeopleLibraryRepository(root: root)
        let firstSource = try fixture(in: parent, name: "first", library: "11111111-1111-1111-1111-111111111111",
            person: "22222222-2222-2222-2222-222222222222")
        let first = try repository.importSnapshot(from: firstSource)
        XCTAssertEqual(try repository.currentSnapshot()?.manifest.revision, first.manifest.revision)
        let secondSource = try fixture(in: parent, name: "second", library: "44444444-4444-4444-4444-444444444444",
            person: "55555555-5555-5555-5555-555555555555")
        let second = try repository.importSnapshot(from: secondSource)
        XCTAssertEqual(try repository.currentSnapshot()?.manifest.libraryID, second.manifest.libraryID)
        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertEqual(first.gallery.people.first?.id.uuidString.lowercased(), "22222222-2222-2222-2222-222222222222")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directoryURL.path))
        try repository.removeCurrentSnapshot()
        XCTAssertNil(try repository.currentSnapshot())
        XCTAssertEqual(first.gallery.people.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directoryURL.path))
    }

    func testFailedReplacementAndPreActivationFaultPreserveCurrentSelection() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("people-library-failure-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("installed", isDirectory: true)
        let source = try fixture(in: parent, name: "good", library: "11111111-1111-1111-1111-111111111111",
            person: "22222222-2222-2222-2222-222222222222")
        let repository = PeopleLibraryRepository(root: root)
        let current = try repository.importSnapshot(from: source)
        let corrupt = try fixture(in: parent, name: "corrupt", library: "44444444-4444-4444-4444-444444444444",
            person: "55555555-5555-5555-5555-555555555555")
        let path = corrupt.appendingPathComponent("embeddings/33333333-3333-3333-3333-333333333333.fem2")
        var bytes = try Data(contentsOf: path); bytes[8] ^= 1; try bytes.write(to: path)
        XCTAssertThrowsError(try repository.importSnapshot(from: corrupt))
        XCTAssertEqual(try repository.currentSnapshot()?.manifest.revision, current.manifest.revision)
        let other = try fixture(in: parent, name: "other", library: "66666666-6666-6666-6666-666666666666",
            person: "77777777-7777-7777-7777-777777777777")
        let failing = PeopleLibraryRepository(root: root, beforeActivate: { throw Injected.failure })
        XCTAssertThrowsError(try failing.importSnapshot(from: other))
        XCTAssertEqual(try repository.currentSnapshot()?.manifest.revision, current.manifest.revision)
    }

    func testEquivalentReexportWithNewTimestampReusesImmutableRevision() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("people-library-reexport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let firstSource = try fixture(in: parent, name: "first", library: "11111111-1111-1111-1111-111111111111",
            person: "22222222-2222-2222-2222-222222222222")
        let secondSource = try fixture(in: parent, name: "second", library: "11111111-1111-1111-1111-111111111111",
            person: "22222222-2222-2222-2222-222222222222", exportedAt: "2026-09-12T11:00:00.000Z",
            reverseFiles: true)
        let repository = PeopleLibraryRepository(root: parent.appendingPathComponent("installed"))
        let first = try repository.importSnapshot(from: firstSource)
        let second = try repository.importSnapshot(from: secondSource)
        XCTAssertEqual(first.manifest.revision, second.manifest.revision)
        XCTAssertEqual(first.directoryURL, second.directoryURL)
    }

    func testCurrentSelectionRejectsTamperedBytesPointersAndWritableRoot() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("people-library-tamper-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("installed", isDirectory: true)
        let source = try fixture(in: parent, name: "source", library: "11111111-1111-1111-1111-111111111111",
            person: "22222222-2222-2222-2222-222222222222")
        let repository = PeopleLibraryRepository(root: root)
        let snapshot = try repository.importSnapshot(from: source)
        let installedVector = snapshot.directoryURL
            .appendingPathComponent("embeddings/33333333-3333-3333-3333-333333333333.fem2")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installedVector.path)
        var bytes = try Data(contentsOf: installedVector); bytes[8] ^= 1; try bytes.write(to: installedVector)
        XCTAssertThrowsError(try repository.currentSnapshot())

        let pointer = root.appendingPathComponent("current.json")
        let selection = UUID().uuidString.lowercased()
        try Data("{\"schemaVersion\":1,\"schemaVersion\":1,\"selectionID\":\"\(selection)\"}".utf8)
            .write(to: pointer, options: .atomic)
        XCTAssertThrowsError(try repository.currentSnapshot())
        try Data("{\"schemaVersion\":1,\"selectionID\":\"\(selection)\",\"libraryID\":null,\"revision\":null}".utf8)
            .write(to: pointer, options: .atomic)
        XCTAssertThrowsError(try repository.currentSnapshot())

        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: root.path)
        XCTAssertThrowsError(try repository.currentSnapshot()) {
            XCTAssertEqual($0 as? PeopleLibraryRepository.Failure, .unsafeFile)
        }
    }
}
