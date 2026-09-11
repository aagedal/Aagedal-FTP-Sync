import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataGeocodingSettingsTests: XCTestCase {
    private func settings() throws -> MetadataGeocodingSettings {
        try .init(resolveVariables: true, cityPolicy: .fillEmpty, countryPolicy: .overwrite, localeIdentifier: "nb-NO")
    }
    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func bytes(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("geocoding-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testExplicitOfflineContractAndIndependentOptInsRoundTrip() throws {
        let setting = try settings()
        let decoded = try JSONDecoder().decode(MetadataGeocodingSettings.self, from: JSONEncoder().encode(setting))
        XCTAssertEqual(decoded, setting)
        XCTAssertTrue(setting.isEnabled)
        XCTAssertEqual(MetadataGeocodingSettings.providerIdentifier, OfflineMetadataGeocodingProvider.identity.provider)
        XCTAssertEqual(MetadataGeocodingSettings.providerVersion, OfflineMetadataGeocodingProvider.identity.version)
        XCTAssertEqual(MetadataGeocodingSettings.datasetIdentifier, OfflineMetadataGeocodingProvider.identity.dataset)
        XCTAssertEqual(Double(MetadataGeocodingSettings.maximumDistanceMeters), OfflineMetadataGeocodingProvider.offlineLimits.maximumDistanceMeters)
        XCTAssertFalse(try MetadataGeocodingSettings(localeIdentifier: "en_US").isEnabled)
        XCTAssertTrue(try MetadataGeocodingSettings(resolveVariables: true, localeIdentifier: "en_US").isEnabled)
        XCTAssertTrue(try MetadataGeocodingSettings(cityPolicy: .fillEmpty, localeIdentifier: "en_US").isEnabled)
        XCTAssertTrue(try MetadataGeocodingSettings(countryPolicy: .overwrite, localeIdentifier: "en_US").isEnabled)
    }

    func testAllSchemaFieldsAreStrictAndUnknownFuturePolicyIsRejected() throws {
        let original = try object(settings())
        for key in original.keys {
            var missing = original; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(MetadataGeocodingSettings.self, from: bytes(missing)))
            var null = original; null[key] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(MetadataGeocodingSettings.self, from: bytes(null)))
        }
        let corrupt: [(String, Any)] = [
            ("schemaVersion", true), ("schemaVersion", 2), ("schemaVersion", "1"),
            ("providerIdentifier", "apple-online"), ("providerVersion", "future"), ("datasetIdentifier", "future"),
            ("maximumDistanceMeters", 100_000), ("maximumDistanceMeters", true),
            ("resolveVariables", 1), ("cityPolicy", "automatic"), ("countryPolicy", false),
            ("localeIdentifier", ""), ("localeIdentifier", "automatic"), ("localeIdentifier", " en_US"),
            ("localeIdentifier", "made-up-locale"), ("unknownFutureField", true)
        ]
        for (key, value) in corrupt {
            var changed = original; changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(MetadataGeocodingSettings.self, from: bytes(changed))) {
                XCTAssertEqual($0 as? MetadataGeocodingSettingsError, .invalidSettings, key)
                XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: $0))
            }
        }
        var changed = try settings(); changed.localeIdentifier = "automatic"
        XCTAssertThrowsError(try changed.validate())
        XCTAssertThrowsError(try JSONEncoder().encode(changed))
    }

    func testJobAbsenceIsOffWhilePresentNullAndInvalidMutationFailClosed() throws {
        let literal = SyncJob(name: "Literal {gps:city}")
        let old = try JSONEncoder().encode(literal)
        XCTAssertNil(try object(literal)["metadataGeocoding"])
        XCTAssertNil(try JSONDecoder().decode(SyncJob.self, from: old).metadataGeocoding)
        var configured = literal; configured.metadataGeocoding = try settings()
        XCTAssertEqual(try JSONDecoder().decode(SyncJob.self, from: JSONEncoder().encode(configured)), configured)
        XCTAssertTrue(configured.requiresVersion3MetadataConfiguration)
        let invalidValues: [Any] = [NSNull(), true, 1, [], [:]]
        for invalid in invalidValues {
            var raw = try object(literal); raw["metadataGeocoding"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(SyncJob.self, from: bytes(raw))) {
                XCTAssertEqual($0 as? MetadataGeocodingSettingsError, .invalidSettings)
            }
        }
        configured.metadataGeocoding?.localeIdentifier = "invalid locale"
        XCTAssertThrowsError(try JSONEncoder().encode(configured))
        configured.metadataGeocoding = nil
        XCTAssertEqual(try object(configured) as NSDictionary, try object(literal) as NSDictionary)
    }

    func testLegacyStoreRefusesAnySettingsPresenceEvenWhenAllDisabled() throws {
        let codec = VersionedStoreCodec(format: .legacy, store: .jobs)
        var job = SyncJob(name: "Literal {gps:city}", metadataProcessingTimeZoneIdentifier: "Europe/Oslo")
        XCTAssertNoThrow(try codec.encode([job], encoder: JSONEncoder()))
        job.metadataGeocoding = try .init(localeIdentifier: "en_US")
        XCTAssertThrowsError(try codec.encode([job], encoder: JSONEncoder())) {
            XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .requiresVersion3Storage)
        }
        XCTAssertThrowsError(try codec.decode([SyncJob].self, from: JSONEncoder().encode([job]), decoder: JSONDecoder()))
        let folder = try root(), primary = folder.appendingPathComponent("jobs.json")
        let retained = try JSONEncoder().encode([job]); try retained.write(to: primary)
        let repository = JobRepository(fileURL: primary)
        XCTAssertThrowsError(try repository.save([]))
        XCTAssertEqual(try Data(contentsOf: primary), retained)
    }

    func testV3MalformedLaterSettingsCannotRecoverOrClobberFromOlderBackup() throws {
        let folder = try root()
        let layout = AppStorageLayout(root: folder, storageFormat: .version3)
        let codec = VersionedStoreCodec(format: .version3, store: .jobs)
        let old = SyncJob(name: "Older")
        let backup = try codec.encode([old], encoder: JSONEncoder())
        try backup.write(to: layout.jobs.appendingPathExtension("backup"))
        var configured = old; configured.metadataGeocoding = try settings()
        let valid = try codec.encode([configured], encoder: JSONEncoder())
        try valid.write(to: layout.jobs)
        let repository = JobRepository(storage: layout)
        XCTAssertEqual(try repository.load(), [configured])
        let malformedValues: [Any] = [NSNull(), ["schemaVersion": 2], try object(settings())]
        for malformed in malformedValues {
            var later = try object(configured); later["metadataGeocoding"] = malformed
            let envelope: [String: Any] = ["format": "AagedalFTPSync.store", "schemaVersion": 3,
                "store": "jobs", "payload": [["invalidEarlierSibling": true], later]]
            let retained = try bytes(envelope); try retained.write(to: layout.jobs)
            XCTAssertThrowsError(try repository.load()) { XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: $0)) }
            XCTAssertThrowsError(try repository.save([old]))
            XCTAssertEqual(try Data(contentsOf: layout.jobs), retained)
            XCTAssertEqual(try Data(contentsOf: layout.jobs.appendingPathExtension("backup")), backup)
        }
    }

    func testConfigurationVersionFollowsSelectedSettingsAndImportStaysStopped() throws {
        var job = SyncJob(name: "Offline", isEnabled: true, startOnAppLaunch: true)
        job.metadataGeocoding = try settings()
        for scope in [ConfigurationTransferScope.jobs, .package] {
            let transfer = ConfigurationTransfer(scope: scope, jobs: [job], metadataPresets: [], photographers: [])
            XCTAssertEqual(transfer.version, 3)
            let passwords: [String?] = [nil, "geocoding-test-password"]
            for password in passwords {
                let encoded = try ConfigurationTransferCodec.encode(transfer, password: password)
                let decoded = try ConfigurationTransferCodec.decode(encoded, password: password)
                let imported = try XCTUnwrap(decoded.jobs.first).preparedForImport()
                XCTAssertEqual(imported.metadataGeocoding, job.metadataGeocoding)
                XCTAssertFalse(imported.isEnabled)
                XCTAssertFalse(imported.startsOnAppLaunch)
            }
        }
        let metadataOnly = ConfigurationTransfer(scope: .metadata, jobs: [job], metadataPresets: [], photographers: [])
        XCTAssertEqual(metadataOnly.version, 2)
        job.metadataGeocoding = nil
        XCTAssertEqual(ConfigurationTransfer(scope: .jobs, jobs: [job], metadataPresets: [], photographers: []).version, 2)
    }

    func testEnabledSettingsRequireOneWayLocalDestinationEvenWithoutSchedule() throws {
        var job = SyncJob(name: "Offline", left: Endpoint(kind: .local, localPath: "/tmp/geocode-source", bookmark: Data([1])),
            right: Endpoint(kind: .local, localPath: "/tmp/geocode-target", bookmark: Data([2])))
        job.metadataGeocoding = try settings()
        XCTAssertNil(job.metadataAutomation)
        XCTAssertNoThrow(try job.validateMetadataGeocodingContext())
        job.direction = .bidirectional
        XCTAssertEqual(job.validationMessage, MetadataGeocodingSettingsError.requiresOneWayJob.localizedDescription)
        XCTAssertThrowsError(try JSONEncoder().encode(job))
        job.direction = .leftToRight
        job.right = Endpoint(kind: .sftp, host: "example.test", port: 22, username: "user", remotePath: "/target",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(job.validationMessage, MetadataGeocodingSettingsError.requiresLocalDestination.localizedDescription)
        XCTAssertThrowsError(try job.validateMetadataGeocodingContext())
        job.metadataGeocoding = try .init(localeIdentifier: "en_US")
        XCTAssertNoThrow(try job.validateMetadataGeocodingContext())
    }

    func testLegacyPackageMarkerMismatchFailsBeforeDomainDecode() throws {
        for version in [1, 2] {
            let malformed = try bytes(["format": ConfigurationTransfer.formatIdentifier, "version": version,
                "ignoredObject": ["metadataGeocoding": NSNull()]])
            XCTAssertThrowsError(try ConfigurationTransferCodec.decode(malformed, password: nil)) {
                XCTAssertEqual($0 as? ConfigurationTransferError, .inconsistentContents)
            }
        }
        var job = SyncJob(name: "Offline"); job.metadataGeocoding = try settings()
        let transfer = ConfigurationTransfer(scope: .jobs, jobs: [job], metadataPresets: [], photographers: [])
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ConfigurationTransferCodec.encode(transfer, password: nil)) as? [String: Any])
        raw["version"] = 2
        XCTAssertThrowsError(try ConfigurationTransferCodec.decode(bytes(raw), password: nil))
    }
}
