import CryptoKit
import Foundation
import XCTest
@testable import AagedalFTPSync

@MainActor
final class PeopleLibraryControllerTests: XCTestCase {
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


    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("people-controller-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testImportFailureAndExportCollisionRetainSelectionAndSanitizeErrors() async throws {
        let parent = try directory()
        let repository = PeopleLibraryRepository(root: parent.appendingPathComponent("installed"))
        let source = try fixture(in: parent, name: "valid.aagedalpeople", library: "11111111-1111-1111-1111-111111111111", person: "22222222-2222-2222-2222-222222222222")
        let controller = PeopleLibraryController(repository: repository)
        await controller.refresh()
        XCTAssertEqual(controller.state, .unselected)
        await controller.importPackage(at: source)
        let selected = controller.state
        guard case .selected(let summary) = selected else { return XCTFail("Import must select library") }
        XCTAssertEqual(summary.peopleCount, 1)
        await controller.importPackage(at: parent.appendingPathComponent("private-source-secret.aagedalpeople"))
        XCTAssertEqual(controller.state, selected)
        XCTAssertFalse(try XCTUnwrap(controller.message).contains("private-source-secret"))
        await controller.exportPackage(to: source)
        XCTAssertEqual(controller.state, selected)
        XCTAssertNotNil(controller.message)
        let export = parent.appendingPathComponent("export.aagedalpeople")
        await controller.exportPackage(to: export)
        XCTAssertNil(controller.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("manifest.json").path))
        await controller.removeCurrentLibrary()
        XCTAssertEqual(controller.state, .unselected)
        XCTAssertNil(try repository.currentSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
    }
    func testSuspensionBlocksNewOperationsWithoutCreatingStorage() async throws {
        let parent = try directory()
        let root = parent.appendingPathComponent("installed")
        let controller = PeopleLibraryController(repository: .init(root: root))
        controller.suspend()
        await controller.refresh()
        await controller.importPackage(at: parent.appendingPathComponent("missing.aagedalpeople"))
        await controller.removeCurrentLibrary()
        XCTAssertTrue(controller.suspended)
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testCorruptPointerRefreshHasSanitizedFailure() async throws {
        let parent = try directory()
        let root = parent.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("private-data-not-json".utf8).write(to: root.appendingPathComponent("current.json"))
        let controller = PeopleLibraryController(repository: .init(root: root))
        await controller.refresh()
        XCTAssertEqual(controller.state, .failure)
        XCTAssertEqual(controller.message, "The people library could not be read.")
        XCTAssertFalse(controller.busy)
    }
    func testInFlightSuspensionKeepsWorkerOccupiedAndRejectsStaleSummary() async throws {
        let parent = try directory()
        let source = try fixture(in: parent, name: "valid.aagedalpeople", library: "11111111-1111-1111-1111-111111111111", person: "22222222-2222-2222-2222-222222222222")
        let reached = expectation(description: "Reached activation boundary")
        let release = DispatchSemaphore(value: 0)
        let repository = PeopleLibraryRepository(root: parent.appendingPathComponent("installed"), beforeActivate: {
            reached.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            try Task.checkCancellation()
        })
        let controller = PeopleLibraryController(repository: repository)
        await controller.refresh()
        let task = Task { await controller.importPackage(at: source) }
        await fulfillment(of: [reached], timeout: 3)
        XCTAssertTrue(controller.busy)
        // A second operation cannot reset busy or replace the in-flight worker.
        await controller.removeCurrentLibrary()
        XCTAssertTrue(controller.busy)
        controller.suspend()
        XCTAssertTrue(controller.busy)
        release.signal()
        await task.value
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.state, .unselected)
        XCTAssertNil(try repository.currentSnapshot())
    }

}
