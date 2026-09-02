import Foundation
import XCTest
@testable import AagedalFTPSync

final class ConfigurationTransferTests: XCTestCase {
    private let password = "correct horse battery staple"

    func testPackageRoundTripsThroughAuthenticatedEncryption() throws {
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .package,
            jobs: [fixture.job],
            metadataPresets: [fixture.preset],
            photographers: [fixture.photographer],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encrypted = try ConfigurationTransferCodec.encode(transfer, password: password)
        let decoded = try ConfigurationTransferCodec.decode(encrypted, password: password)

        XCTAssertEqual(decoded.scope, .package)
        XCTAssertEqual(decoded.jobs.count, 1)
        XCTAssertEqual(decoded.jobs[0].name, fixture.job.name)
        XCTAssertNil(decoded.jobs[0].metadataAutomation)
        XCTAssertNil(decoded.jobs[0].left.bookmark)
        XCTAssertNil(decoded.jobs[0].right.bookmark)
        XCTAssertNotEqual(decoded.jobs[0].left.credentialID, fixture.job.left.credentialID)
        XCTAssertTrue(decoded.jobs[0].verifiesMatchingFileContents)
        XCTAssertEqual(decoded.metadataProgramming.count, 1)
        XCTAssertEqual(decoded.metadataProgramming[0].automation, fixture.job.metadataAutomation)
        XCTAssertEqual(decoded.metadataPresets, [fixture.preset])
        XCTAssertEqual(decoded.photographers, [fixture.photographer])
    }

    func testPackageCanRoundTripWithoutEncryption() throws {
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .package,
            jobs: [fixture.job],
            metadataPresets: [fixture.preset],
            photographers: [fixture.photographer]
        )

        let unencrypted = try ConfigurationTransferCodec.encode(transfer, password: nil)
        let decoded = try ConfigurationTransferCodec.decode(unencrypted, password: nil)

