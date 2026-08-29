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
                copyrightNotice: "Example News"
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
}
