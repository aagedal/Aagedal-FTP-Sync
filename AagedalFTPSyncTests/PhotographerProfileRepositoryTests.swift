import Foundation
import XCTest
@testable import AagedalFTPSync

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
