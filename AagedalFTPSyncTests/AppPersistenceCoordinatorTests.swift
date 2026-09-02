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

    func testPasswordChangeUsesFreshCredentialAndCommitsBeforeRemovingOldPassword() throws {
        let leftCredentialID = "left-old"
        let rightCredentialID = "right-old"
        let keychain = TestKeychain(values: [
            leftCredentialID: "left-password",
            rightCredentialID: "right-password"
        ])
        let fixture = try PersistenceCoordinatorFixture(prefix: "credential-change", keychain: keychain.store)
        defer { fixture.removeTemporaryFiles() }
        let job = remoteJob(leftCredentialID: leftCredentialID, rightCredentialID: rightCredentialID)
        try fixture.jobRepository.save([job])

        var draft = job
        draft.name = "Updated"
        let result = try fixture.coordinator.saveJob(
            previousJobs: [job],
            draftJob: draft,
            leftPassword: "new-left-password",
            rightPassword: "right-password"
        )

        XCTAssertNotEqual(result.savedJob.left.credentialID, leftCredentialID)
        XCTAssertEqual(result.savedJob.right.credentialID, rightCredentialID)
        XCTAssertEqual(keychain.value(for: result.savedJob.left.credentialID), "new-left-password")
        XCTAssertNil(keychain.value(for: leftCredentialID))
        XCTAssertEqual(keychain.value(for: rightCredentialID), "right-password")
        XCTAssertEqual(try fixture.jobRepository.load(), result.jobs)
        XCTAssertTrue(result.cleanupWarnings.isEmpty)
    }

    func testFailedJobCommitRemovesStagedPasswordAndPreservesPreviousCredential() throws {
        let credentialID = "durable-password"
        let keychain = TestKeychain(values: [credentialID: "previous-password"])
        let fixture = try PersistenceCoordinatorFixture(prefix: "credential-commit-failure", keychain: keychain.store)
        defer { fixture.removeTemporaryFiles() }
        var job = remoteJob(leftCredentialID: credentialID)
        job.right = .local
        try fixture.jobRepository.save([job])
        var unencodableDraft = job
        unencodableDraft.intervalSeconds = .nan

        XCTAssertThrowsError(try fixture.coordinator.saveJob(
            previousJobs: [job],
            draftJob: unencodableDraft,
            leftPassword: "replacement-password",
            rightPassword: ""
        ))

        XCTAssertEqual(keychain.valuesSnapshot(), [credentialID: "previous-password"])
        XCTAssertEqual(try fixture.jobRepository.load(), [job])
        XCTAssertEqual(keychain.writeCount, 1)
        XCTAssertEqual(keychain.removedCredentialIDs.count, 1)
        XCTAssertNotEqual(keychain.removedCredentialIDs.first, credentialID)
    }

    func testSecondEndpointPasswordFailureRollsBackFirstStagedPassword() throws {
        let leftCredentialID = "left-existing"
        let rightCredentialID = "right-existing"
        let keychain = TestKeychain(
            values: [leftCredentialID: "left-old", rightCredentialID: "right-old"],
            failWriteNumber: 2
        )
        let fixture = try PersistenceCoordinatorFixture(prefix: "second-password-failure", keychain: keychain.store)
        defer { fixture.removeTemporaryFiles() }
        let job = remoteJob(leftCredentialID: leftCredentialID, rightCredentialID: rightCredentialID)
        try fixture.jobRepository.save([job])

        XCTAssertThrowsError(try fixture.coordinator.saveJob(
            previousJobs: [job],
            draftJob: job,
            leftPassword: "left-new",
            rightPassword: "right-new"
        ))

        XCTAssertEqual(keychain.valuesSnapshot(), [leftCredentialID: "left-old", rightCredentialID: "right-old"])
        XCTAssertEqual(try fixture.jobRepository.load(), [job])
        XCTAssertEqual(keychain.writeCount, 2)
        XCTAssertEqual(keychain.removedCredentialIDs.count, 1)
    }

    func testEmptyPasswordExplicitlyRemovesPreviouslySavedPassword() throws {
        let credentialID = "remove-me"
        let keychain = TestKeychain(values: [credentialID: "saved-password"])
        let fixture = try PersistenceCoordinatorFixture(prefix: "credential-removal", keychain: keychain.store)
        defer { fixture.removeTemporaryFiles() }
        var job = remoteJob(leftCredentialID: credentialID)
        job.right = .local
        try fixture.jobRepository.save([job])

        let result = try fixture.coordinator.saveJob(
            previousJobs: [job],
            draftJob: job,
            leftPassword: "",
            rightPassword: ""
        )

        XCTAssertNotEqual(result.savedJob.left.credentialID, credentialID)
        XCTAssertNil(keychain.value(for: credentialID))
        XCTAssertNil(keychain.value(for: result.savedJob.left.credentialID))
        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertEqual(keychain.removedCredentialIDs, [credentialID])
    }

    func testPasswordReadFailurePreventsAnyCredentialOrJobMutation() throws {
        let credentialID = "unreadable"
        let keychain = TestKeychain(values: [credentialID: "still-saved"], failingReadIDs: [credentialID])
        let fixture = try PersistenceCoordinatorFixture(prefix: "credential-read-failure", keychain: keychain.store)
        defer { fixture.removeTemporaryFiles() }
        var job = remoteJob(leftCredentialID: credentialID)
        job.right = .local
        try fixture.jobRepository.save([job])

        XCTAssertThrowsError(try fixture.coordinator.saveJob(
            previousJobs: [job],
            draftJob: job,
            leftPassword: "replacement",
            rightPassword: ""
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("test Keychain read failure"))
        }

        XCTAssertEqual(keychain.valuesSnapshot(), [credentialID: "still-saved"])
        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertEqual(try fixture.jobRepository.load(), [job])
    }

    func testSavingReferencedEndpointCannotRewriteSharedProfileCredential() throws {
        let profileID = UUID()
        let credentialID = "shared-profile-credential"
        let keychain = TestKeychain(values: [credentialID: "profile-password"])
        let fixture = try PersistenceCoordinatorFixture(prefix: "profile-job-save", keychain: keychain.store)
        defer { fixture.removeTemporaryFiles() }
        var job = remoteJob(leftCredentialID: credentialID)
        job.right = .local
        job.left.serverProfileID = profileID
        try fixture.jobRepository.save([job])

        var draft = job
        draft.left.remotePath = "/incoming/another-desk"
        let result = try fixture.coordinator.saveJob(
            previousJobs: [job],
            draftJob: draft,
            leftPassword: "attempted-job-password-change",
            rightPassword: ""
        )

        XCTAssertEqual(result.savedJob.left.serverProfileID, profileID)
        XCTAssertEqual(result.savedJob.left.remotePath, "/incoming/another-desk")
        XCTAssertEqual(result.savedJob.left.credentialID, credentialID)
        XCTAssertEqual(keychain.valuesSnapshot(), [credentialID: "profile-password"])
        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertTrue(keychain.removedCredentialIDs.isEmpty)
    }

    func testLoadMigratesMatchingLegacyConnectionsToOneProfileWithoutChangingCredentials() throws {
        let credentialID = "legacy-shared-credential"
        let keychain = TestKeychain(values: [credentialID: "existing-password"])
        let fixture = try PersistenceCoordinatorFixture(prefix: "server-profile-migration", keychain: keychain.store)
        defer { fixture.removeTemporaryFiles() }
        var first = remoteJob(leftCredentialID: credentialID)
        first.name = "Picture desk"
        first.left.remotePath = "/incoming/pictures"
        first.right = .local
        var second = first
        second.id = UUID()
        second.name = "Sports desk"
        second.left.remotePath = "/incoming/sports"
        try fixture.jobRepository.save([first, second])

        let result = fixture.coordinator.load()

        let profile = try XCTUnwrap(result.state.serverProfiles.first)
        XCTAssertEqual(result.state.serverProfiles.count, 1)
        XCTAssertEqual(profile.name, "source.example.com")
        XCTAssertEqual(profile.credentialID, credentialID)
        XCTAssertEqual(result.state.jobs.map(\.left.serverProfileID), [profile.id, profile.id])
        XCTAssertEqual(result.state.jobs.map(\.left.remotePath), ["/incoming/pictures", "/incoming/sports"])
        XCTAssertEqual(try fixture.serverProfileRepository.load(), [profile])
        XCTAssertEqual(try fixture.jobRepository.load(), result.state.jobs)
        XCTAssertEqual(try fixture.coordinator.password(for: result.state.jobs[0].left), "existing-password")
        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertTrue(keychain.removedCredentialIDs.isEmpty)
    }

    func testLoadReusesExistingMatchingProfileAndIsIdempotent() throws {
        let fixture = try PersistenceCoordinatorFixture(prefix: "server-profile-reuse")
        defer { fixture.removeTemporaryFiles() }
        let profile = ServerProfile(
            name: "Shared newsroom",
            kind: .sftp,
            host: "source.example.com",
            username: "source",
            credentialID: "existing-profile-credential",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        var job = remoteJob(leftCredentialID: profile.credentialID)
        job.right = .local
        try fixture.serverProfileRepository.save([profile])
        try fixture.jobRepository.save([job])

        let firstLoad = fixture.coordinator.load()
        let secondLoad = fixture.coordinator.load()

        XCTAssertEqual(firstLoad.state.serverProfiles, [profile])
        XCTAssertEqual(firstLoad.state.jobs.first?.left.serverProfileID, profile.id)
        XCTAssertEqual(secondLoad.state.serverProfiles, firstLoad.state.serverProfiles)
        XCTAssertEqual(secondLoad.state.jobs, firstLoad.state.jobs)
    }

    func testLoadKeepsDistinctCredentialsAndIncompleteConnectionsIndependent() throws {
        let fixture = try PersistenceCoordinatorFixture(prefix: "server-profile-distinct")
        defer { fixture.removeTemporaryFiles() }
        var first = remoteJob(leftCredentialID: "first-credential")
        first.left.kind = .ftp
        first.left.port = EndpointKind.ftp.defaultPort
        first.right = .local
        var second = remoteJob(leftCredentialID: "second-credential")
        second.id = UUID()
        second.left.kind = .ftps
        second.left.port = EndpointKind.ftps.defaultPort
        second.right = .local
        var incomplete = remoteJob(leftCredentialID: "incomplete-credential")
        incomplete.id = UUID()
        incomplete.left.hostKeyFingerprint = ""
        incomplete.right = .local
        try fixture.jobRepository.save([first, second, incomplete])

        let result = fixture.coordinator.load()

        XCTAssertEqual(result.state.serverProfiles.count, 2)
        XCTAssertEqual(Set(result.state.serverProfiles.map(\.credentialID)), ["first-credential", "second-credential"])
        XCTAssertEqual(result.state.serverProfiles.map(\.kind), [.ftp, .ftps])
        XCTAssertNotEqual(result.state.jobs[0].left.serverProfileID, result.state.jobs[1].left.serverProfileID)
        XCTAssertNil(result.state.jobs[2].left.serverProfileID)
        XCTAssertEqual(result.state.jobs[2].left.credentialID, "incomplete-credential")
    }

    private func remoteJob(leftCredentialID: String, rightCredentialID: String = "unused-right") -> SyncJob {
        SyncJob(
            name: "Remote job",
            left: Endpoint(
                kind: .sftp,
                host: "source.example.com",
                username: "source",
                credentialID: leftCredentialID,
                hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            ),
            right: Endpoint(
                kind: .ftps,
                host: "target.example.com",
                username: "target",
                credentialID: rightCredentialID
            ),
            direction: .leftToRight,
            isEnabled: false
        )
    }
}

