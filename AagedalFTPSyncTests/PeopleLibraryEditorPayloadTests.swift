import CryptoKit
import Foundation
import XCTest
@testable import AagedalFTPSync

final class PeopleLibraryEditorPayloadTests: XCTestCase {
    private let library = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let person = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    private let example = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fixture() throws -> (PeopleLibraryManifest, PeopleLibraryPayload, PeopleLibraryEditorPayload) {
        let item = try PeopleLibraryPayload.Example(id: example, embeddingPath: "embeddings/\(example.uuidString.lowercased()).fem2")
        let payload = try PeopleLibraryPayload(people: [.init(id: person, name: "Person", examples: [item])])
        let bytes = try JSONEncoder().encode(payload)
        let files = [try PeopleLibraryManifest.FileDeclaration(path: "people.json", byteCount: bytes.count, sha256: hash(bytes)),
                     try PeopleLibraryManifest.FileDeclaration(path: item.embeddingPath, byteCount: 2056, sha256: String(repeating: "a", count: 64))]
        let manifest = try PeopleLibraryManifest(libraryID: library, exportedAt: "2026-09-12T10:00:00.000Z",
            exporter: .init(app: "Photo Agent", version: "3", sourceRevision: String(repeating: "a", count: 40)), peopleCount: 1, embeddingCount: 1, files: files)
        let editor = try PeopleLibraryEditorPayload(libraryID: library, coreRevision: manifest.coreRevision,
            people: [person.uuidString.lowercased(): .init(role: "", notes: "  {literal}\n", representativeThumbnailID: example, createdAt: -0.125, updatedAt: 812345678.123456)],
            examples: [example.uuidString.lowercased(): .init(sourceDescription: "/private/example/Å.jpg", addedAt: 123.125, recognitionMode: .faceClothing)])
        return (manifest, payload, editor)
    }
    private func attach(_ bytes: Data, to core: PeopleLibraryManifest) throws -> PeopleLibraryManifest {
        let descriptor = try PeopleLibraryManifest.EditorPayloadDescriptor(byteCount: bytes.count, sha256: hash(bytes))
        return try .init(libraryID: core.libraryID, exportedAt: core.exportedAt, exporter: core.exporter,
            peopleCount: core.peopleCount, embeddingCount: core.embeddingCount,
            files: core.files + [.init(path: descriptor.path, byteCount: descriptor.byteCount, sha256: descriptor.sha256)], editorPayload: descriptor)
    }
    func testLosslessRoundTripAndNonCircularRevisions() throws {
        let (core, payload, editor) = try fixture()
        let bytes = try JSONEncoder().encode(editor)
        let full = try attach(bytes, to: core)
        XCTAssertEqual(full.coreRevision, core.coreRevision)
        XCTAssertNotEqual(full.revision, core.revision)
        XCTAssertNotEqual(core.revision, core.coreRevision)
        XCTAssertEqual(try PeopleLibraryEditorPayload.decode(bytes, manifest: full, payload: payload), editor)
        XCTAssertEqual(try PeopleLibraryManifest.decode(JSONEncoder().encode(full)), full)
        let changed = try PeopleLibraryEditorPayload(libraryID: library, coreRevision: core.coreRevision, people: editor.people,
            examples: [example.uuidString.lowercased(): .init(sourceDescription: "changed", addedAt: 123.125, recognitionMode: .vision)])
        let other = try attach(JSONEncoder().encode(changed), to: core)
        XCTAssertEqual(other.coreRevision, full.coreRevision); XCTAssertNotEqual(other.revision, full.revision)
    }
    func testStrictRawKeysNullsModesAndHashAdmission() throws {
        let (core, payload, editor) = try fixture()
        let original = try JSONEncoder().encode(editor)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for key in ["unknown", "editorVersion"] {
            var invalid = object; invalid[key] = 1
            let bytes = try JSONSerialization.data(withJSONObject: invalid)
            XCTAssertThrowsError(try PeopleLibraryEditorPayload.decode(bytes, manifest: attach(bytes, to: core), payload: payload))
        }
        var examples = try XCTUnwrap(object["examples"] as? [String: [String: Any]])
        for mode in [NSNull(), "off", "onDemand", "alwaysOn"] as [Any] {
            examples[example.uuidString.lowercased()]?["recognitionMode"] = mode; object["examples"] = examples
            let bytes = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try PeopleLibraryEditorPayload.decode(bytes, manifest: attach(bytes, to: core), payload: payload))
        }
        let duplicate = Data(("{\"schemaVersion\":1," + String(decoding: original, as: UTF8.self).dropFirst()).utf8)
        XCTAssertThrowsError(try PeopleLibraryEditorPayload.decode(duplicate, manifest: attach(duplicate, to: core), payload: payload))
        XCTAssertThrowsError(try PeopleLibraryEditorPayload.decode(original + Data([32]), manifest: attach(original, to: core), payload: payload))
    }
    func testBindingCoverageAndFiniteDates() throws {
        let (core, payload, editor) = try fixture()
        let absent = try PeopleLibraryEditorPayload(libraryID: library, coreRevision: core.coreRevision, people: [:], examples: editor.examples)
        XCTAssertThrowsError(try absent.validate(manifest: core, payload: payload))
        let wrong = try PeopleLibraryEditorPayload(libraryID: UUID(), coreRevision: core.coreRevision, people: editor.people, examples: editor.examples)
        XCTAssertThrowsError(try wrong.validate(manifest: core, payload: payload))
        let representative = try PeopleLibraryEditorPayload(libraryID: library, coreRevision: core.coreRevision,
            people: [person.uuidString.lowercased(): .init(representativeThumbnailID: UUID(), createdAt: 1, updatedAt: 2)], examples: editor.examples)
        XCTAssertThrowsError(try representative.validate(manifest: core, payload: payload))
        XCTAssertThrowsError(try PeopleLibraryEditorPayload.PersonMetadata(createdAt: .infinity, updatedAt: 1))
        XCTAssertThrowsError(try PeopleLibraryEditorPayload.ExampleMetadata(addedAt: .nan))
        let optional = try PeopleLibraryEditorPayload.ExampleMetadata(addedAt: 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(optional)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["addedAt"])
    }
}
