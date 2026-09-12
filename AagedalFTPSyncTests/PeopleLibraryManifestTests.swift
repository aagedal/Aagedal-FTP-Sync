import CryptoKit
import Foundation
import XCTest
@testable import AagedalFTPSync

final class PeopleLibraryManifestTests: XCTestCase {
    private let libraryID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let personID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let exampleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture() throws -> (PeopleLibraryManifest, PeopleLibraryPayload, Data, Data) {
        var values = [Float](repeating: 0, count: 512); values[0] = 1
        let vector = try FaceRecognitionEmbeddingCodec.encode(.init(validatingNormalized: values))
        let example = try PeopleLibraryPayload.Example(id: exampleID,
            embeddingPath: "embeddings/\(exampleID.uuidString.lowercased()).fem2")
        let person = try PeopleLibraryPayload.Person(id: personID, name: "  {persons} Å  ", examples: [example])
        let payload = try PeopleLibraryPayload(people: [person])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadBytes = try encoder.encode(payload)
        let files = [
            try PeopleLibraryManifest.FileDeclaration(path: "people.json", byteCount: payloadBytes.count, sha256: sha(payloadBytes)),
            try PeopleLibraryManifest.FileDeclaration(path: example.embeddingPath, byteCount: vector.count, sha256: sha(vector)),
        ]
        let exporter = try PeopleLibraryManifest.Exporter(app: "Aagedal Photo Agent", version: "3.0", sourceRevision: String(repeating: "a", count: 40))
        let manifest = try PeopleLibraryManifest(libraryID: libraryID, exportedAt: "2026-09-12T10:00:00.000Z",
            exporter: exporter, peopleCount: 1, embeddingCount: 1, files: files)
        return (manifest, payload, payloadBytes, vector)
    }

    func testStrictCanonicalRoundTripPreservesLiteralNamesAndReferences() throws {
        let (manifest, payload, _, _) = try fixture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestBytes = try encoder.encode(manifest)
        let payloadBytes = try encoder.encode(payload)
        XCTAssertTrue(String(decoding: manifestBytes, as: UTF8.self).contains(libraryID.uuidString.lowercased()))
        XCTAssertFalse(String(decoding: manifestBytes, as: UTF8.self).contains(libraryID.uuidString))
        XCTAssertTrue(String(decoding: payloadBytes, as: UTF8.self).contains(personID.uuidString.lowercased()))
        let decodedManifest = try PeopleLibraryManifest.decode(manifestBytes)
        let decodedPayload = try PeopleLibraryPayload.decode(payloadBytes)
        try decodedManifest.validate(payload: decodedPayload)
        XCTAssertEqual(decodedPayload.people[0].name, "  {persons} Å  ")
        XCTAssertEqual(decodedManifest.revision, manifest.revision)
    }

    func testRawAdmissionRejectsDuplicateEscapedKeysUnknownKeysAndUppercaseIDs() throws {
        XCTAssertThrowsError(try PeopleLibraryPayload.decode(Data(#"{"people":[],"pe\u006fple":[]}"#.utf8)))
        XCTAssertThrowsError(try PeopleLibraryPayload.decode(Data(#"{"people":[],"extra":false}"#.utf8)))
        let (manifest, _, _, _) = try fixture()
        let bytes = try JSONEncoder().encode(manifest)
        let canonical = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try PeopleLibraryManifest.decode(Data(canonical
            .replacingOccurrences(of: libraryID.uuidString.lowercased(), with: libraryID.uuidString).utf8)))
        XCTAssertThrowsError(try PeopleLibraryManifest.decode(Data(canonical
            .replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":1"#).utf8)))
    }

    func testPathsCountsRevisionsAndPayloadReferencesAreBound() throws {
        for path in ["/people.json", "../people.json", "embeddings\\x.fem2", "embeddings/../x.fem2",
                     "EMBEDDINGS/33333333-3333-3333-3333-333333333333.fem2"] {
            XCTAssertThrowsError(try PeopleLibraryManifest.FileDeclaration(path: path, byteCount: 1,
                sha256: String(repeating: "0", count: 64)))
        }
        let (manifest, payload, payloadBytes, _) = try fixture()
        let orphan = try PeopleLibraryManifest.FileDeclaration(path: "thumbnails/\(personID.uuidString.lowercased()).jpg",
            byteCount: 1, sha256: String(repeating: "0", count: 64))
        let exporter = try PeopleLibraryManifest.Exporter(app: "App", version: "3", sourceRevision: String(repeating: "b", count: 40))
        let changed = try PeopleLibraryManifest(libraryID: libraryID, exportedAt: "2026-09-12T10:00:00.000Z", exporter: exporter,
            peopleCount: 1, embeddingCount: 1, files: manifest.files + [orphan])
        XCTAssertThrowsError(try changed.validate(payload: payload))
        XCTAssertThrowsError(try PeopleLibraryManifest.FileDeclaration(path: "people.json", byteCount: payloadBytes.count,
            sha256: String(repeating: "A", count: 64)))
    }
}
