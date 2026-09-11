import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class MetadataCalendarProtocolModelTests: XCTestCase {
    private func document(active: Bool = false) throws -> SharedMetadataDocument {
        var profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Creator", copyrightNotice: "{gps:city}")
        var fields = ScheduledMetadataFields(headline: "{gps:city}", description: "Literal {broken", keywords: ["  one  ", "one"])
        if active {
            profile.setCopyright(try .activated("{gps:city}"))
            fields.setHeadline(try .activated("{gps:city}"))
            fields.setDescription(try .activated("{date:YYYY-MM-DD}"))
            fields.setKeywords(try .activated(["  {gps:city}  ", "one", "one"]))
        }
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Clip", startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: Date(timeIntervalSince1970: 1_800_000_600), fields: fields)
        return SharedMetadataDocument(MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [clip]))
    }

    private func snapshot(_ document: SharedMetadataDocument, compatibility: MetadataCalendarCompatibility = .legacy) -> SharedMetadataCalendar {
        .init(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: 7, role: "owner", document: document, compatibility: compatibility)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; value.dateEncodingStrategy = .millisecondsSince1970
        return value
    }
    private var decoder: JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value
    }

    func testAbsentHeadersPreserveExactLegacySnapshotAndSummaryBytes() throws {
        struct OldSnapshot: Encodable {
            var id: UUID; var name: String; var timeZone: String; var revision: Int64; var role: String
            var rangeStart: Date?; var rangeEnd: Date?; var document: SharedMetadataDocument
        }
        struct OldSummary: Encodable { var id: UUID; var name: String; var timeZone: String; var role: String }
        var value = snapshot(try document())
        for ranged in [false, true] {
            if ranged { value.rangeStart = Date(timeIntervalSince1970: 1_800_000_000); value.rangeEnd = Date(timeIntervalSince1970: 1_800_000_600) }
            let old = OldSnapshot(id: value.id, name: value.name, timeZone: value.timeZone, revision: value.revision, role: value.role,
                rangeStart: value.rangeStart, rangeEnd: value.rangeEnd, document: value.document)
            let bytes = try encoder.encode(value)
            XCTAssertEqual(bytes, try encoder.encode(old))
            XCTAssertEqual(try decoder.decode(SharedMetadataCalendar.self, from: bytes), value)
        }
        let summary = MetadataCalendarSummary(id: value.id, name: value.name, timeZone: value.timeZone, role: value.role)
        XCTAssertEqual(try encoder.encode(summary), try encoder.encode(OldSummary(id: value.id, name: value.name, timeZone: value.timeZone, role: value.role)))
        XCTAssertEqual(try decoder.decode(MetadataCalendarSummary.self, from: encoder.encode(summary)).compatibility, .legacy)
    }

    func testTemplateNamespaceRoundtripRetainsHeadersEvenAfterAllActivationsRemoved() throws {
        var value = snapshot(try document(active: true), compatibility: .templates)
        XCTAssertEqual(try decoder.decode(SharedMetadataCalendar.self, from: encoder.encode(value)), value)
        value.document = try document()
        let bytes = try encoder.encode(value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["documentSchemaVersion"] as? Int, 3)
        XCTAssertEqual(json["minimumClientProtocol"] as? Int, 3)
        XCTAssertEqual(json["requiredCapabilities"] as? [String], ["metadata-templates-v1"])
        XCTAssertEqual(try decoder.decode(SharedMetadataCalendar.self, from: bytes), value)
        XCTAssertNoThrow(try value.validateCompatibility(for: .templates))
        XCTAssertThrowsError(try value.validateCompatibility(for: .legacy))
        XCTAssertThrowsError(try LegacyMetadataCalendarGate.validate(value))
        let summary = MetadataCalendarSummary(id: value.id, name: value.name, timeZone: value.timeZone, role: value.role, compatibility: .templates)
        XCTAssertEqual(try decoder.decode(MetadataCalendarSummary.self, from: encoder.encode(summary)).compatibility, .templates)
    }

    func testMalformedCompatibilityRejectsBeforeMalformedDocumentAndIsNonrecoverable() throws {
        let good: [String: Any] = ["documentSchemaVersion": 3, "minimumClientProtocol": 3, "requiredCapabilities": ["metadata-templates-v1"]]
        for key in good.keys {
            var absent = good; absent.removeValue(forKey: key)
            var null = good; null[key] = NSNull()
            var boolean = good; boolean[key] = true
            for headers in [absent, null, boolean] {
                try assertInvalidHeaders(headers)
            }
        }
        for (key, replacement) in [("documentSchemaVersion", 4 as Any), ("minimumClientProtocol", 2 as Any),
                ("requiredCapabilities", [] as [String]), ("requiredCapabilities", ["metadata-templates-v2"]),
                ("requiredCapabilities", ["metadata-templates-v1", "metadata-templates-v1"])] {
            var headers = good; headers[key] = replacement; try assertInvalidHeaders(headers)
        }
    }

    private func assertInvalidHeaders(_ headers: [String: Any]) throws {
        var object = headers; object["document"] = "Must not decode first"
        let bytes = try JSONSerialization.data(withJSONObject: object)
        for decode in [
            { _ = try self.decoder.decode(SharedMetadataCalendar.self, from: bytes) },
            { _ = try self.decoder.decode(MetadataCalendarSummary.self, from: bytes) }
        ] {
            XCTAssertThrowsError(try decode()) { error in
                XCTAssertEqual(error as? MetadataTemplateRecordError, .invalidSource)
                XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error))
            }
        }
    }

    func testExactDeactivationsCoverOnlyRetainedFieldsAndPreserveRawSources() throws {
        let old = try document(active: true)
        var proposed = old
        proposed.photographers[0].setCopyright(.literal(old.photographers[0].copyrightNotice))
        proposed.clips[0].fields.setHeadline(.literal(old.clips[0].fields.headline))
        proposed.clips[0].fields.setDescription(.literal(old.clips[0].fields.description))
        proposed.clips[0].fields.setKeywords(.literal(old.clips[0].fields.keywords))
        let declarations = try MetadataTemplateDeactivation.required(from: old, to: proposed)
        XCTAssertEqual(declarations.count, 4)
        XCTAssertEqual(try MetadataTemplateDeactivation.required(from: old, to: proposed), declarations)
        XCTAssertNoThrow(try MetadataTemplateDeactivation.validate(Array(declarations.reversed()), from: old, to: proposed))
        XCTAssertEqual(proposed.clips[0].fields.keywords, ["  {gps:city}  ", "one", "one"])
        XCTAssertThrowsError(try MetadataTemplateDeactivation.validate(Array(declarations.dropLast()), from: old, to: proposed))
        XCTAssertThrowsError(try MetadataTemplateDeactivation.validate(declarations + [declarations[0]], from: old, to: proposed))
        XCTAssertThrowsError(try MetadataTemplateDeactivation.validate(declarations, from: old, to: old))
        proposed.clips = []; proposed.photographers = []
        XCTAssertEqual(try MetadataTemplateDeactivation.required(from: old, to: proposed), [])
        XCTAssertEqual(try MetadataTemplateDeactivation.required(from: proposed, to: old), [])
    }

    func testDeactivationCodecRejectsUnknownMissingNullFutureAndWrongRecordField() throws {
        let value = try MetadataTemplateDeactivation(recordKind: .clip, recordID: UUID(), field: .headline)
        let bytes = try encoder.encode(value)
        XCTAssertEqual(try decoder.decode(MetadataTemplateDeactivation.self, from: bytes), value)
        let good = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for key in good.keys {
            var absent = good; absent.removeValue(forKey: key)
            var null = good; null[key] = NSNull()
            for object in [absent, null] { XCTAssertThrowsError(try decoder.decode(MetadataTemplateDeactivation.self, from: JSONSerialization.data(withJSONObject: object))) }
        }
        for (key, replacement) in [("previousVersion", 2 as Any), ("previousVersion", true as Any), ("recordKind", "unknown" as Any),
                ("recordID", "bad UUID" as Any), ("field", "copyrightNotice" as Any), ("unknown", 1 as Any)] {
            var object = good; object[key] = replacement
            XCTAssertThrowsError(try decoder.decode(MetadataTemplateDeactivation.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        XCTAssertThrowsError(try MetadataTemplateDeactivation(recordKind: .photographer, recordID: UUID(), field: .keywords))
    }

    func testDeactivationDiffRejectsAmbiguousRecordIDsAndInvalidActiveSources() throws {
        let old = try document(active: true)
        var duplicate = old; duplicate.clips.append(old.clips[0])
        XCTAssertThrowsError(try MetadataTemplateDeactivation.required(from: old, to: duplicate))
        duplicate = old; duplicate.photographers.append(old.photographers[0])
        XCTAssertThrowsError(try MetadataTemplateDeactivation.required(from: duplicate, to: old))
        var malformed = old; malformed.clips[0].fields.headline = "{unknown:variable}"
        XCTAssertThrowsError(try MetadataTemplateDeactivation.required(from: malformed, to: old))
    }

    func testProductionRepositoryKeepsLiteralTemplateNamespaceBlockedAndBytesIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let repository = MetadataCalendarRepository(storage: layout)
        let codec = VersionedStoreCodec(format: .version3, store: .metadataCalendar)
        let empty = MetadataCalendarState()
        let bytes = try codec.encode(empty, encoder: encoder)
        try bytes.write(to: repository.url)
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid")
        let value = snapshot(try document(), compatibility: .templates)
        let blocked = MetadataCalendarState(accounts: [account], activeAccountID: account.id,
            bindings: [.init(accountID: account.id, jobID: UUID(), snapshot: value)])
        XCTAssertThrowsError(try repository.save(blocked))
        XCTAssertEqual(try Data(contentsOf: repository.url), bytes)
        let incompatible = try codec.encode(blocked, encoder: encoder)
        try incompatible.write(to: repository.url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.save(empty))
        XCTAssertEqual(try Data(contentsOf: repository.url), incompatible)
    }

    func testEarlierMalformedBindingCannotHideLaterNamespaceFromRecoveryOrStaleSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let repository = MetadataCalendarRepository(storage: layout)
        let codec = VersionedStoreCodec(format: .version3, store: .metadataCalendar)
        let original = try codec.encode(MetadataCalendarState(), encoder: encoder)
        let bad = Data("""
        {"format":"AagedalFTPSync.store","schemaVersion":3,"store":"metadataCalendar","payload":{
          "accounts":[],"bindings":[{"accountID":false},{"snapshot":{"documentSchemaVersion":3,
          "minimumClientProtocol":3,"requiredCapabilities":["metadata-templates-v1"]}}]}}
        """.utf8)
        try bad.write(to: repository.url)
        try original.write(to: repository.url.appendingPathExtension("backup"))
        XCTAssertThrowsError(try codec.decode(MetadataCalendarState.self, from: bad, decoder: decoder)) { error in
            XCTAssertEqual(error as? MetadataTemplateRecordError, .invalidSource)
            XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error))
        }
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.save(MetadataCalendarState()))
        XCTAssertEqual(try Data(contentsOf: repository.url), bad)
        XCTAssertEqual(try Data(contentsOf: repository.url.appendingPathExtension("backup")), original)
        XCTAssertThrowsError(try VersionedStoreCodec.rejectLegacyTemplateMarkers(in: bad))
    }
}
