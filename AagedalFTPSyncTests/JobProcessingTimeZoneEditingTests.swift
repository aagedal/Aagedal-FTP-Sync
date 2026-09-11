import Foundation
import MetadataTemplates
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

@MainActor
final class JobProcessingTimeZoneEditingTests: XCTestCase {
    private func store(activated: Bool = false) throws -> (AppStore, JobRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zone-editing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root, storageFormat: activated ? .version3 : .legacy)
        let repository = JobRepository(storage: storage)
        var job = SyncJob(name: "Fixture",
            left: Endpoint(kind: .local, localPath: root.appendingPathComponent("source").path, bookmark: Data([1])),
            right: Endpoint(kind: .local, localPath: root.appendingPathComponent("target").path, bookmark: Data([2])),
            isEnabled: false)
        job.startsOnAppLaunch = false
        if activated {
            let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [:])
            for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
            let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "")
            var fields = ScheduledMetadataFields(); fields.setHeadline(try .activated("{photographer}"))
            let clip = MetadataScheduleClip(photographerID: profile.id, name: "Fixture", startsAt: Date(timeIntervalSince1970: 100),
                endsAt: Date(timeIntervalSince1970: 200), fields: fields)
            job.metadataAutomation = MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [clip])
            job.metadataProcessingTimeZoneIdentifier = "Asia/Kathmandu"
        }
        try repository.save([job])
        if activated {
            let store = try AppStore.makePausedForValidatedStorage(storage, retainedCredentialIDs: [], allowsCredentialGarbageCollection: false,
                keychain: KeychainStore(passwordReader: { _ in XCTFail("No credential read"); return nil },
                    passwordWriter: { _, _ in XCTFail("No credential write") }, passwordRemover: { _ in XCTFail("No credential removal") }),
                launchAtLoginCoordinator: ZoneEditingLaunchStub())
            return (store, repository, root)
        }
        let store = AppStore(repository: repository, metadataPresetRepository: MetadataPresetRepository(storage: storage),
            photographerProfileRepository: PhotographerProfileRepository(storage: storage), serverProfileRepository: ServerProfileRepository(storage: storage),
            metadataAuditRepository: MetadataAuditRepository(storage: storage), syncFailureRepository: SyncFailureRepository(storage: storage),
            sourceSignatureRepository: SourceSignatureRepository(storage: storage), downloadManifestRepository: DownloadManifestRepository(storage: storage),
            keychain: KeychainStore(passwordReader: { _ in XCTFail("No credential read"); return nil },
                passwordWriter: { _, _ in XCTFail("No credential write") }, passwordRemover: { _ in XCTFail("No credential removal") }),
            launchAtLoginCoordinator: ZoneEditingLaunchStub(), startsJobsOnInitialization: false)
        return (store, repository, root)
    }

    func testOpeningAndSearchingLeavesLiteralZoneUnsetAndDoesNotDirtyDraft() throws {
        let session = JobEditingSession()
        let job = SyncJob(name: "Literal")
        session.edit(job)
        XCTAssertNil(session.draft.metadataProcessingTimeZoneIdentifier)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertTrue(MetadataProcessingTimeZoneChoices.identifiers(matching: "oslo").contains("Europe/Oslo"))
        XCTAssertTrue(MetadataProcessingTimeZoneChoices.identifiers(matching: "New York").contains("America/New_York"))
        XCTAssertEqual(MetadataProcessingTimeZoneChoices.identifiers(matching: "never-a-real-zone-name"), [])
        XCTAssertNil(session.draft.metadataProcessingTimeZoneIdentifier)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.draft, job)
    }

    func testExplicitChoiceValidatesAtomicallyAndDiscardRestoresUnset() throws {
        let session = JobEditingSession()
        session.edit(SyncJob(name: "Literal"))
        try session.selectMetadataProcessingTimeZone("Europe/Oslo")
        XCTAssertEqual(session.draft.metadataProcessingTimeZoneIdentifier, "Europe/Oslo")
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertThrowsError(try session.selectMetadataProcessingTimeZone("invalid-zone"))
        XCTAssertEqual(session.draft.metadataProcessingTimeZoneIdentifier, "Europe/Oslo")
        session.markDiscarded()
        XCTAssertNil(session.draft.metadataProcessingTimeZoneIdentifier)
        XCTAssertFalse(session.hasUnsavedChanges)
        try session.selectMetadataProcessingTimeZone("Etc/UTC")
        try session.selectMetadataProcessingTimeZone(nil)
        XCTAssertNil(session.draft.metadataProcessingTimeZoneIdentifier)
    }

    func testSavingOtherSettingsPreservesZoneChangedInAnotherWindow() throws {
        let (store, repository, _) = try store()
        let session = JobEditingSession()
        session.edit(try XCTUnwrap(store.jobs.first))
        var latest = try XCTUnwrap(store.jobs.first)
        latest.metadataProcessingTimeZoneIdentifier = "Asia/Kathmandu"
        XCTAssertTrue(store.saveJob(latest, leftPassword: "", rightPassword: ""))
        session.draft.name = "Other edit"
        XCTAssertTrue(session.save(using: store), store.alertMessage ?? "")
        XCTAssertEqual(try repository.load().first?.metadataProcessingTimeZoneIdentifier, "Asia/Kathmandu")
        XCTAssertEqual(session.draft.metadataProcessingTimeZoneIdentifier, "Asia/Kathmandu")
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testExplicitZoneChoiceWinsOverNewerSavedZoneAndClearRemainsLiteral() throws {
        let (store, repository, _) = try store()
        let session = JobEditingSession()
        session.edit(try XCTUnwrap(store.jobs.first))
        try session.selectMetadataProcessingTimeZone("Europe/Oslo")
        var latest = try XCTUnwrap(store.jobs.first)
        latest.metadataProcessingTimeZoneIdentifier = "Asia/Kathmandu"
        XCTAssertTrue(store.saveJob(latest, leftPassword: "", rightPassword: ""))
        XCTAssertTrue(session.save(using: store))
        XCTAssertEqual(try repository.load().first?.metadataProcessingTimeZoneIdentifier, "Europe/Oslo")
        try session.selectMetadataProcessingTimeZone(nil)
        XCTAssertTrue(session.save(using: store))
        XCTAssertNil(try repository.load().first?.metadataProcessingTimeZoneIdentifier)
        XCTAssertNil(store.jobs.first?.metadataAutomation)
    }

    func testZoneSelectionIsOnlyDraftStateUntilSaveAndDoesNotTouchImage() throws {
        let (store, repository, root) = try store()
        let image = root.appendingPathComponent("untouched.jpg")
        let imageBytes = Data("fixture image remains untouched".utf8)
        try imageBytes.write(to: image)
        let session = JobEditingSession()
        session.edit(try XCTUnwrap(store.jobs.first))
        try session.selectMetadataProcessingTimeZone("Etc/UTC")
        XCTAssertNil(try repository.load().first?.metadataProcessingTimeZoneIdentifier)
        XCTAssertTrue(session.save(using: store))
        XCTAssertEqual(try repository.load().first?.metadataProcessingTimeZoneIdentifier, "Etc/UTC")
        XCTAssertEqual(try Data(contentsOf: image), imageBytes)
        XCTAssertEqual(store.phases[session.draft.id], .stopped)
    }

    func testInvalidDirectDraftZoneShowsActionableErrorWithoutSaving() throws {
        let (store, repository, _) = try store()
        let session = JobEditingSession()
        session.edit(try XCTUnwrap(store.jobs.first))
        session.draft.metadataProcessingTimeZoneIdentifier = "invalid-zone"
        XCTAssertFalse(session.save(using: store))
        XCTAssertEqual(store.alertMessage, "Choose a valid processing time zone before saving this job.")
        XCTAssertNil(try repository.load().first?.metadataProcessingTimeZoneIdentifier)
        XCTAssertEqual(session.draft.metadataProcessingTimeZoneIdentifier, "invalid-zone")
    }

    func testStaleLiteralClearCannotResetZoneAfterActivationInAnotherWindow() throws {
        let (store, repository, _) = try store(activated: true)
        let latest = try XCTUnwrap(store.jobs.first)
        var stale = latest
        stale.metadataAutomation = nil
        stale.metadataProcessingTimeZoneIdentifier = nil
        let session = JobEditingSession()
        session.edit(stale)
        try session.selectMetadataProcessingTimeZone(nil)
        XCTAssertFalse(session.save(using: store))
        XCTAssertEqual(store.alertMessage, "A job using metadata variables needs a processing time zone. Choose a zone before saving.")
        XCTAssertEqual(try repository.load().first?.metadataProcessingTimeZoneIdentifier, "Asia/Kathmandu")
        XCTAssertEqual(store.jobs.first, latest)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertThrowsError(try session.selectMetadataProcessingTimeZone(nil))
    }
}

@MainActor
private final class ZoneEditingLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws {}
    func openSettings() {}
}
