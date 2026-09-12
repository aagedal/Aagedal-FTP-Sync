import CryptoKit
import Foundation
import XCTest
@testable import AagedalFTPSync

final class PeopleLibraryPackageServiceTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let repository: PeopleLibraryRepository
        let snapshot: PeopleLibrarySnapshot
    }
    private enum Failure: Error { case injected }
    private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("people-package-\(UUID())")
        let source = parent.appendingPathComponent("source.aagedalpeople")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("embeddings"), withIntermediateDirectories: true)
        addTeardownBlock {
            if let entries = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil) {
                for case let url as URL in entries { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
            }
            try? FileManager.default.removeItem(at: parent)
        }
        let exampleID = UUID(), personID = UUID()
        var values = [Float](repeating: 0, count: 512); values[0] = 1
        let vector = FaceRecognitionEmbeddingCodec.encode(try .init(validatingNormalized: values))
        let path = "embeddings/\(exampleID.uuidString.lowercased()).fem2"
        let example = try PeopleLibraryPayload.Example(id: exampleID, embeddingPath: path)
        let payload = try PeopleLibraryPayload(people: [.init(id: personID, name: "  {persons}, Å  ", examples: [example])])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        let manifest = try PeopleLibraryManifest(libraryID: UUID(), exportedAt: "2026-09-12T12:00:00.000Z",
            exporter: .init(app: "Fixture", version: "3", sourceRevision: String(repeating: "a", count: 40)),
            peopleCount: 1, embeddingCount: 1, files: [
                .init(path: "people.json", byteCount: bytes.count, sha256: sha(bytes)),
                .init(path: path, byteCount: vector.count, sha256: sha(vector))])
        try bytes.write(to: source.appendingPathComponent("people.json"))
        try vector.write(to: source.appendingPathComponent(path))
        try encoder.encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        let repository = PeopleLibraryRepository(root: parent.appendingPathComponent("installed"))
        return .init(parent: parent, repository: repository, snapshot: try repository.importSnapshot(from: source))
    }
    private func stages(_ f: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: f.parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".aagedalpeople-export-") }
    }
    private func assertNoStages(_ f: Fixture) throws {
        XCTAssertTrue(try stages(f).isEmpty)
    }

    func testCommittedCrossAppGoldenPackageAndExactReexport() throws {
        let repositoryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("people-golden-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: repositoryRoot) }
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: false)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Documentation/Testing/Fixtures/people-library-v2.aagedalpeople")
        let repository = PeopleLibraryRepository(root: repositoryRoot.appendingPathComponent("repository"))
        let snapshot = try PeopleLibraryPackageService().importPackage(at: fixture, into: repository)
        XCTAssertEqual(snapshot.manifest.coreRevision, "636f498dba7a9bb357ece23e2f5edcd02997fb4df1acc1e1101eecfd32438e83")
        XCTAssertEqual(snapshot.manifest.revision, "12324ae00b79094d239447531d81348e4c6450b7a65fbc329daab261c08025ba")
        let output = repositoryRoot.appendingPathComponent("roundtrip.aagedalpeople")
        try PeopleLibraryPackageService().export(snapshot, to: output)
        for path in snapshot.manifest.files.map(\.path) + [PeopleLibraryManifest.fileName] {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)),
                           try Data(contentsOf: fixture.appendingPathComponent(path)), path)
        }
    }

    func testExactByteExportAndImportIntoSeparateRepository() throws {
        let f = try fixture(), service = PeopleLibraryPackageService()
        let output = f.parent.appendingPathComponent("shared.aagedalpeople")
        XCTAssertEqual(try service.export(f.snapshot, to: output), output)
        let paths = f.snapshot.manifest.files.map(\.path) + [PeopleLibraryManifest.fileName]
        for path in paths {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)),
                           try Data(contentsOf: f.snapshot.directoryURL.appendingPathComponent(path)))
        }
        let receiver = PeopleLibraryRepository(root: f.parent.appendingPathComponent("receiver"))
        let imported = try service.importPackage(at: output, into: receiver)
        XCTAssertEqual(imported.manifest, f.snapshot.manifest)
        XCTAssertEqual(imported.gallery, f.snapshot.gallery)
        XCTAssertEqual(imported.gallery.people[0].name, "  {persons}, Å  ")
        XCTAssertEqual(try f.repository.currentSnapshot()?.manifest, f.snapshot.manifest)
        try assertNoStages(f)
    }

    func testEditorPayloadIsValidatedAndReexportedByteForByte() throws {
        let f = try fixture()
        let payloadBytes = try Data(contentsOf: f.snapshot.directoryURL.appendingPathComponent("people.json"))
        let payload = try PeopleLibraryPayload.decode(payloadBytes)
        let person = try XCTUnwrap(payload.people.first)
        let example = try XCTUnwrap(person.examples.first)
        let editorText = """
        { "examples" : {
            "\(example.id.uuidString.lowercased())" : { "recognitionMode" : "faceClothing", "addedAt" : 42.125,
              "sourceDescription" : "/private/source/Å.jpg" }
          },
          "people" : { "\(person.id.uuidString.lowercased())" : {
              "updatedAt" : 812345678.123456, "createdAt" : -0.125,
              "representativeThumbnailID" : "\(example.id.uuidString.lowercased())", "notes" : "  Preserve exactly {value}", "role" : "" } },
          "coreRevision" : "\(f.snapshot.manifest.coreRevision)", "libraryID" : "\(f.snapshot.manifest.libraryID.uuidString.lowercased())",
          "schemaVersion" : 1, "format" : "aagedal-photo-agent-known-people-editor" }
        """
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let editorBytes = Data(editorText.utf8)
        let descriptor = try PeopleLibraryManifest.EditorPayloadDescriptor(
            byteCount: editorBytes.count, sha256: sha(editorBytes)
        )
        let manifest = try PeopleLibraryManifest(
            libraryID: f.snapshot.manifest.libraryID,
            exportedAt: f.snapshot.manifest.exportedAt,
            exporter: f.snapshot.manifest.exporter,
            peopleCount: f.snapshot.manifest.peopleCount,
            embeddingCount: f.snapshot.manifest.embeddingCount,
            files: f.snapshot.manifest.files + [
                .init(path: descriptor.path, byteCount: descriptor.byteCount, sha256: descriptor.sha256)
            ],
            editorPayload: descriptor
        )
        let package = f.parent.appendingPathComponent("editor-source.aagedalpeople")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("embeddings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("editor"), withIntermediateDirectories: true)
        for declaration in f.snapshot.manifest.files {
            let source = f.snapshot.directoryURL.appendingPathComponent(declaration.path)
            let destination = package.appendingPathComponent(declaration.path)
            try Data(contentsOf: source).write(to: destination)
        }
        try editorBytes.write(to: package.appendingPathComponent(descriptor.path))
        try encoder.encode(manifest).write(to: package.appendingPathComponent(PeopleLibraryManifest.fileName))

        let repository = PeopleLibraryRepository(root: f.parent.appendingPathComponent("editor-receiver"))
        let imported = try PeopleLibraryPackageService().importPackage(at: package, into: repository)
        let output = f.parent.appendingPathComponent("editor-roundtrip.aagedalpeople")
        try PeopleLibraryPackageService().export(imported, to: output)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(descriptor.path)), editorBytes)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(PeopleLibraryManifest.fileName)),
                       try Data(contentsOf: imported.directoryURL.appendingPathComponent(PeopleLibraryManifest.fileName)))
        let secondRepository = PeopleLibraryRepository(root: f.parent.appendingPathComponent("editor-second-receiver"))
        let second = try PeopleLibraryPackageService().importPackage(at: output, into: secondRepository)
        let secondOutput = f.parent.appendingPathComponent("editor-second-roundtrip.aagedalpeople")
        try PeopleLibraryPackageService().export(second, to: secondOutput)
        XCTAssertEqual(try Data(contentsOf: secondOutput.appendingPathComponent(descriptor.path)), editorBytes)
        XCTAssertEqual(second.manifest.coreRevision, f.snapshot.manifest.coreRevision)
        XCTAssertNotEqual(second.manifest.revision, f.snapshot.manifest.revision)
    }

    func testExistingAndConcurrentlyCreatedDestinationsAreNeverReplaced() throws {
        let f = try fixture()
        let output = f.parent.appendingPathComponent("occupied.aagedalpeople")
        let sentinel = Data("Keep existing user content".utf8)
        let racing = PeopleLibraryPackageService(beforePublish: {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try sentinel.write(to: output.appendingPathComponent("sentinel"))
        })
        XCTAssertThrowsError(try racing.export(f.snapshot, to: output))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("sentinel")), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["sentinel"])
        XCTAssertThrowsError(try PeopleLibraryPackageService().export(f.snapshot, to: output))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("sentinel")), sentinel)
        XCTAssertEqual(try stages(f).count, 1)
    }

    func testFailureAndChangedSourcePreserveStagesAfterExternalHook() throws {
        let f = try fixture(), output = f.parent.appendingPathComponent("failed.aagedalpeople")
        let unrelated = f.parent.appendingPathComponent("unrelated"); try Data([1, 2, 3]).write(to: unrelated)
        XCTAssertThrowsError(try PeopleLibraryPackageService(beforePublish: { throw Failure.injected }).export(f.snapshot, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try stages(f).count, 1)
        let vectorPath = try XCTUnwrap(f.snapshot.manifest.files.first { $0.path.hasSuffix(".fem2") }).path
        let vectorURL = f.snapshot.directoryURL.appendingPathComponent(vectorPath)
        let changed = PeopleLibraryPackageService(beforePublish: {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vectorURL.path)
            var bytes = try Data(contentsOf: vectorURL); bytes[8] ^= 1; try bytes.write(to: vectorURL)
        })
        XCTAssertThrowsError(try changed.export(f.snapshot, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([1, 2, 3]))
        XCTAssertEqual(try stages(f).count, 2)
    }

    func testTighterImportLimitsFailBeforeReceivingRepositoryMutation() throws {
        let f = try fixture()
        let package = f.parent.appendingPathComponent("bounded.aagedalpeople")
        try PeopleLibraryPackageService().export(f.snapshot, to: package)
        var limits = PeopleLibraryManifest.Limits(); limits.maximumFileBytes = 1
        let receiverRoot = f.parent.appendingPathComponent("limit-receiver")
        let receiver = PeopleLibraryRepository(root: receiverRoot)
        XCTAssertThrowsError(try PeopleLibraryPackageService(limits: limits).importPackage(at: package, into: receiver))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiverRoot.path))
        XCTAssertEqual(try f.repository.currentSnapshot()?.manifest, f.snapshot.manifest)
        try assertNoStages(f)
    }

    func testSubstitutedStageChildIsPreservedAfterHookFailure() throws {
        let f = try fixture(), output = f.parent.appendingPathComponent("substituted.aagedalpeople")
        let replacement = Data("Foreign replacement must remain".utf8)
        let service = PeopleLibraryPackageService(beforePublish: {
            let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.parent, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".aagedalpeople-export-") })
            let child = stage.appendingPathComponent("people.json")
            try FileManager.default.removeItem(at: child)
            try replacement.write(to: child)
        })
        XCTAssertThrowsError(try service.export(f.snapshot, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let stage = try XCTUnwrap(stages(f).first)
        XCTAssertEqual(try stages(f).count, 1)
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("people.json")), replacement)
        XCTAssertEqual(try f.repository.currentSnapshot()?.manifest, f.snapshot.manifest)
    }

    func testSymlinkHardlinkAndWrongPackageExtensionAreRejected() throws {
        let f = try fixture(), service = PeopleLibraryPackageService()
        let output = f.parent.appendingPathComponent("blocked.aagedalpeople")
        let alias = f.parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.snapshot.directoryURL)
        let aliased = PeopleLibrarySnapshot(manifest: f.snapshot.manifest, gallery: f.snapshot.gallery, directoryURL: alias)
        XCTAssertThrowsError(try service.export(aliased, to: output))
        let payload = f.snapshot.directoryURL.appendingPathComponent("people.json")
        try FileManager.default.linkItem(at: payload, to: f.parent.appendingPathComponent("payload-hardlink"))
        XCTAssertThrowsError(try service.export(f.snapshot, to: output))
        XCTAssertThrowsError(try service.export(f.snapshot, to: f.parent.appendingPathComponent("wrong.zip")))
        let receiverRoot = f.parent.appendingPathComponent("unused-receiver")
        XCTAssertThrowsError(try service.importPackage(at: alias, into: .init(root: receiverRoot)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiverRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStages(f)
    }
}
