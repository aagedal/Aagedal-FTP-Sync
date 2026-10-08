import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class SyncJobProcessingTimeZoneTests: XCTestCase {
    private let zoneKey = "metadataProcessingTimeZoneIdentifier"

    /// Independent old wire fixture, including deliberately literal brace text.
    private func legacyObject() throws -> [String: Any] {
        let source = #"""
        {
          "id":"ABCDEFAB-1234-5678-9012-ABCDEFABCDEF",
          "name":"Literal {date:YYYY-MM-DD}",
          "left":{"kind":"local","localPath":"/source","host":"","port":0,"username":"","remotePath":"/","credentialID":"source","hostKeyFingerprint":""},
          "right":{"kind":"local","localPath":"/target","host":"","port":0,"username":"","remotePath":"/","credentialID":"target","hostKeyFingerprint":""},
          "direction":"leftToRight",
          "filter":{"preset":"custom","customExtensions":"jpg","includeHiddenFiles":false},
          "intervalSeconds":5,"isEnabled":false,
          "preserveModificationDates":true,"verifyFileSizes":true
        }
        """#
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }

    private func bytes(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func assertConfigurationError(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? MetadataTemplateRecordError, .invalidSource, file: file, line: line)
            XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error), file: file, line: line)
        }
    }

    func testAbsentZoneRetainsLegacyBytesOptionalDefaultsAndRequiredKeys() throws {
        let original = try bytes(legacyObject())
        let job = try JSONDecoder().decode(SyncJob.self, from: original)
        XCTAssertNil(job.metadataProcessingTimeZoneIdentifier)
        XCTAssertNil(try job.validatedMetadataProcessingTimeZone)
        XCTAssertNil(job.startOnAppLaunch)
        XCTAssertFalse(job.startsOnAppLaunch)
        XCTAssertNil(job.latestSessionTransferCountOnly)
        XCTAssertNil(job.verifyMatchingFileContents)
        XCTAssertNil(job.metadataAutomation)
        XCTAssertEqual(try encoder().encode(job), original)
        XCTAssertNoThrow(try job.validateMetadataTemplateActivationContext())
        assertConfigurationError { _ = try job.requiredMetadataProcessingTimeZone() }

        var missingRequired = try legacyObject()
        missingRequired.removeValue(forKey: "verifyFileSizes")
        XCTAssertThrowsError(try JSONDecoder().decode(SyncJob.self, from: bytes(missingRequired))) { error in
            guard case DecodingError.keyNotFound = error else { return XCTFail("Existing required keys must stay required") }
        }
    }

    func testExplicitZoneRoundTripsExactlyAndRetainsSeasonalOffsets() throws {
        for identifier in ["Europe/Oslo", "America/New_York", "Etc/UTC", "Asia/Kathmandu"] {
            var object = try legacyObject()
            object[zoneKey] = identifier
            let job = try JSONDecoder().decode(SyncJob.self, from: bytes(object))
            XCTAssertEqual(job.metadataProcessingTimeZoneIdentifier, identifier)
            XCTAssertEqual(try job.requiredMetadataProcessingTimeZone(), TimeZone(identifier: identifier))
            XCTAssertEqual(try encoder().encode(job), try bytes(object))
            var copy = job
            copy.metadataProcessingTimeZoneIdentifier = nil
            XCTAssertNotEqual(copy, job)
            XCTAssertEqual(Set([copy, job]).count, 2)
        }
        let job = SyncJob(name: "Frozen", metadataProcessingTimeZoneIdentifier: "Europe/Oslo")
        let zone = try job.requiredMetadataProcessingTimeZone()
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(zone.secondsFromGMT(for: try XCTUnwrap(iso.date(from: "2026-01-15T12:00:00Z"))), 3_600)
        XCTAssertEqual(zone.secondsFromGMT(for: try XCTUnwrap(iso.date(from: "2026-07-15T12:00:00Z"))), 7_200)
    }

    func testPresentNullWrongTypesAndInvalidZonesFailBeforeOtherFields() throws {
        let malformed: [Any] = [NSNull(), true, 1, 1.5, [], [:], "", " ", "Europe/NotARealZone", " Europe/Oslo", "Europe/Oslo\n"]
        for value in malformed {
            var object = try legacyObject()
            object[zoneKey] = value
            assertConfigurationError { _ = try JSONDecoder().decode(SyncJob.self, from: bytes(object)) }
            object["id"] = false
            assertConfigurationError { _ = try JSONDecoder().decode(SyncJob.self, from: bytes(object)) }
        }
        var job = SyncJob(name: "Draft")
        job.metadataProcessingTimeZoneIdentifier = "invalid-zone"
        assertConfigurationError { _ = try job.validatedMetadataProcessingTimeZone }
        assertConfigurationError { _ = try encoder().encode(job) }
        assertConfigurationError { try job.validateMetadataTemplateActivationContext() }
    }

    func testActivationRequirementIsExplicitAndIncludesDisabledAutomation() throws {
        var profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "{date:YYYY-MM-DD}")
        var job = SyncJob(name: "Fixture", metadataAutomation: MetadataAutomation(photographers: [profile]))
        XCTAssertNoThrow(try job.validateMetadataTemplateActivationContext())
        profile.setCopyright(try .activated("{date:YYYY-MM-DD}"))
        job.metadataAutomation = MetadataAutomation(isEnabled: false, photographers: [profile])
        assertConfigurationError { try job.validateMetadataTemplateActivationContext() }
        // Reading existing active records does not invent a zone or silently enable work.
        let decoded = try JSONDecoder().decode(SyncJob.self, from: encoder().encode(job))
        XCTAssertNil(decoded.metadataProcessingTimeZoneIdentifier)
        XCTAssertEqual(decoded.metadataAutomation?.isEnabled, false)
        assertConfigurationError { try decoded.validateMetadataTemplateActivationContext() }
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        XCTAssertNoThrow(try job.validateMetadataTemplateActivationContext())
        XCTAssertEqual(try JSONDecoder().decode(SyncJob.self, from: encoder().encode(job)), job)
    }

    func testInvalidPersistedZoneCannotRecoverOrBeOverwrittenByStaleJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("job-processing-zone-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let codec = VersionedStoreCodec(format: .version3, store: .jobs)
        let good = try codec.encode([SyncJob(name: "Old")], encoder: encoder())
        try good.write(to: layout.jobs.appendingPathExtension("backup"))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var payload = try XCTUnwrap(envelope["payload"] as? [[String: Any]])
        payload[0][zoneKey] = NSNull()
        envelope["payload"] = payload
        let damaged = try bytes(envelope)
        try damaged.write(to: layout.jobs)
        let repository = JobRepository(storage: layout)
        assertConfigurationError { _ = try repository.loadResult() }
        assertConfigurationError { try repository.save([SyncJob(name: "Stale")]) }
        XCTAssertEqual(try Data(contentsOf: layout.jobs), damaged)
        XCTAssertEqual(try Data(contentsOf: layout.jobs.appendingPathExtension("backup")), good)
    }

    func testEarlierMalformedJobCannotHideLaterProcessingZoneFromRecoveryOrSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("job-zone-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let codec = VersionedStoreCodec(format: .version3, store: .jobs)
        let backup = layout.jobs.appendingPathExtension("backup")
        let old = try codec.encode([SyncJob(name: "Older configuration")], encoder: encoder())
        try old.write(to: backup)
        let zones: [Any] = ["Europe/Oslo", NSNull(), false, "invalid-zone"]
        for zone in zones {
            var laterJob = try legacyObject()
            laterJob[zoneKey] = zone
            let envelope: [String: Any] = ["format": "AagedalFTPSync.store", "schemaVersion": 3,
                "store": "jobs", "payload": [["id": NSNull()], laterJob]]
            let original = try bytes(envelope)
            try original.write(to: layout.jobs)
            assertConfigurationError { _ = try codec.decode([SyncJob].self, from: original, decoder: JSONDecoder()) }
            let repository = JobRepository(storage: layout)
            assertConfigurationError { _ = try repository.loadResult() }
            assertConfigurationError { try repository.save([SyncJob(name: "Stale configuration")]) }
            XCTAssertEqual(try Data(contentsOf: layout.jobs), original)
            XCTAssertEqual(try Data(contentsOf: backup), old)
        }
    }

    func testProcessingZoneRecoveryProbeIsRecursiveAndLimitedToVersionThreeJobs() throws {
        let payload: [[String: Any]] = [["id": NSNull()], ["extension": ["nested": [[zoneKey: "Etc/UTC"]]]]]
        for store in [VersionedStoreCodec.Store.jobs, .metadataPresets] {
            let envelope: [String: Any] = ["format": "AagedalFTPSync.store", "schemaVersion": 3,
                "store": store.rawValue, "payload": payload]
            let data = try bytes(envelope)
            let codec = VersionedStoreCodec(format: .version3, store: store)
            if store == .jobs {
                assertConfigurationError { _ = try codec.decode([SyncJob].self, from: data, decoder: JSONDecoder()) }
            } else {
                XCTAssertThrowsError(try codec.decode([MetadataPreset].self, from: data, decoder: JSONDecoder())) { error in
                    XCTAssertTrue(VersionedStoreCodec.permitsBackupRecovery(after: error))
                }
            }
        }
    }

    func testValidLiteralZoneRemainsAllowedInLegacyStoreAndMarkerProbe() throws {
        let job = SyncJob(name: "Literal {date:YYYY-MM-DD}", metadataProcessingTimeZoneIdentifier: "Europe/Oslo")
        let codec = VersionedStoreCodec(format: .legacy, store: .jobs)
        let original = try encoder().encode([job])
        XCTAssertNoThrow(try VersionedStoreCodec.rejectLegacyTemplateMarkers(in: original))
        XCTAssertEqual(try codec.encode([job], encoder: encoder()), original)
        XCTAssertEqual(try codec.decode([SyncJob].self, from: original, decoder: JSONDecoder()), [job])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-job-zone-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("jobs.json")
        let repository = JobRepository(fileURL: file)
        try repository.save([job])
        XCTAssertEqual(try repository.load(), [job])
        XCTAssertEqual(job.metadataProcessingTimeZoneIdentifier, "Europe/Oslo")
        XCTAssertNil(job.metadataAutomation)
    }
}
