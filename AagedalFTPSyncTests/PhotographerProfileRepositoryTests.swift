import Foundation
import XCTest
@testable import AagedalFTPSync

@MainActor
final class PhotographerEditingSessionTests: XCTestCase {
    private func fixture(linked: Bool = true) throws -> (AppStore, PhotographerProfileRepository, PhotographerProfile, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photographer-editing-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root)
        let profiles = PhotographerProfileRepository(fileURL: root.appendingPathComponent("profile-store/photographers.json"))
        let profile = PhotographerProfile(name: "Original", filenamePrefix: "AA", creator: "Creator", copyrightNotice: "Original copyright")
        try profiles.save([profile])
        var job = SyncJob(name: "Linked job")
        job.left = Endpoint(kind: .local, localPath: "/source", bookmark: Data([1]))
        job.right = Endpoint(kind: .local, localPath: "/destination", bookmark: Data([2]))
        job.isEnabled = false
        job.startsOnAppLaunch = false
        if linked { job.metadataAutomation = MetadataAutomation(photographers: [profile]) }
        let jobs = JobRepository(storage: storage)
        try jobs.save([job])
        let store = AppStore(repository: jobs,
            metadataPresetRepository: MetadataPresetRepository(storage: storage),
            photographerProfileRepository: profiles, serverProfileRepository: ServerProfileRepository(storage: storage),
            metadataAuditRepository: MetadataAuditRepository(storage: storage), syncFailureRepository: SyncFailureRepository(storage: storage),
            sourceSignatureRepository: SourceSignatureRepository(storage: storage), downloadManifestRepository: DownloadManifestRepository(storage: storage),
            keychain: KeychainStore(passwordReader: { _ in XCTFail("No credential reads"); return nil },
                passwordWriter: { _, _ in XCTFail("No credential writes") }, passwordRemover: { _ in XCTFail("No credential removals") }),
            startsJobsOnInitialization: false)
        return (store, profiles, profile, root)
    }

    func testCleanDraftRefreshesExternalChangesWithoutBecomingUnsaved() throws {
        let (store, repository, profile, root) = try fixture()
        let first = PhotographerEditingSession()
        let second = PhotographerEditingSession()
        first.edit(profile)
        second.edit(profile)
        second.draft?.copyrightNotice = "New shared copyright"
        second.draft?.filenamePrefix = "BB"
        XCTAssertTrue(second.save(using: store))
        XCTAssertFalse(first.hasUnsavedChanges, "An external change is not a local edit")
        let bytes = try Data(contentsOf: root.appendingPathComponent("profile-store/photographers.json"))

        first.refresh(from: store.photographerLibrary)

        XCTAssertEqual(first.draft, second.draft)
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertNil(first.saveError)
        XCTAssertEqual(try repository.load(), store.photographerLibrary)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profile-store/photographers.json")), bytes)
        XCTAssertEqual(store.jobs.first?.metadataAutomation?.photographers.first?.copyrightNotice, "New shared copyright")
    }

    func testDirtyConflictCancelsAutosaveAndPreservesBothVersions() async throws {
        let (store, repository, profile, _) = try fixture()
        let first = PhotographerEditingSession()
        first.edit(profile)
        first.draft?.creator = "Local unsaved creator"
        let local = first.draft
        first.scheduleAutosave(using: store)
        var external = profile
        external.copyrightNotice = "New external copyright"
        XCTAssertTrue(store.savePhotographerProfile(external))
        let latest = store.photographerLibrary

        first.refresh(from: latest)
        try await Task.sleep(for: .milliseconds(750))

        XCTAssertEqual(first.draft, local)
        XCTAssertTrue(first.hasUnsavedChanges)
        XCTAssertTrue(first.saveError?.contains("Revert") == true)
        XCTAssertFalse(first.save(using: store), "Retry must not overwrite an external revision")
        XCTAssertEqual(store.photographerLibrary, latest)
        XCTAssertEqual(try repository.load(), latest)
        XCTAssertEqual(store.jobs.first?.metadataAutomation?.photographers.first?.copyrightNotice, "New external copyright")
        first.edit(store.photographerLibrary.first)
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertNil(first.saveError)
    }

    func testDeletedProfileCannotBeRecreatedByDirtyAutosave() throws {
        let (store, repository, profile, _) = try fixture(linked: false)
        let session = PhotographerEditingSession()
        session.edit(profile)
        session.draft?.creator = "Retained local edit"
        let local = session.draft
        XCTAssertTrue(store.removePhotographerProfile(profile.id))

        session.refresh(from: store.photographerLibrary)

        XCTAssertEqual(session.draft, local)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertFalse(session.save(using: store))
        XCTAssertTrue(store.photographerLibrary.isEmpty)
        XCTAssertTrue(try repository.load().isEmpty)
        session.edit(nil)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertNil(session.saveError)
    }

    func testFailedSaveRetainsDraftAndRetryAdoptsPersistedBaseline() throws {
        let (store, repository, profile, root) = try fixture()
        let session = PhotographerEditingSession()
        session.edit(profile)
        session.draft?.copyrightNotice = "Retry copyright"
        let local = session.draft
        let directory = root.appendingPathComponent("profile-store")
        try FileManager.default.removeItem(at: directory)
        try Data("blocked repository".utf8).write(to: directory)

        XCTAssertFalse(session.save(using: store))
        XCTAssertEqual(session.draft, local)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(store.photographerLibrary, [profile])
        XCTAssertEqual(store.jobs.first?.metadataAutomation?.photographers.first, profile)

        try FileManager.default.removeItem(at: directory)
        try repository.save([profile])
        XCTAssertTrue(session.save(using: store), store.alertMessage ?? "")
        XCTAssertEqual(session.draft, try repository.load().first)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(store.jobs.first?.metadataAutomation?.photographers.first?.copyrightNotice, "Retry copyright")
    }
}

