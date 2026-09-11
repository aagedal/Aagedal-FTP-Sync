import Foundation
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataGeocodingImportConsentTests: XCTestCase {
    private struct Fixture {
        let storage: AppStorageLayout
        let store: AppStore
        let job: SyncJob
    }

    private func fixture(existingApple: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-import-consent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root, storageFormat: .version3)
        var job = SyncJob(name: "Receiving job", left: Endpoint(kind: .local, localPath: "/fixture/source"),
            right: Endpoint(kind: .local, localPath: "/fixture/target"), isEnabled: false)
        job.startsOnAppLaunch = false
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [storage.jobs.lastPathComponent: encoder.encode([job])])
        for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
        if existingApple {
            job.metadataGeocoding = try .init(cityPolicy: .fillEmpty, localeIdentifier: "en", provider: .apple,
                allowSendingCoordinatesToApple: true)
            job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
            try JobRepository(storage: storage).save([job])
        }
        let keychain = KeychainStore(passwordReader: { _ in XCTFail("Import consent must not read credentials"); return nil },
            passwordWriter: { _, _ in XCTFail("Import consent must not write credentials") },
            passwordRemover: { _ in XCTFail("Import consent must not remove credentials") })
        let store = try AppStore.makePausedForValidatedStorage(storage, retainedCredentialIDs: [],
            allowsCredentialGarbageCollection: false, keychain: keychain,
            launchAtLoginCoordinator: ImportConsentLaunchStub())
        return .init(storage: storage, store: store, job: job)
    }

    private func sourceJob(enabled: Bool = true) throws -> SyncJob {
        let profile = PhotographerProfile(name: "Imported photographer", filenamePrefix: "IM", creator: "Imported", copyrightNotice: "Literal {gps:country}")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Imported clip",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_600),
            fields: .init(headline: "Literal {gps:city}"))
        var job = SyncJob(name: "Imported Apple job", left: Endpoint(kind: .local, localPath: "/export/source"),
            right: Endpoint(kind: .local, localPath: "/export/target"), isEnabled: true,
            metadataAutomation: .init(photographers: [profile], photographerTracks: [], clips: [clip]))
        job.startsOnAppLaunch = true
        job.metadataGeocoding = try .init(cityPolicy: enabled ? .fillEmpty : .disabled, localeIdentifier: "nb",
            provider: .apple, allowSendingCoordinatesToApple: true)
        return job
    }

    private func transfer(scope: ConfigurationTransferScope, enabled: Bool = true, password: String?) throws -> Data {
        let job = try sourceJob(enabled: enabled)
        return try ConfigurationTransferCodec.encode(.init(scope: scope, jobs: [job],
            metadataPresets: [.init(name: "Imported preset", fields: .init(headline: "Literal"))],
            photographers: try XCTUnwrap(job.metadataAutomation).photographers), password: password)
    }

    private func files(_ root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    func testDefaultDenialLeavesAllStoresAndPublishedStateUntouchedPlainAndEncrypted() throws {
        let passwords: [String?] = [nil, "apple-import-test-password"]
        for scope in [ConfigurationTransferScope.jobs, .package] {
            for password in passwords {
                let fixture = try fixture()
                let data = try transfer(scope: scope, password: password)
                let before = try files(fixture.storage.root)
                let jobs = fixture.store.jobs, presets = fixture.store.metadataPresets
                let photographers = fixture.store.photographerLibrary
                let selected = fixture.store.selectedJobID
                XCTAssertNil(fixture.store.importConfiguration(from: data, password: password, expectedScope: scope))
                XCTAssertTrue(fixture.store.alertMessage?.contains("Apple") == true)
                XCTAssertEqual(try files(fixture.storage.root), before)
                XCTAssertEqual(fixture.store.jobs, jobs)
                XCTAssertEqual(fixture.store.metadataPresets, presets)
                XCTAssertEqual(fixture.store.photographerLibrary, photographers)
                XCTAssertEqual(fixture.store.selectedJobID, selected)
                XCTAssertFalse(fixture.store.isSyncing)
            }
        }
    }

    func testExplicitReceivingUserConsentImportsStoppedJobsPlainAndEncrypted() throws {
        let passwords: [String?] = [nil, "apple-import-test-password"]
        for password in passwords {
            let fixture = try fixture()
            let data = try transfer(scope: .package, password: password)
            let result = fixture.store.importConfiguration(from: data, password: password, expectedScope: .package,
                allowImportedAppleCoordinates: true)
            XCTAssertNotNil(result, fixture.store.alertMessage ?? "")
            XCTAssertEqual(result?.importedJobs, 1)
            let imported = try XCTUnwrap(fixture.store.jobs.first { $0.id != fixture.job.id })
            XCTAssertEqual(imported.metadataGeocoding?.provider, .apple)
            XCTAssertEqual(imported.metadataGeocoding?.allowSendingCoordinatesToApple, true)
            XCTAssertEqual(imported.metadataGeocoding?.localeIdentifier, "nb")
            XCTAssertFalse(imported.isEnabled)
            XCTAssertFalse(imported.startsOnAppLaunch)
            XCTAssertFalse(fixture.store.isJobBusy(imported.id))
            XCTAssertEqual(fixture.store.phases[imported.id], .stopped)
            XCTAssertEqual(try JobRepository(storage: fixture.storage).load().first { $0.id == imported.id }, imported)
        }
    }

    func testImportedDisabledAppleChoiceStillRequiresReceivingUserConsent() throws {
        let fixture = try fixture()
        let data = try transfer(scope: .jobs, enabled: false, password: nil)
        let before = try files(fixture.storage.root)
        XCTAssertNil(fixture.store.importConfiguration(from: data, password: nil))
        XCTAssertEqual(try files(fixture.storage.root), before)
        XCTAssertNotNil(fixture.store.importConfiguration(from: data, password: nil, allowImportedAppleCoordinates: true))
        let imported = try XCTUnwrap(fixture.store.jobs.first { $0.id != fixture.job.id })
        XCTAssertEqual(imported.metadataGeocoding?.provider, .apple)
        XCTAssertFalse(imported.metadataGeocoding?.isEnabled ?? true)
        XCTAssertFalse(imported.isEnabled)
    }

    func testMetadataOnlyExportFromAppleJobDoesNotRequireUnrelatedConsent() throws {
        let passwords: [String?] = [nil, "apple-import-test-password"]
        for existingApple in [false, true] {
            for password in passwords {
                let fixture = try fixture(existingApple: existingApple)
                let data = try transfer(scope: .metadata, password: password)
                let decoded = try ConfigurationTransferCodec.decode(data, password: password)
                XCTAssertTrue(decoded.jobs.isEmpty)
                XCTAssertEqual(decoded.version, 2)
                let savedSettings = fixture.store.jobs[0].metadataGeocoding
                let result = fixture.store.importConfiguration(from: data, password: password,
                    expectedScope: .metadata, metadataTargetJobID: fixture.job.id)
                XCTAssertNotNil(result, fixture.store.alertMessage ?? "")
                XCTAssertEqual(result?.importedJobs, 0)
                XCTAssertEqual(result?.importedMetadataProgramming, 1)
                XCTAssertEqual(fixture.store.jobs.count, 1)
                XCTAssertEqual(fixture.store.jobs[0].metadataGeocoding, savedSettings)
                XCTAssertEqual(fixture.store.jobs[0].metadataAutomation?.clips.first?.fields.headline, "Literal {gps:city}")
                XCTAssertFalse(fixture.store.jobs[0].isEnabled)
            }
        }
    }
}

@MainActor
private final class ImportConsentLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws { XCTFail("Import must not change launch at login") }
    func openSettings() { XCTFail("Import must not open system settings") }
}
