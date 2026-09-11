import Foundation
import MetadataTemplates
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataActivationAdmissionTests: XCTestCase {
    private struct Fixture {
        let storage: AppStorageLayout
        let store: AppStore
        let job: SyncJob
    }

    private func fixture(linked: Bool = false, zone: String? = nil, legacy: Bool = false,
                         templateCalendar: Bool = false, revision: Int64 = 1) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activation-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func endpoint(_ name: String) throws -> Endpoint {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bookmark = try FolderBookmark.create(for: url)
            return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
        }
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "Literal {date}")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Fixture",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_600),
            fields: ScheduledMetadataFields(headline: "Literal {photographer}"))
        var job = try SyncJob(name: "Fixture", left: endpoint("source"), right: endpoint("target"), isEnabled: false,
            metadataAutomation: MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [clip]),
            metadataProcessingTimeZoneIdentifier: zone)
        job.startsOnAppLaunch = false
        let storage = AppStorageLayout(root: root, storageFormat: legacy ? .legacy : .version3)
        let keychain = KeychainStore(passwordReader: { _ in XCTFail("Admission must not read credentials"); return nil },
            passwordWriter: { _, _ in XCTFail("Admission must not write credentials") },
            passwordRemover: { _ in XCTFail("Admission must not remove credentials") })
        if legacy {
            try JobRepository(storage: storage).save([job])
            try PhotographerProfileRepository(storage: storage).save([profile])
        } else {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [storage.jobs.lastPathComponent: encoder.encode([job])])
            for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
            try PhotographerProfileRepository(storage: storage).save([profile])
        }
        if linked {
            let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid", registered: true)
            let calendar = SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: revision,
                role: "owner", document: SharedMetadataDocument(job.metadataAutomation!), compatibility: templateCalendar ? .templates : .legacy)
            try MetadataCalendarRepository(storage: storage).save(MetadataCalendarState(accounts: [account], activeAccountID: account.id,
                bindings: [.init(accountID: account.id, jobID: job.id, snapshot: calendar)]))
        }
        let store: AppStore
        if legacy {
            store = AppStore(repository: JobRepository(storage: storage), metadataPresetRepository: MetadataPresetRepository(storage: storage),
                photographerProfileRepository: PhotographerProfileRepository(storage: storage), serverProfileRepository: ServerProfileRepository(storage: storage),
                metadataAuditRepository: MetadataAuditRepository(storage: storage), syncFailureRepository: SyncFailureRepository(storage: storage),
                sourceSignatureRepository: SourceSignatureRepository(storage: storage), downloadManifestRepository: DownloadManifestRepository(storage: storage),
                keychain: keychain, launchAtLoginCoordinator: AdmissionLaunchStub(), startsJobsOnInitialization: false)
        } else {
            store = try AppStore.makePausedForValidatedStorage(storage, retainedCredentialIDs: [], allowsCredentialGarbageCollection: false,
                keychain: keychain, launchAtLoginCoordinator: AdmissionLaunchStub())
        }
        return Fixture(storage: storage, store: store, job: job)
    }

    func testOfflineSettingsSaveFreezesZoneWithoutActivatingSharedSchedule() throws {
        let f = try fixture(linked: true)
        let calendarBefore = try Data(contentsOf: f.storage.metadataCalendar)
        var job = f.job
        job.metadataGeocoding = try .init(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en")
        XCTAssertTrue(f.store.saveJob(job, leftPassword: "", rightPassword: ""), f.store.alertMessage ?? "")
        let saved = try XCTUnwrap(f.store.jobs.first)
        XCTAssertEqual(saved.metadataProcessingTimeZoneIdentifier, TimeZone.current.identifier)
        XCTAssertEqual(saved.metadataAutomation, f.job.metadataAutomation)
        XCTAssertEqual(saved.metadataGeocoding, job.metadataGeocoding)
        XCTAssertEqual(try Data(contentsOf: f.storage.metadataCalendar), calendarBefore)
        let session = JobEditingSession(); session.edit(saved)
        XCTAssertThrowsError(try session.selectMetadataProcessingTimeZone(nil))
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testLegacyJobSaveCannotDropOfflineSettingsSilently() throws {
        let f = try fixture(legacy: true)
        let before = try Data(contentsOf: f.storage.jobs)
        var job = f.job
        job.metadataGeocoding = try .init(localeIdentifier: "en")
        XCTAssertFalse(f.store.saveJob(job, leftPassword: "", rightPassword: ""))
        XCTAssertNil(f.store.jobs.first?.metadataGeocoding)
        XCTAssertEqual(try Data(contentsOf: f.storage.jobs), before)
    }

    private func activeAutomation(_ job: SyncJob) throws -> MetadataAutomation {
        var automation = try XCTUnwrap(job.metadataAutomation)
        automation.clips[0].fields.setHeadline(try .activated("{photographer}"))
        return automation
    }

    private func savedBytes(_ fixture: Fixture) throws -> [String: Data] {
        let stores = [fixture.storage.jobs, fixture.storage.photographers, fixture.storage.metadataPresets, fixture.storage.metadataCalendar]
        return try Dictionary(uniqueKeysWithValues: (stores + stores.map { $0.appendingPathExtension("backup") }).compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (url.lastPathComponent, try Data(contentsOf: url))
        })
    }

    private func transfer(_ job: SyncJob) throws -> Data {
        let value = ConfigurationTransfer(scope: .metadata, jobs: [job], metadataPresets: [], photographers: [])
        return try ConfigurationTransferCodec.encode(value, password: nil)
    }

    func testUnlinkedAutomationSaveInitializesMissingZoneAndPreservesExistingZone() throws {
        for zone in [nil, Optional("Asia/Kathmandu")] {
            let f = try fixture(zone: zone)
            let draft = try activeAutomation(f.job)
            XCTAssertTrue(f.store.saveMetadataAutomation(draft, for: f.job.id), f.store.alertMessage ?? "")
            let saved = try XCTUnwrap(f.store.jobs.first)
            XCTAssertEqual(saved.metadataAutomation, draft)
            XCTAssertEqual(saved.metadataProcessingTimeZoneIdentifier, zone ?? TimeZone.current.identifier)
            XCTAssertEqual(try JobRepository(storage: f.storage).load().first, saved)
            XCTAssertEqual(f.job.metadataProcessingTimeZoneIdentifier, zone)
        }
    }

    func testLinkedAutomationAndJobSavesRejectBeforeAnyPersistenceAndPreserveDraft() throws {
        let f = try fixture(linked: true)
        let before = try savedBytes(f)
        let previous = f.store.jobs
        let draft = try activeAutomation(f.job)
        XCTAssertFalse(f.store.saveMetadataAutomation(draft, for: f.job.id))
        XCTAssertTrue(f.store.alertMessage?.contains("Detach") == true)
        var jobDraft = f.job; jobDraft.metadataAutomation = draft
        XCTAssertFalse(f.store.saveJob(jobDraft, leftPassword: "", rightPassword: ""))
        XCTAssertTrue(f.store.alertMessage?.contains("draft has not been saved") == true)
        XCTAssertEqual(f.store.jobs, previous)
        XCTAssertEqual(try savedBytes(f), before)
        XCTAssertTrue(draft.hasActivatedTemplates)
        XCTAssertNil(jobDraft.metadataProcessingTimeZoneIdentifier)
    }

    func testProfileActivationPropagatesOnlyWhenAllAffectedJobsAreUnlinked() throws {
        for linked in [false, true] {
            let f = try fixture(linked: linked)
            let before = try savedBytes(f)
            var draft = try XCTUnwrap(f.store.photographerLibrary.first)
            draft.setCopyright(try .activated("© {photographer}"))
            XCTAssertEqual(f.store.savePhotographerProfile(draft), !linked)
            if linked {
                XCTAssertEqual(try savedBytes(f), before)
                XCTAssertTrue(f.store.alertMessage?.contains("newer calendar sharing protocol") == true)
                XCTAssertFalse(f.store.photographerLibrary[0].hasActivatedTemplates)
            } else {
                XCTAssertEqual(f.store.jobs[0].metadataAutomation?.photographers[0].copyrightTemplateVersion, 1)
                XCTAssertNotNil(f.store.jobs[0].metadataProcessingTimeZoneIdentifier)
                XCTAssertEqual(f.store.photographerLibrary[0].copyrightTemplateVersion, 1)
            }
            XCTAssertEqual(draft.copyrightTemplateVersion, 1)
        }
    }

    func testMetadataImportInitializesActiveZoneAndRejectsLinkedTargetAtomically() throws {
        for linked in [false, true] {
            let f = try fixture(linked: linked)
            let before = try savedBytes(f)
            var incoming = f.job
            incoming.metadataAutomation = try activeAutomation(incoming)
            let result = f.store.importConfiguration(from: try transfer(incoming), password: nil,
                expectedScope: .metadata, metadataTargetJobID: f.job.id)
            if linked {
                XCTAssertNil(result)
                XCTAssertEqual(try savedBytes(f), before)
                XCTAssertTrue(f.store.alertMessage?.contains("Detach") == true)
            } else {
                XCTAssertNotNil(result, f.store.alertMessage ?? "")
                XCTAssertTrue(f.store.jobs[0].metadataAutomation?.hasActivatedTemplates == true)
                XCTAssertNotNil(f.store.jobs[0].metadataProcessingTimeZoneIdentifier)
            }
        }
        let literal = try fixture()
        XCTAssertNotNil(literal.store.importConfiguration(from: try transfer(literal.job), password: nil,
            expectedScope: .metadata, metadataTargetJobID: literal.job.id))
        XCTAssertNil(literal.store.jobs[0].metadataProcessingTimeZoneIdentifier)
    }

    func testActivePresetRequiresVersionThreeButLiteralPresetStillSaves() throws {
        for legacy in [true, false] {
            let f = try fixture(legacy: legacy)
            var fields = ScheduledMetadataFields(); fields.setHeadline(try .activated("{photographer}"))
            let preset = MetadataPreset(name: "Active", fields: fields)
            let before = try savedBytes(f)
            XCTAssertEqual(f.store.saveMetadataPreset(preset), !legacy)
            if legacy {
                XCTAssertEqual(try savedBytes(f), before)
                XCTAssertTrue(f.store.alertMessage?.contains("Open version 3 storage") == true)
            }
            XCTAssertTrue(f.store.saveMetadataPreset(MetadataPreset(name: "Literal", fields: .init(headline: "{photographer}"))))
        }
    }

    func testUnreadableCalendarAndSyncedActiveAutomationFailWithoutChangingJobs() throws {
        let f = try fixture()
        let before = try Data(contentsOf: f.storage.jobs)
        let draft = try activeAutomation(f.job)
        XCTAssertFalse(f.store.applySyncedMetadataAutomation(draft, for: f.job.id))
        XCTAssertEqual(try Data(contentsOf: f.storage.jobs), before)
        try Data("damaged calendar".utf8).write(to: f.storage.metadataCalendar)
        XCTAssertFalse(f.store.saveMetadataAutomation(draft, for: f.job.id))
        XCTAssertTrue(f.store.alertMessage?.contains("calendar storage recovery") == true)
        XCTAssertEqual(try Data(contentsOf: f.storage.jobs), before)
        XCTAssertFalse(f.store.jobs[0].metadataAutomation?.hasActivatedTemplates ?? true)
    }

    func testConfirmedTemplateCalendarAdmitsOfflineEditorActivationWithoutChangingBaseline() throws {
        let f = try fixture(linked: true, templateCalendar: true)
        let calendarBefore = try Data(contentsOf: f.storage.metadataCalendar)
        let draft = try activeAutomation(f.job)
        XCTAssertTrue(f.store.saveMetadataAutomation(draft, for: f.job.id), f.store.alertMessage ?? "")
        XCTAssertEqual(f.store.jobs[0].metadataAutomation, draft)
        XCTAssertEqual(try Data(contentsOf: f.storage.metadataCalendar), calendarBefore)
        XCTAssertTrue(try XCTUnwrap(JobRepository(storage: f.storage).load().first?.metadataAutomation).hasActivatedTemplates)
        let jobsBefore = try Data(contentsOf: f.storage.jobs)
        XCTAssertFalse(f.store.applySyncedMetadataAutomation(f.job.metadataAutomation!, for: f.job.id))
        XCTAssertEqual(try Data(contentsOf: f.storage.jobs), jobsBefore)
        XCTAssertEqual(f.store.jobs[0].metadataAutomation, draft)
    }

    func testUnconfirmedTemplateCalendarBlocksNewActivation() throws {
        let f = try fixture(linked: true, templateCalendar: true, revision: 0)
        let before = try savedBytes(f)
        XCTAssertFalse(f.store.saveMetadataAutomation(try activeAutomation(f.job), for: f.job.id))
        XCTAssertTrue(f.store.alertMessage?.contains("confirm") == true)
        XCTAssertEqual(try savedBytes(f), before)
    }

    func testSyncedTemplateApplicationRequiresExplicitProtocolAndDurableNamespaceBinding() throws {
        for linked in [false, true] {
            for templateCalendar in [false, true] {
                let f = try fixture(linked: linked, templateCalendar: templateCalendar)
                let draft = try activeAutomation(f.job)
                let before = try Data(contentsOf: f.storage.jobs)
                XCTAssertFalse(f.store.applySyncedMetadataAutomation(draft, for: f.job.id))
                XCTAssertEqual(try Data(contentsOf: f.storage.jobs), before)
                let allowed = linked && templateCalendar
                XCTAssertEqual(f.store.applySyncedMetadataAutomation(draft, for: f.job.id, protocolVersion: .templates), allowed)
                if !allowed { XCTAssertEqual(try Data(contentsOf: f.storage.jobs), before) }
            }
        }
    }
}

@MainActor
private final class AdmissionLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws {}
    func openSettings() {}
}