final class PhotographerProfileRepositoryTests: XCTestCase {
    func testMissingLibraryLoadsAsEmpty() throws {
        let fileURL = temporaryFileURL()
        let repository = PhotographerProfileRepository(fileURL: fileURL)

        let result = try repository.loadResult()

        XCTAssertTrue(result.photographers.isEmpty)
        XCTAssertFalse(result.recoveredFromBackup)
    }

    func testRoundTripsPhotographers() throws {
        let fileURL = temporaryFileURL()
        defer { removeRepositoryFiles(at: fileURL) }
        let repository = PhotographerProfileRepository(fileURL: fileURL)
        let photographers = [
            PhotographerProfile(
                name: "Jane Doe",
                filenamePrefix: "JAD",
                creator: "Jane Doe",
                copyrightNotice: "Example News",
                workHours: PhotographerWorkHours(startMinutes: 8 * 60 + 30, endMinutes: 16 * 60 + 30)
            ),
            PhotographerProfile(
                name: "John Smith",
                filenamePrefix: "JOS",
                creator: "John Smith",
                copyrightNotice: "Example News"
            ),
        ]

        try repository.save(photographers)

        XCTAssertEqual(try repository.load(), photographers)
    }

    func testRecoversFromBackupWhenPrimaryFileIsCorrupt() throws {
        let fileURL = temporaryFileURL()
        defer { removeRepositoryFiles(at: fileURL) }
        let repository = PhotographerProfileRepository(fileURL: fileURL)
        let recoverable = [
            PhotographerProfile(
                name: "Jane Doe",
                filenamePrefix: "JAD",
                creator: "Jane Doe",
                copyrightNotice: "Example News"
            ),
        ]

        try repository.save(recoverable)
        try repository.save([])
        try Data("not valid JSON".utf8).write(to: fileURL, options: .atomic)

        let result = try repository.loadResult()

        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.photographers, recoverable)
    }

    func testTransferCodecRoundTripsVersionedPhotographerList() throws {
        let photographers = [
            PhotographerProfile(
                name: "Jane Doe",
                filenamePrefix: "JAD, CAM2",
                creator: "Jane Doe",
                copyrightNotice: "Example News",
                workHours: PhotographerWorkHours(startMinutes: 8 * 60, endMinutes: 16 * 60)
            ),
        ]

        let data = try PhotographerLibraryTransferCodec.encode(photographers)
        let transfer = try JSONDecoder().decode(PhotographerLibraryTransfer.self, from: data)

        XCTAssertEqual(transfer.format, PhotographerLibraryTransfer.formatIdentifier)
        XCTAssertEqual(transfer.version, PhotographerLibraryTransfer.currentVersion)
        XCTAssertEqual(try PhotographerLibraryTransferCodec.decode(data), photographers)
    }

    func testTransferCodecAcceptsLegacyRawPhotographerArray() throws {
        let photographers = [
            PhotographerProfile(
                name: "Jane Doe",
                filenamePrefix: "JAD",
                creator: "Jane Doe",
                copyrightNotice: "Example News"
            ),
        ]
        let data = try JSONEncoder().encode(photographers)

        XCTAssertEqual(try PhotographerLibraryTransferCodec.decode(data), photographers)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("photographers-\(UUID().uuidString).json")
    }

    private func removeRepositoryFiles(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("backup"))
    }
}