        XCTAssertEqual(try ConfigurationTransferCodec.protection(of: unencrypted), .unencrypted)
        XCTAssertEqual(decoded.scope, .package)
        XCTAssertEqual(decoded.jobs.map(\.name), [fixture.job.name])
        XCTAssertNil(decoded.jobs[0].left.bookmark)
        XCTAssertEqual(decoded.metadataProgramming[0].automation, fixture.job.metadataAutomation)
        let text = String(decoding: unencrypted, as: UTF8.self)
        XCTAssertTrue(text.contains(fixture.job.name))
        XCTAssertTrue(text.contains(fixture.job.left.host))
    }

    func testEncryptedPackageReportsThatPasswordIsRequired() throws {
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [fixture.job],
            metadataPresets: [],
            photographers: []
        )
        let encrypted = try ConfigurationTransferCodec.encode(transfer, password: password)

        XCTAssertEqual(try ConfigurationTransferCodec.protection(of: encrypted), .encrypted)
        XCTAssertThrowsError(try ConfigurationTransferCodec.decode(encrypted, password: nil)) { error in
            XCTAssertEqual(error as? ConfigurationTransferError, .passwordRequired)
        }
    }

    func testSeparateScopesContainOnlyRequestedContent() throws {
        let fixture = makeFixture()
        let jobs = ConfigurationTransfer(
            scope: .jobs,
            jobs: [fixture.job],
            metadataPresets: [fixture.preset],
            photographers: [fixture.photographer]
        )
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertTrue(jobs.metadataProgramming.isEmpty)
        XCTAssertTrue(jobs.metadataPresets.isEmpty)
        XCTAssertTrue(jobs.photographers.isEmpty)

        let metadata = ConfigurationTransfer(
            scope: .metadata,
            jobs: [fixture.job],
            metadataPresets: [fixture.preset],
            photographers: [fixture.photographer]
        )
        XCTAssertTrue(metadata.jobs.isEmpty)
        XCTAssertEqual(metadata.metadataProgramming.count, 1)
        XCTAssertEqual(metadata.metadataPresets, [fixture.preset])
        XCTAssertEqual(metadata.photographers, [fixture.photographer])
    }

    func testWrongPasswordAndTamperingAreRejected() throws {
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .package,
            jobs: [fixture.job],
            metadataPresets: [],
            photographers: []
        )
        let encrypted = try ConfigurationTransferCodec.encode(transfer, password: password)

        XCTAssertThrowsError(
            try ConfigurationTransferCodec.decode(encrypted, password: "this is the wrong password")
        ) { error in
            XCTAssertEqual(error as? ConfigurationTransferError, .wrongPasswordOrDamagedFile)
        }

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encrypted) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["sealedPayload"] as? String)))
        sealed[sealed.startIndex] ^= 0x01
        object["sealedPayload"] = sealed.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try ConfigurationTransferCodec.decode(tampered, password: password)
        ) { error in
            XCTAssertEqual(error as? ConfigurationTransferError, .wrongPasswordOrDamagedFile)
        }
    }

    func testEncryptedFileDoesNotExposeConfigurationStrings() throws {
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .package,
            jobs: [fixture.job],
            metadataPresets: [fixture.preset],
            photographers: [fixture.photographer]
        )
        let encrypted = try ConfigurationTransferCodec.encode(transfer, password: password)
        let outerText = String(decoding: encrypted, as: UTF8.self)

        XCTAssertFalse(outerText.contains(fixture.job.name))
        XCTAssertFalse(outerText.contains(fixture.job.left.host))
        XCTAssertFalse(outerText.contains(fixture.preset.name))
        XCTAssertFalse(outerText.contains(fixture.photographer.photographerName))
    }

    func testExportRequiresTwelveCharacterPassword() {
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [fixture.job],
            metadataPresets: [],
            photographers: []
        )

        XCTAssertThrowsError(
            try ConfigurationTransferCodec.encode(transfer, password: "too short")
        ) { error in
            XCTAssertEqual(error as? ConfigurationTransferError, .passwordTooShort)
        }
    }

    func testPreparedImportedJobIsSafeAndDisabled() {
        let fixture = makeFixture()
        let imported = fixture.job.preparedForImport()

        XCTAssertNotEqual(imported.id, fixture.job.id)
        XCTAssertFalse(imported.isEnabled)
        XCTAssertFalse(imported.startsOnAppLaunch)
        XCTAssertNil(imported.left.bookmark)
        XCTAssertNil(imported.right.bookmark)
        XCTAssertNotEqual(imported.left.credentialID, fixture.job.left.credentialID)
        XCTAssertNotEqual(imported.right.credentialID, fixture.job.right.credentialID)
    }

    func testJobsExportIncludesOnlyReferencedServerProfilesWithoutCredentialReferences() throws {
        let referenced = ServerProfile(
            name: "Picture Desk",
            kind: .sftp,
            host: "pictures.example.test",
            username: "desk",
            credentialID: "saved-picture-desk-password",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        let unreferenced = ServerProfile(
            name: "Archive",
            kind: .ftp,
            host: "archive.example.test",
            username: "archive",
            credentialID: "saved-archive-password"
        )
        var job = SyncJob(name: "Profile-backed job")
        job.left = referenced.endpoint(remotePath: "/incoming/camera-1")
        job.right = Endpoint(kind: .local)

        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [job],
            serverProfiles: [referenced, unreferenced],
            metadataPresets: [],
            photographers: []
        )
        let encoded = try ConfigurationTransferCodec.encode(transfer, password: nil)
        let decoded = try ConfigurationTransferCodec.decode(encoded, password: nil)

        XCTAssertEqual(decoded.serverProfiles.count, 1)
        XCTAssertEqual(decoded.serverProfiles[0].id, referenced.id)
        XCTAssertEqual(decoded.serverProfiles[0].name, referenced.name)
        XCTAssertNotEqual(decoded.serverProfiles[0].credentialID, referenced.credentialID)
        XCTAssertEqual(decoded.jobs[0].left.serverProfileID, referenced.id)
        XCTAssertEqual(decoded.jobs[0].left.credentialID, decoded.serverProfiles[0].credentialID)
        XCTAssertEqual(decoded.jobs[0].left.remotePath, "/incoming/camera-1")
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(referenced.credentialID))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(unreferenced.credentialID))
    }

    func testLegacyPackageWithoutProfilesDecodesWithEmptyProfileLibrary() throws {
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [fixture.job],
            metadataPresets: [],
            photographers: []
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ConfigurationTransferCodec.encode(transfer, password: nil)
            ) as? [String: Any]
        )
        object["version"] = 1
        object.removeValue(forKey: "serverProfiles")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try ConfigurationTransferCodec.decode(legacyData, password: nil)

        XCTAssertTrue(decoded.serverProfiles.isEmpty)
        XCTAssertEqual(decoded.version, 1)
    }

    func testCurrentExportsUsePayloadVersionTwo() throws {
        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [SyncJob(name: "Current package")],
            metadataPresets: [],
            photographers: []
        )

        let decoded = try ConfigurationTransferCodec.decode(
            ConfigurationTransferCodec.encode(transfer, password: nil),
            password: nil
        )

        XCTAssertEqual(decoded.version, 2)
    }

    func testVersionTwoPackageRejectsMissingReferencedServerProfile() throws {
        let profile = ServerProfile(
            name: "Required FTP",
            kind: .ftp,
            host: "required.example.test",
            username: "desk"
        )
        var job = SyncJob(name: "Requires profile")
        job.left = profile.endpoint(remotePath: "/incoming")
        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [job],
            serverProfiles: [profile],
            metadataPresets: [],
            photographers: []
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ConfigurationTransferCodec.encode(transfer, password: nil)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "serverProfiles")
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try ConfigurationTransferCodec.decode(malformed, password: nil)
        ) { error in
            XCTAssertEqual(error as? ConfigurationTransferError, .inconsistentContents)
        }
    }

    func testPackageRejectsDuplicateProfilesAndFiltersUnreferencedProfiles() {
        let profile = ServerProfile(
            name: "News FTP",
            kind: .ftp,
            host: "news.example.test",
            username: "desk"
        )
        var referencedJob = SyncJob(name: "Referenced")
        referencedJob.left = profile.endpoint(remotePath: "/incoming")
        let duplicate = ConfigurationTransfer(
            scope: .jobs,
            jobs: [referencedJob],
            serverProfiles: [profile, profile],
            metadataPresets: [],
            photographers: []
        )
        XCTAssertThrowsError(try ConfigurationTransferCodec.encode(duplicate, password: nil)) { error in
            XCTAssertEqual(error as? ConfigurationTransferError, .inconsistentContents)
        }

        let unreferenced = ConfigurationTransfer(
            scope: .jobs,
            jobs: [SyncJob(name: "Embedded")],
            serverProfiles: [profile],
            metadataPresets: [],
            photographers: []
        )
        XCTAssertTrue(unreferenced.serverProfiles.isEmpty)
    }

    @MainActor
    func testAppStorePersistsImportedServerProfileAndResolvableJobReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("configuration-profile-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let serverRepository = ServerProfileRepository(fileURL: root.appendingPathComponent("servers.json"))
        let profile = ServerProfile(
            name: "Imported SFTP",
            kind: .sftp,
            host: "sftp.example.test",
            username: "desk",
            credentialID: "source-credential",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        var job = SyncJob(name: "Imported profile job")
        job.left = profile.endpoint(remotePath: "/camera")
        job.right = Endpoint(kind: .local)
        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [job],
            serverProfiles: [profile],
            metadataPresets: [],
            photographers: []
        )
        let data = try ConfigurationTransferCodec.encode(transfer, password: nil)
        let store = AppStore(
            repository: jobRepository,
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            photographerProfileRepository: PhotographerProfileRepository(
                fileURL: root.appendingPathComponent("photographers.json")
            ),
            serverProfileRepository: serverRepository,
            metadataAuditRepository: MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json"))
        )

        let result = try XCTUnwrap(store.importConfiguration(from: data, password: nil))

        XCTAssertEqual(result.importedServerProfiles, 1)
        let importedProfile = try XCTUnwrap(store.serverProfiles.first)
        let importedJob = try XCTUnwrap(store.jobs.first)
        XCTAssertEqual(importedJob.left.serverProfileID, importedProfile.id)
        XCTAssertEqual(importedJob.left.remotePath, "/camera")
        XCTAssertEqual(try serverRepository.load(), [importedProfile])
        XCTAssertEqual(try jobRepository.load(), [importedJob])
        XCTAssertNoThrow(try importedJob.resolvingServerProfiles(in: store.serverProfiles))
    }

    @MainActor
    func testAppStoreImportsPackageAsSafeCopyAndPersistsLibraries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("configuration-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let presetRepository = MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let auditRepository = MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json"))
        let fixture = makeFixture()
        let transfer = ConfigurationTransfer(
            scope: .package,
            jobs: [fixture.job],
            metadataPresets: [fixture.preset],
            photographers: [fixture.photographer]
        )
        let data = try ConfigurationTransferCodec.encode(transfer, password: password)
        let store = AppStore(
            repository: jobRepository,
            metadataPresetRepository: presetRepository,
            photographerProfileRepository: photographerRepository,
            metadataAuditRepository: auditRepository
        )

        let result = try XCTUnwrap(store.importConfiguration(from: data, password: password))

        XCTAssertEqual(result.importedJobs, 1)
        XCTAssertEqual(result.importedMetadataProgramming, 1)
        let importedJob = try XCTUnwrap(store.jobs.first)
        XCTAssertNotEqual(importedJob.id, fixture.job.id)
        XCTAssertFalse(importedJob.isEnabled)
        XCTAssertFalse(importedJob.startsOnAppLaunch)
        XCTAssertNil(importedJob.left.bookmark)
        XCTAssertNil(importedJob.right.bookmark)
        XCTAssertEqual(importedJob.metadataAutomation, fixture.job.metadataAutomation)
        XCTAssertEqual(store.metadataPresets, [fixture.preset])
        XCTAssertEqual(store.photographerLibrary, [fixture.photographer])
        XCTAssertEqual(try jobRepository.load(), store.jobs)
        XCTAssertEqual(try presetRepository.load(), store.metadataPresets)
        XCTAssertEqual(try photographerRepository.load(), store.photographerLibrary)
    }

    private func makeFixture() -> (
        job: SyncJob,
        photographer: PhotographerProfile,
        preset: MetadataPreset
    ) {
        let photographer = PhotographerProfile(
            name: "Ada Photographer",
            filenamePrefix: "ADA",
            creator: "Ada Photographer",
            copyrightNotice: "Copyright Ada"
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Morning assignment",
            startsAt: start,
            endsAt: start.addingTimeInterval(3_600),
            fields: ScheduledMetadataFields(
                headline: "City hall",
                description: "Press conference",
                keywords: ["news", "city"]
            )
        )
        let automation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [clip]
        )
        var job = SyncJob(
            name: "Secret Newsroom Job",
            left: Endpoint(
                kind: .sftp,
                bookmark: Data("left bookmark".utf8),
                host: "secret.example.test",
                username: "newsroom",
                credentialID: "left-keychain-reference",
                hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            ),
            right: Endpoint(
                kind: .local,
                localPath: "/Volumes/Newsroom",
                bookmark: Data("right bookmark".utf8),
                credentialID: "right-keychain-reference"
            )
        )
        job.metadataAutomation = automation
        job.verifiesMatchingFileContents = true
        let preset = MetadataPreset(name: "Breaking news", fields: clip.fields)
        return (job, photographer, preset)
    }
}