private struct PersistenceCoordinatorFixture {
    let root: URL
    let jobsURL: URL
    let presetsURL: URL
    let photographersURL: URL
    let serverProfilesURL: URL
    let auditsURL: URL
    let failuresURL: URL

    let jobRepository: JobRepository
    let metadataPresetRepository: MetadataPresetRepository
    let photographerProfileRepository: PhotographerProfileRepository
    let serverProfileRepository: ServerProfileRepository
    let metadataAuditRepository: MetadataAuditRepository
    let syncFailureRepository: SyncFailureRepository
    let coordinator: AppPersistenceCoordinator

    @MainActor
    init(prefix: String, keychain: KeychainStore = KeychainStore()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        jobsURL = root.appendingPathComponent("jobs.json")
        presetsURL = root.appendingPathComponent("presets.json")
        photographersURL = root.appendingPathComponent("photographers.json")
        serverProfilesURL = root.appendingPathComponent("server-profiles.json")
        auditsURL = root.appendingPathComponent("audits.json")
        failuresURL = root.appendingPathComponent("failures.json")

        jobRepository = JobRepository(fileURL: jobsURL)
        metadataPresetRepository = MetadataPresetRepository(fileURL: presetsURL)
        photographerProfileRepository = PhotographerProfileRepository(fileURL: photographersURL)
        serverProfileRepository = ServerProfileRepository(fileURL: serverProfilesURL)
        metadataAuditRepository = MetadataAuditRepository(fileURL: auditsURL)
        syncFailureRepository = SyncFailureRepository(fileURL: failuresURL)
        coordinator = AppPersistenceCoordinator(
            jobRepository: jobRepository,
            metadataPresetRepository: metadataPresetRepository,
            photographerProfileRepository: photographerProfileRepository,
            serverProfileRepository: serverProfileRepository,
            metadataAuditRepository: metadataAuditRepository,
            syncFailureRepository: syncFailureRepository,
            keychain: keychain
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

private enum TestKeychainFailure: LocalizedError {
    case read
    case write

    var errorDescription: String? {
        switch self {
        case .read: "A test Keychain read failure occurred."
        case .write: "A test Keychain write failure occurred."
        }
    }
}

private final class TestKeychain: @unchecked Sendable {
    private var values: [String: String]
    private let failingReadIDs: Set<String>
    private let failWriteNumber: Int?
    private(set) var writeCount = 0
    private(set) var removedCredentialIDs: [String] = []

    init(
        values: [String: String] = [:],
        failingReadIDs: Set<String> = [],
        failWriteNumber: Int? = nil
    ) {
        self.values = values
        self.failingReadIDs = failingReadIDs
        self.failWriteNumber = failWriteNumber
    }

    var store: KeychainStore {
        KeychainStore(
            passwordReader: { [self] credentialID in
                if failingReadIDs.contains(credentialID) { throw TestKeychainFailure.read }
                return values[credentialID]
            },
            passwordWriter: { [self] password, credentialID in
                writeCount += 1
                if writeCount == failWriteNumber { throw TestKeychainFailure.write }
                values[credentialID] = password
            },
            passwordRemover: { [self] credentialID in
                removedCredentialIDs.append(credentialID)
                values[credentialID] = nil
            }
        )
    }

    func value(for credentialID: String) -> String? {
        values[credentialID]
    }

    func valuesSnapshot() -> [String: String] {
        values
    }
}