@MainActor
final class PhotographerLibraryAppStoreTests: XCTestCase {
    func testSavingProgrammingMakesPhotographerAvailableAcrossJobsAndSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photographer-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let bookmark = Data([1])
        let firstJob = SyncJob(
            name: "First desk",
            left: Endpoint(kind: .local, localPath: "/first-source", bookmark: bookmark),
            right: Endpoint(kind: .local, localPath: "/first-target", bookmark: bookmark),
            direction: .leftToRight,
            isEnabled: false
        )
        let secondJob = SyncJob(
            name: "Second desk",
            left: Endpoint(kind: .local, localPath: "/second-source", bookmark: bookmark),
            right: Endpoint(kind: .local, localPath: "/second-target", bookmark: bookmark),
            direction: .leftToRight,
            isEnabled: false
        )
        try jobRepository.save([firstJob, secondJob])
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "Example News"
        )

        let firstStore = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )
        XCTAssertTrue(firstStore.saveMetadataAutomation(
            MetadataAutomation(photographers: [photographer]),
            for: firstJob.id
        ))

        let secondStore = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )

        XCTAssertEqual(secondStore.photographerLibrary, [photographer])
        XCTAssertEqual(secondStore.jobs.first(where: { $0.id == secondJob.id })?.metadataAutomation, nil)
    }

    func testExistingJobPhotographersMigrateIntoSharedLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photographer-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "Example News"
        )
        var job = SyncJob(name: "Existing desk")
        job.isEnabled = false
        job.metadataAutomation = MetadataAutomation(photographers: [photographer])
        try jobRepository.save([job])

        let store = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )

        XCTAssertEqual(store.photographerLibrary, [photographer])
        XCTAssertEqual(try photographerRepository.load(), [photographer])
    }

    func testEditingSharedPhotographerUpdatesAssignedJobsAndPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photographer-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "Example News"
        )
        var job = SyncJob(name: "Picture desk")
        job.isEnabled = false
        job.metadataAutomation = MetadataAutomation(photographers: [photographer])
        try jobRepository.save([job])
        try photographerRepository.save([photographer])
        let store = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )
        var updated = PhotographerProfile(
            id: photographer.id,
            name: "Jane Photographer",
            filenamePrefix: " jap, JAX, jap ",
            creator: "Jane Photographer",
            copyrightNotice: "Example News",
            workHours: PhotographerWorkHours(startMinutes: 9 * 60, endMinutes: 17 * 60)
        )
        updated.setWorkHoursOverride(
            PhotographerWorkHours(startMinutes: 12 * 60, endMinutes: 20 * 60),
            on: Date(timeIntervalSince1970: 1_788_134_400),
            calendar: Calendar(identifier: .gregorian)
        )
        var expected = updated
        expected.filenamePrefix = "JAP, JAX"

        XCTAssertTrue(store.savePhotographerProfile(updated))

        XCTAssertEqual(store.photographerLibrary, [expected])
        XCTAssertEqual(store.jobs.first?.metadataAutomation?.photographers, [expected])
        XCTAssertEqual(try photographerRepository.load(), [expected])
        XCTAssertEqual(try jobRepository.load().first?.metadataAutomation?.photographers, [expected])
    }

    func testAssignedSharedPhotographerMustBeRemovedFromJobsBeforeDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photographer-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let assigned = PhotographerProfile(
            name: "Assigned",
            filenamePrefix: "ASG",
            creator: "",
            copyrightNotice: ""
        )
        let unused = PhotographerProfile(
            name: "Unused",
            filenamePrefix: "UNU",
            creator: "",
            copyrightNotice: ""
        )
        var job = SyncJob(name: "Picture desk")
        job.isEnabled = false
        job.metadataAutomation = MetadataAutomation(photographers: [assigned])
        try jobRepository.save([job])
        try photographerRepository.save([assigned, unused])
        let store = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )

        XCTAssertFalse(store.removePhotographerProfile(assigned.id))
        XCTAssertTrue(store.photographerLibrary.contains(where: { $0.id == assigned.id }))
        XCTAssertTrue(store.removePhotographerProfile(unused.id))
        XCTAssertFalse(store.photographerLibrary.contains(where: { $0.id == unused.id }))
    }

    func testSharedLibraryRejectsDuplicateSecondaryCameraInitials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photographer-duplicate-initials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let first = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD, CAM2",
            creator: "Jane",
            copyrightNotice: ""
        )
        try photographerRepository.save([first])
        let store = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )
        let second = PhotographerProfile(
            name: "John",
            filenamePrefix: "JOS, cam2",
            creator: "John",
            copyrightNotice: ""
        )

        XCTAssertFalse(store.savePhotographerProfile(second))
        XCTAssertEqual(store.alertMessage, "The filename initials CAM2 are already used by another photographer.")
        XCTAssertEqual(store.photographerLibrary, [first])
    }

    func testProgrammingCannotIntroduceDuplicateInitialsIntoSharedLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("programming-duplicate-initials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let existing = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD, CAM2",
            creator: "Jane",
            copyrightNotice: ""
        )
        let bookmark = Data([1])
        let job = SyncJob(
            name: "Picture desk",
            left: Endpoint(kind: .local, localPath: "/source", bookmark: bookmark),
            right: Endpoint(kind: .local, localPath: "/target", bookmark: bookmark),
            direction: .leftToRight,
            isEnabled: false
        )
        try jobRepository.save([job])
        try photographerRepository.save([existing])
        let store = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )
        let incoming = PhotographerProfile(
            name: "John",
            filenamePrefix: "JOS, cam2",
            creator: "John",
            copyrightNotice: ""
        )

        XCTAssertFalse(store.saveMetadataAutomation(
            MetadataAutomation(photographers: [incoming]),
            for: job.id
        ))
        XCTAssertEqual(store.alertMessage, "The filename initials CAM2 are already used by another photographer.")
        XCTAssertNil(store.jobs.first?.metadataAutomation)
        XCTAssertEqual(store.photographerLibrary, [existing])
    }

    func testImportMergesPhotographersAndUpdatesAssignedJobs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photographer-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let assigned = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "Old copyright"
        )
        let retained = PhotographerProfile(
            name: "Retained",
            filenamePrefix: "RET",
            creator: "Retained",
            copyrightNotice: ""
        )
        var job = SyncJob(name: "Picture desk")
        job.isEnabled = false
        job.metadataAutomation = MetadataAutomation(photographers: [assigned])
        try jobRepository.save([job])
        try photographerRepository.save([assigned, retained])
        let store = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )
        let updated = PhotographerProfile(
            id: assigned.id,
            name: "Legacy name",
            filenamePrefix: " jad, cam2 ",
            creator: "Jane Updated",
            copyrightNotice: "New copyright"
        )
        let added = PhotographerProfile(
            name: "Alice",
            filenamePrefix: "ALI",
            creator: "Alice",
            copyrightNotice: "Example News"
        )
        let data = try PhotographerLibraryTransferCodec.encode([updated, added])

        let result = store.importPhotographerLibrary(from: data)

        XCTAssertEqual(result, PhotographerLibraryImportResult(
            addedCount: 1,
            updatedCount: 1,
            unchangedCount: 0
        ))
        let importedUpdate = store.photographerLibrary.first { $0.id == assigned.id }
        XCTAssertEqual(importedUpdate?.name, "Jane Updated")
        XCTAssertEqual(importedUpdate?.creator, "Jane Updated")
        XCTAssertEqual(importedUpdate?.filenamePrefix, "JAD, CAM2")
        XCTAssertTrue(store.photographerLibrary.contains(where: { $0.id == retained.id }))
        XCTAssertTrue(store.photographerLibrary.contains(where: { $0.id == added.id }))
        XCTAssertEqual(store.jobs.first?.metadataAutomation?.photographers, [importedUpdate].compactMap { $0 })
        XCTAssertEqual(try photographerRepository.load(), store.photographerLibrary)
        XCTAssertEqual(try jobRepository.load(), store.jobs)
    }

    func testImportRejectsConflictingInitialsWithoutChangingLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photographer-import-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let photographerRepository = PhotographerProfileRepository(
            fileURL: root.appendingPathComponent("photographers.json")
        )
        let existing = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD, CAM2",
            creator: "Jane",
            copyrightNotice: ""
        )
        try photographerRepository.save([existing])
        let store = AppStore(
            repository: jobRepository,
            photographerProfileRepository: photographerRepository
        )
        let conflicting = PhotographerProfile(
            name: "John",
            filenamePrefix: "cam2",
            creator: "John",
            copyrightNotice: ""
        )
        let data = try PhotographerLibraryTransferCodec.encode([conflicting])

        XCTAssertNil(store.importPhotographerLibrary(from: data))
        XCTAssertEqual(store.alertMessage, "The photographers could not be imported: The filename initials CAM2 are already used by another photographer.")
        XCTAssertEqual(store.photographerLibrary, [existing])
        XCTAssertEqual(try photographerRepository.load(), [existing])
    }
}
