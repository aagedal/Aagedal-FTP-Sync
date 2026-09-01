import Foundation
import XCTest
@testable import AagedalFTPSync

@MainActor
final class AppPersistenceCoordinatorTests: XCTestCase {
    func testLoadAggregatesRecoveredRepositoryStateAndWarnings() throws {
        let fixture = try PersistenceCoordinatorFixture(prefix: "load-recovery")
        defer { fixture.removeTemporaryFiles() }

        let job = SyncJob(name: "Recovered job")
        let preset = MetadataPreset(name: "Recovered preset")
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "Example News"
        )
        let auditEntry = MetadataAuditEntry(
            runID: UUID(),
            jobID: job.id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            operation: .transfer,
            relativePath: "incoming/JAD_0001.jpg",
            status: .applied,
            timestampPolicy: .sourceModification,
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let failureEntry = SyncFailureRecord(
            jobID: job.id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_001),
            message: "The source was unavailable."
        )

        try fixture.jobRepository.save([job])
        try fixture.jobRepository.save([SyncJob(name: "Newer job")])
        try fixture.metadataPresetRepository.save([preset])
        try fixture.metadataPresetRepository.save([MetadataPreset(name: "Newer preset")])
        try fixture.photographerProfileRepository.save([photographer])
        try fixture.photographerProfileRepository.save([])
        try fixture.metadataAuditRepository.save([auditEntry])
        try fixture.metadataAuditRepository.save([])
        try fixture.syncFailureRepository.save([failureEntry])
        try fixture.syncFailureRepository.save([])

        try fixture.corruptPrimaryFiles()

        let result = fixture.coordinator.load()

        XCTAssertTrue(result.jobsRecoveredFromBackup)
        XCTAssertEqual(result.state.jobs, [job])
        XCTAssertEqual(result.state.metadataPresets, [preset])
        XCTAssertEqual(result.state.photographerLibrary, [photographer])
        XCTAssertEqual(result.state.metadataAuditEntries[job.id], [auditEntry])
        XCTAssertEqual(result.state.syncFailureEntries[job.id], [failureEntry])
        XCTAssertEqual(result.warnings.count, 5)
        XCTAssertTrue(result.warnings.contains { $0.contains("metadata preset library was damaged") })
        XCTAssertTrue(result.warnings.contains { $0.contains("photographer library was damaged") })
        XCTAssertTrue(result.warnings.contains { $0.contains("jobs file was damaged") })
        XCTAssertTrue(result.warnings.contains { $0.contains("metadata audit trail was damaged") })
        XCTAssertTrue(result.warnings.contains { $0.contains("sync error log was damaged") })
    }

    func testSaveJobsAndPhotographersRollsBackPhotographersWhenUpdatedJobEncodingFails() throws {
        let fixture = try PersistenceCoordinatorFixture(prefix: "photographer-rollback")
        defer { fixture.removeTemporaryFiles() }

        let photographerID = UUID()
        let previousPhotographer = PhotographerProfile(
            id: photographerID,
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "Previous copyright"
        )
        let updatedPhotographer = PhotographerProfile(
            id: photographerID,
            name: "Jane Doe",
            filenamePrefix: "JAD, JANE",
            creator: "Jane Doe",
            copyrightNotice: "Updated copyright"
        )
        let previousJob = SyncJob(name: "Previous job")
        var unencodableUpdatedJob = previousJob
        unencodableUpdatedJob.name = "Updated job"
        unencodableUpdatedJob.intervalSeconds = .nan

        try fixture.photographerProfileRepository.save([previousPhotographer])
        try fixture.jobRepository.save([previousJob])

        XCTAssertThrowsError(
            try fixture.coordinator.saveJobsAndPhotographers(
                previousJobs: [previousJob],
                previousPhotographers: [previousPhotographer],
                updatedJobs: [unencodableUpdatedJob],
                updatedPhotographers: [updatedPhotographer]
            )
        ) { error in
            guard let encodingError = error as? EncodingError else {
                return XCTFail("Expected the original job encoding error, got \(error)")
            }
            guard case .invalidValue = encodingError else {
                return XCTFail("Expected an invalid-value encoding error, got \(encodingError)")
            }
        }

        XCTAssertEqual(try fixture.photographerProfileRepository.load(), [previousPhotographer])
        XCTAssertEqual(try fixture.jobRepository.load(), [previousJob])
    }
}

private struct PersistenceCoordinatorFixture {
    let root: URL
    let jobsURL: URL
    let presetsURL: URL
    let photographersURL: URL
    let auditsURL: URL
    let failuresURL: URL

    let jobRepository: JobRepository
    let metadataPresetRepository: MetadataPresetRepository
    let photographerProfileRepository: PhotographerProfileRepository
    let metadataAuditRepository: MetadataAuditRepository
    let syncFailureRepository: SyncFailureRepository
    let coordinator: AppPersistenceCoordinator

    @MainActor
    init(prefix: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        jobsURL = root.appendingPathComponent("jobs.json")
        presetsURL = root.appendingPathComponent("presets.json")
        photographersURL = root.appendingPathComponent("photographers.json")
        auditsURL = root.appendingPathComponent("audits.json")
        failuresURL = root.appendingPathComponent("failures.json")

        jobRepository = JobRepository(fileURL: jobsURL)
        metadataPresetRepository = MetadataPresetRepository(fileURL: presetsURL)
        photographerProfileRepository = PhotographerProfileRepository(fileURL: photographersURL)
        metadataAuditRepository = MetadataAuditRepository(fileURL: auditsURL)
        syncFailureRepository = SyncFailureRepository(fileURL: failuresURL)
        coordinator = AppPersistenceCoordinator(
            jobRepository: jobRepository,
            metadataPresetRepository: metadataPresetRepository,
            photographerProfileRepository: photographerProfileRepository,
            metadataAuditRepository: metadataAuditRepository,
            syncFailureRepository: syncFailureRepository,
            keychain: KeychainStore()
        )
    }

    func corruptPrimaryFiles() throws {
        for url in [jobsURL, presetsURL, photographersURL, auditsURL, failuresURL] {
            try Data("not valid JSON".utf8).write(to: url, options: .atomic)
        }
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}
