import Foundation
import XCTest
@testable import AagedalFTPSync

final class PhotoAgentPeopleLibraryInterchangeTests: XCTestCase {
    func testPhotoAgentGoldenPackageImportsAndExportsWithoutChangingBytes() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PhotoAgentPeopleLibraryV2")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-agent-interchange-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("producer.aagedalpeople")
        let output = root.appendingPathComponent("receiver.aagedalpeople")
        let paths = [
            "manifest.json": "manifest.json.base64",
            "people.json": "people.json.base64",
            "editor/photo-agent.json": "editor-photo-agent.json.base64",
            "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2": "embedding.fem2.base64",
        ]
        var original: [String: Data] = [:]
        for (path, name) in paths {
            let encoded = try String(contentsOf: fixture.appendingPathComponent(name), encoding: .utf8)
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded.components(separatedBy: .whitespacesAndNewlines).joined()))
            let target = input.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
            original[path] = bytes
        }

        let service = PeopleLibraryPackageService()
        let repository = PeopleLibraryRepository(root: root.appendingPathComponent("installed"))
        let snapshot = try service.importPackage(at: input, into: repository)
        XCTAssertEqual(snapshot.manifest.schemaVersion, 2)
        XCTAssertEqual(try service.export(snapshot, to: output), output)
        for (path, bytes) in original {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)), bytes, path)
        }
        let second = PeopleLibraryRepository(root: root.appendingPathComponent("reimported"))
        XCTAssertEqual(try service.importPackage(at: output, into: second).manifest, snapshot.manifest)
    }
}
