import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataFaceRecognitionSettingsTests: XCTestCase {
    private enum ForbiddenSession: Error { case opened }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func bytes(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testStrictSchemaRoundTripsBothKeywordChoices() throws {
        for appendToKeywords in [false, true] {
            let settings = MetadataFaceRecognitionSettings(appendToKeywords: appendToKeywords)
            let encoded = try object(settings)
            XCTAssertEqual(Set(encoded.keys), ["schemaVersion", "appendToKeywords"])
            XCTAssertEqual(encoded["schemaVersion"] as? Int, 1)
            XCTAssertEqual(encoded["appendToKeywords"] as? Bool, appendToKeywords)
            XCTAssertEqual(
                try JSONDecoder().decode(MetadataFaceRecognitionSettings.self, from: bytes(encoded)),
                settings
            )
        }
    }

    func testMalformedSettingsFailClosedAndCannotRecoverBackup() throws {
        let original = try object(MetadataFaceRecognitionSettings())
        var malformed: [[String: Any]] = []
        for key in original.keys {
            var missing = original
            missing.removeValue(forKey: key)
            malformed.append(missing)
            var null = original
            null[key] = NSNull()
            malformed.append(null)
        }
        for (key, value) in [
            ("schemaVersion", 2 as Any),
            ("schemaVersion", true as Any),
            ("appendToKeywords", 1 as Any),
            ("futureChoice", false as Any)
        ] {
            var changed = original
            changed[key] = value
            malformed.append(changed)
        }
        for value in malformed {
            XCTAssertThrowsError(
                try JSONDecoder().decode(MetadataFaceRecognitionSettings.self, from: bytes(value))
            ) {
                XCTAssertEqual($0 as? MetadataFaceRecognitionSettingsError, .invalidSettings)
                XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: $0))
            }
        }
    }

    func testMissingJobSettingIsOffWhilePresentNullAndMalformedFailClosed() throws {
        let legacy = SyncJob(name: "Before face recognition")
        XCTAssertNil(try object(legacy)["metadataFaceRecognition"])
        XCTAssertNil(try JSONDecoder().decode(SyncJob.self, from: JSONEncoder().encode(legacy)).metadataFaceRecognition)

        for invalid in [NSNull(), true, 1, [], [:]] as [Any] {
            var raw = try object(legacy)
            raw["metadataFaceRecognition"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(SyncJob.self, from: bytes(raw))) {
                XCTAssertEqual($0 as? MetadataFaceRecognitionSettingsError, .invalidSettings)
            }
        }

        var configured = legacy
        configured.metadataFaceRecognition = .init(appendToKeywords: true)
        XCTAssertTrue(configured.requiresVersion3MetadataConfiguration)
        XCTAssertEqual(
            try JSONDecoder().decode(SyncJob.self, from: JSONEncoder().encode(configured)),
            configured
        )
        configured.metadataFaceRecognition = nil
        XCTAssertEqual(try object(configured) as NSDictionary, try object(legacy) as NSDictionary)
    }

    func testPresenceRequiresOneWayJobWithLocalDestination() throws {
        let localLeft = Endpoint(kind: .local, localPath: "/tmp/face-source", bookmark: Data([1]))
        let localRight = Endpoint(kind: .local, localPath: "/tmp/face-target", bookmark: Data([2]))
        var job = SyncJob(name: "Faces", left: localLeft, right: localRight)
        job.metadataFaceRecognition = .init()
        XCTAssertNoThrow(try job.validateMetadataFaceRecognitionContext())

        job.direction = .rightToLeft
        XCTAssertNoThrow(try job.validateMetadataFaceRecognitionContext())
        job.left = Endpoint(
            kind: .sftp,
            host: "example.test",
            port: 22,
            username: "user",
            remotePath: "/target",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        XCTAssertThrowsError(try job.validateMetadataFaceRecognitionContext()) {
            XCTAssertEqual($0 as? MetadataFaceRecognitionSettingsError, .requiresLocalDestination)
        }

        job.left = localLeft
        job.direction = .bidirectional
        XCTAssertThrowsError(try JSONEncoder().encode(job)) {
            XCTAssertEqual($0 as? MetadataFaceRecognitionSettingsError, .requiresOneWayJob)
        }
        job.metadataFaceRecognition = nil
        XCTAssertNoThrow(try job.validateMetadataFaceRecognitionContext())
        XCTAssertNil(job.metadataFaceRecognitionRuntimeBlocker)
    }

    func testStoredSettingsExposeActionableRuntimeBlockerUntilRuntimeIsAdmitted() {
        var job = SyncJob(name: "Faces")
        job.isEnabled = false
        job.startsOnAppLaunch = false
        XCTAssertNil(job.metadataFaceRecognitionRuntimeBlocker)
        XCTAssertNil(job.metadataFaceRecognitionSchedulingBlocker)
        job.metadataFaceRecognition = .init()
        let message = job.metadataFaceRecognitionRuntimeBlocker
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("cannot run") == true)
        XCTAssertTrue(message?.contains("Disable face recognition") == true)
        XCTAssertNil(job.metadataFaceRecognitionSchedulingBlocker)

        job.isEnabled = true
        XCTAssertTrue(job.metadataFaceRecognitionSchedulingBlocker?.contains("Turn off Automatic syncing") == true)
        job.isEnabled = false
        job.startsOnAppLaunch = true
        XCTAssertTrue(job.metadataFaceRecognitionSchedulingBlocker?.contains("Enable automatically on app launch") == true)
        job.metadataFaceRecognition = nil
        XCTAssertNil(job.metadataFaceRecognitionSchedulingBlocker)
    }

    func testReprocessingRejectsSavedRecognitionBeforeOpeningAnyFiles() async {
        var job = SyncJob(name: "Faces")
        job.metadataFaceRecognition = .init()
        do {
            _ = try await SyncEngine().reprocessExistingLocalFiles(job: job)
            XCTFail("An unavailable requested recognition stage must not be ignored")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot run"))
            XCTAssertTrue(error.localizedDescription.contains("Disable face recognition"))
        }
    }

    func testNormalRunRejectsSavedRecognitionBeforeOpeningEndpointSessions() async {
        var job = SyncJob(
            name: "Faces",
            left: Endpoint(kind: .local, localPath: "/tmp/face-run-source", bookmark: Data([1])),
            right: Endpoint(kind: .local, localPath: "/tmp/face-run-target", bookmark: Data([2])),
            direction: .leftToRight
        )
        job.metadataFaceRecognition = .init()
        let engine = SyncEngine(sessionFactory: { _, _, _ in throw ForbiddenSession.opened })
        do {
            _ = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTFail("An unavailable requested recognition stage must not be ignored")
        } catch {
            XCTAssertFalse(error is ForbiddenSession)
            XCTAssertTrue(error.localizedDescription.contains("cannot run"))
        }
    }

    func testSettingsRequireVersionThreeStorageAndRecursiveLegacyAdmission() throws {
        var job = SyncJob(name: "Faces")
        let legacy = VersionedStoreCodec(format: .legacy, store: .jobs)
        XCTAssertNoThrow(try legacy.encode([job], encoder: JSONEncoder()))
        job.metadataFaceRecognition = .init()
        XCTAssertThrowsError(try legacy.encode([job], encoder: JSONEncoder())) {
            XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .requiresVersion3Storage)
        }
        let nested = try bytes(["unknown": ["nested": [["metadataFaceRecognition": NSNull()]]]])
        XCTAssertThrowsError(try VersionedStoreCodec.rejectLegacyTemplateMarkers(in: nested)) {
            XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .requiresVersion3Storage)
        }

        let versionThree = VersionedStoreCodec(format: .version3, store: .jobs)
        let admitted = try versionThree.encode([job], encoder: JSONEncoder())
        XCTAssertEqual(try versionThree.decode([SyncJob].self, from: admitted, decoder: JSONDecoder()), [job])
        var malformedJob = try object(job)
        malformedJob["metadataFaceRecognition"] = NSNull()
        let malformedStore = try bytes([
            "format": "AagedalFTPSync.store",
            "schemaVersion": 3,
            "store": "jobs",
            "payload": [malformedJob]
        ])
        XCTAssertThrowsError(
            try versionThree.decode([SyncJob].self, from: malformedStore, decoder: JSONDecoder())
        ) {
            XCTAssertEqual($0 as? MetadataFaceRecognitionSettingsError, .invalidSettings)
            XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: $0))
        }
    }

    func testJobAndPackageTransfersUseVersionThreeWhileMetadataOnlyExcludesSettings() throws {
        var job = SyncJob(name: "Faces", isEnabled: true, startOnAppLaunch: true)
        job.metadataFaceRecognition = .init(appendToKeywords: true)
        for scope in [ConfigurationTransferScope.jobs, .package] {
            let transfer = ConfigurationTransfer(
                scope: scope,
                jobs: [job],
                metadataPresets: [],
                photographers: []
            )
            XCTAssertEqual(transfer.version, 3)
            let decoded = try ConfigurationTransferCodec.decode(
                ConfigurationTransferCodec.encode(transfer, password: nil),
                password: nil
            )
            let imported = try XCTUnwrap(decoded.jobs.first).preparedForImport()
            XCTAssertEqual(imported.metadataFaceRecognition, job.metadataFaceRecognition)
            XCTAssertFalse(imported.isEnabled)
            XCTAssertFalse(imported.startsOnAppLaunch)
        }

        let metadataOnly = ConfigurationTransfer(
            scope: .metadata,
            jobs: [job],
            metadataPresets: [],
            photographers: []
        )
        XCTAssertEqual(metadataOnly.version, 2)
        XCTAssertTrue(metadataOnly.jobs.isEmpty)
        XCTAssertTrue(metadataOnly.metadataProgramming.isEmpty)
    }
}
