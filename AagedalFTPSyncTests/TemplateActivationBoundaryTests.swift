import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class TemplateActivationBoundaryTests: XCTestCase {
    private func activeAssignment() throws -> MetadataAssignment {
        let profile = PhotographerProfile(name: "Creator", filenamePrefix: "A", creator: "", copyrightNotice: "Literal")
        var fields = ScheduledMetadataFields()
        fields.setHeadline(try .activated("{photographer}"))
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Active", startsAt: .distantPast,
                                       endsAt: .distantFuture, fields: fields)
        return MetadataAssignment(photographer: profile, clip: clip, existingFieldPolicy: .overwrite)
    }

    func testActiveAssignmentCannotReachLiteralWriterAndOriginalBytesStayUntouched() throws {
        let assignment = try activeAssignment()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("fixture.jpg")
        let bytes = Data("intact disposable source".utf8)
        try bytes.write(to: image)
        let check: (Error) -> Void = { error in
            guard let error = error as? AppError, case .invalidConfiguration = error else {
                return XCTFail("Expected activation rejection before image decoding")
            }
        }
        XCTAssertThrowsError(try MetadataProcessingCoordinator.prepareLiteral(assignment)) { check($0) }
        XCTAssertThrowsError(try MetadataWriter.assess(assignment, at: image, relativePath: "fixture.jpg")) { check($0) }
        XCTAssertThrowsError(try MetadataWriter.apply(assignment, to: image)) { check($0) }
        XCTAssertThrowsError(try MetadataWriter.apply(assignment, to: image, relativePath: "fixture.nef")) { check($0) }
        XCTAssertEqual(try Data(contentsOf: image), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.xmp").path))
    }

    func testActiveCopyrightAlsoBlocksLiteralProcessing() throws {
        let active = try activeAssignment()
        var clip = active.clip
        clip.fields.setHeadline(.literal("Legacy"))
        var profile = active.photographer
        profile.setCopyright(try .activated("© {photographer}"))
        let assignment = MetadataAssignment(photographer: profile, clip: clip, existingFieldPolicy: .overwrite)
        XCTAssertThrowsError(try MetadataProcessingCoordinator.prepareLiteral(assignment))
    }

    func testInvalidActivePrimaryCannotFallbackOrBeOverwrittenByCachedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root, storageFormat: .version3)
        let file = storage.metadataPresets
        let backup = file.appendingPathExtension("backup")
        let codec = VersionedStoreCodec(format: .version3, store: .metadataPresets)
        let good = try codec.encode([MetadataPreset(name: "Old literal")], encoder: JSONEncoder())
        let active = try codec.encode([MetadataPreset(name: "Active", fields: activeAssignment().clip.fields)], encoder: JSONEncoder())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: active) as? [String: Any])
        var payload = try XCTUnwrap(object["payload"] as? [[String: Any]])
        var fields = try XCTUnwrap(payload[0]["fields"] as? [String: Any])
        fields["templateVersions"] = ["headline": 99]
        payload[0]["fields"] = fields
        object["payload"] = payload
        let future = try JSONSerialization.data(withJSONObject: object)
        try future.write(to: file); try good.write(to: backup)
        let repository = MetadataPresetRepository(storage: storage)
        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertTrue(error is MetadataTemplateRecordError)
            XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error))
        }
        XCTAssertThrowsError(try repository.save([]))
        XCTAssertEqual(try Data(contentsOf: file), future)
        XCTAssertEqual(try Data(contentsOf: backup), good)
    }

    func testTypedRequestRetainsPersistedActivationAndResolvesItInMemory() throws {
        let request = try MetadataProcessingRequest(assignment: activeAssignment())
        XCTAssertEqual(request.headline.templateVersion, 1)
        let context = MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: 0),
            processingTimeZone: TimeZone(secondsFromGMT: 0)!)
        let result = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: [.headline])
        XCTAssertEqual(result.changes.headline, "Creator")
    }

    func testLegacyCodecRejectsMarkerPresenceBeforePayloadAndCannotFallback() throws {
        struct Trap: Decodable { init(from decoder: Decoder) throws { XCTFail("Payload was visited") } }
        let codec = VersionedStoreCodec(format: .legacy, store: .jobs)
        for marker in [#""templateVersions":{}"#, #""templateVersions":null"#, #""copyrightTemplateVersion":1"#] {
            let data = Data("[{\"nested\":{\(marker)}}]".utf8)
            XCTAssertThrowsError(try codec.decode(Trap.self, from: data, decoder: JSONDecoder())) { error in
                XCTAssertEqual(error as? VersionedStoreCodec.HeaderError, .requiresVersion3Storage)
                XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error))
            }
        }
    }

    func testEarlierMalformedSiblingCannotHideActivationDuringRecovery() throws {
        let codec = VersionedStoreCodec(format: .version3, store: .metadataPresets)
        let bytes = Data(#"{"format":"AagedalFTPSync.store","schemaVersion":3,"store":"metadataPresets","payload":[{"id":null,"fields":{"templateVersions":{"headline":99}}}]}"#.utf8)
        XCTAssertThrowsError(try codec.decode([MetadataPreset].self, from: bytes, decoder: JSONDecoder())) { error in
            XCTAssertTrue(error is MetadataTemplateRecordError)
            XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error))
        }
    }

    func testLegacySaveDoesNotReplaceActiveExistingStoreOrBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("presets.json")
        let backup = file.appendingPathExtension("backup")
        let original = Data(#"[{"fields":{"templateVersions":{"headline":1},"headline":"{photographer}"}}]"#.utf8)
        let oldBackup = Data("[]".utf8)
        try original.write(to: file); try oldBackup.write(to: backup)
        let repository = MetadataPresetRepository(fileURL: file)
        XCTAssertThrowsError(try repository.save([]))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: backup), oldBackup)
        XCTAssertThrowsError(try repository.load())
    }

    func testActiveRecordsEncodeOnlyThroughVersionThreeStorage() throws {
        let fields = try activeAssignment().clip.fields
        let value = [MetadataPreset(name: "Active", fields: fields)]
        XCTAssertThrowsError(try VersionedStoreCodec(format: .legacy, store: .metadataPresets).encode(value, encoder: JSONEncoder()))
        let codec = VersionedStoreCodec(format: .version3, store: .metadataPresets)
        let data = try codec.encode(value, encoder: JSONEncoder())
        let restored = try codec.decode([MetadataPreset].self, from: data, decoder: JSONDecoder())
        XCTAssertEqual(restored, value)
        XCTAssertTrue(restored[0].hasActivatedTemplates)
    }
}
