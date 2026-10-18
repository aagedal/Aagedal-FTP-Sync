import Foundation
import XCTest
@testable import AagedalFTPSync

final class ServerProfileRepositoryTests: XCTestCase {
    func testMissingLibraryLoadsAsEmpty() throws {
        let repository = ServerProfileRepository(fileURL: temporaryFileURL())

        let result = try repository.loadResult()

        XCTAssertEqual(result.profiles, [])
        XCTAssertFalse(result.recoveredFromBackup)
    }

    func testRoundTripsNamedFTPFTPSAndSFTPProfiles() throws {
        let fileURL = temporaryFileURL()
        defer { removeRepositoryFiles(at: fileURL) }
        let repository = ServerProfileRepository(fileURL: fileURL)
        let profiles = [
            ServerProfile(name: "Legacy wire", kind: .ftp, host: "ftp.example.test", username: "ftp-user"),
            ServerProfile(name: "Picture desk", kind: .ftps, host: "ftps.example.test", username: "tls-user"),
            ServerProfile(
                name: "News SFTP",
                kind: .sftp,
                host: "sftp.example.test",
                username: "ssh-user",
                hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            ),
        ]

        try repository.save(profiles)

        XCTAssertEqual(try repository.load(), profiles)
    }

    func testRejectsLocalDuplicateIDAndDuplicateNamedProfiles() throws {
        let repository = ServerProfileRepository(fileURL: temporaryFileURL())
        XCTAssertThrowsError(try repository.save([
            ServerProfile(name: "Not remote", kind: .local, host: "localhost", username: "user"),
        ])) { error in
            XCTAssertEqual(
                error as? ServerProfileRepositoryError,
                .invalidProfile("Server profiles support FTP, FTPS, and SFTP connections.")
            )
        }

        let first = ServerProfile(name: "Picture Desk", host: "one.example.test", username: "one")
        var duplicateID = ServerProfile(name: "Another desk", host: "two.example.test", username: "two")
        duplicateID.id = first.id
        XCTAssertThrowsError(try repository.save([first, duplicateID])) { error in
            XCTAssertEqual(error as? ServerProfileRepositoryError, .duplicateID)
        }

        let second = ServerProfile(name: "picture desk", host: "two.example.test", username: "two")
        XCTAssertThrowsError(try repository.save([first, second])) { error in
            XCTAssertEqual(error as? ServerProfileRepositoryError, .duplicateName("picture desk"))
        }
    }

    func testRecoversFromBackupWhenPrimaryFileIsInvalid() throws {
        let fileURL = temporaryFileURL()
        defer { removeRepositoryFiles(at: fileURL) }
        let repository = ServerProfileRepository(fileURL: fileURL)
        let recoverable = ServerProfile(
            name: "Picture desk",
            kind: .ftps,
            host: "photos.example.test",
            username: "desk"
        )

        try repository.save([recoverable])
        try repository.save([])
        try Data("not valid JSON".utf8).write(to: fileURL, options: .atomic)

        let result = try repository.loadResult()

        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.profiles, [recoverable])
    }

    func testProfileCreatesEndpointWithoutOwningRemotePath() {
        let profile = ServerProfile(
            name: "News SFTP",
            kind: .sftp,
            host: "sftp.example.test",
            port: 2222,
            username: "desk",
            credentialID: "shared-credential",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )

        let endpoint = profile.endpoint(remotePath: "/incoming/desk-a")

        XCTAssertEqual(endpoint.kind, .sftp)
        XCTAssertEqual(endpoint.host, "sftp.example.test")
        XCTAssertEqual(endpoint.port, 2222)
        XCTAssertEqual(endpoint.username, "desk")
        XCTAssertEqual(endpoint.credentialID, "shared-credential")
        XCTAssertEqual(endpoint.remotePath, "/incoming/desk-a")
        XCTAssertEqual(endpoint.serverProfileID, profile.id)
    }

    func testIndependentCopyUsesFreshIdentitiesAndCollisionSafeName() {
        let profile = ServerProfile(
            name: "Picture Desk",
            kind: .sftp,
            host: "sftp.example.test",
            port: 2222,
            username: "desk",
            credentialID: "shared-credential",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        let firstCopy = ServerProfile(name: "picture desk copy", host: "copy.example.test", username: "copy")

        let duplicate = profile.independentCopy(existingProfiles: [profile, firstCopy])

        XCTAssertEqual(duplicate.name, "Picture Desk Copy 2")
        XCTAssertNotEqual(duplicate.id, profile.id)
        XCTAssertNotEqual(duplicate.credentialID, profile.credentialID)
        XCTAssertEqual(duplicate.kind, profile.kind)
        XCTAssertEqual(duplicate.host, profile.host)
        XCTAssertEqual(duplicate.port, profile.port)
        XCTAssertEqual(duplicate.username, profile.username)
        XCTAssertEqual(duplicate.hostKeyFingerprint, profile.hostKeyFingerprint)
    }

    func testJobsResolveSharedConnectionSettingsWhileKeepingIndependentPaths() throws {
        let profile = ServerProfile(
            name: "News SFTP",
            kind: .sftp,
            host: "sftp.example.test",
            port: 2222,
            username: "desk",
            credentialID: "shared-credential",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        var first = SyncJob(name: "Desk A", left: profile.endpoint(remotePath: "/incoming/a"))
        var second = SyncJob(name: "Desk B", left: profile.endpoint(remotePath: "/incoming/b"))
        first.left.host = "stale.example.test"
        second.left.username = "stale-user"

        first = try first.resolvingServerProfiles(in: [profile])
        second = try second.resolvingServerProfiles(in: [profile])

        XCTAssertEqual(first.left.remotePath, "/incoming/a")
        XCTAssertEqual(second.left.remotePath, "/incoming/b")
        XCTAssertEqual(first.left.host, profile.host)
        XCTAssertEqual(second.left.username, profile.username)
        XCTAssertEqual(first.left.credentialID, profile.credentialID)
        XCTAssertEqual(second.left.credentialID, profile.credentialID)
    }

    func testMissingProfileReferenceFailsResolution() {
        let missingID = UUID()
        let endpoint = Endpoint(
            kind: .ftps,
            serverProfileID: missingID,
            remotePath: "/incoming"
        )

        XCTAssertThrowsError(try endpoint.resolvingServerProfile(in: [])) { error in
            XCTAssertEqual(error as? ServerProfileResolutionError, .missingProfile(missingID))
        }
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("server-profiles-\(UUID().uuidString).json")
    }

    private func removeRepositoryFiles(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("backup"))
    }
}

@MainActor
final class ServerProfileAppStoreTests: XCTestCase {
    private final class Credentials: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "saved password"
        private var failReads = false
        func read() throws -> String {
            try lock.withLock {
                if failReads { throw AppError.transferFailed("Keychain unavailable") }
                return value
            }
        }
        func write(_ password: String) { lock.withLock { value = password } }
        func fail(_ enabled: Bool) { lock.withLock { failReads = enabled } }
    }

    private func editingStore(missingCredentialIDs: Set<String> = []) throws -> (AppStore, Credentials, ServerProfile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("server-editing-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root)
        let profile = ServerProfile(name: "Desk", host: "photos.example.test", username: "desk")
        let profiles = ServerProfileRepository(storage: storage)
        try profiles.save([profile])
        let credentials = Credentials()
        let store = AppStore(repository: JobRepository(storage: storage),
            metadataPresetRepository: MetadataPresetRepository(storage: storage),
            photographerProfileRepository: PhotographerProfileRepository(storage: storage),
            serverProfileRepository: profiles, metadataAuditRepository: MetadataAuditRepository(storage: storage),
            syncFailureRepository: SyncFailureRepository(storage: storage),
            sourceSignatureRepository: SourceSignatureRepository(storage: storage),
            downloadManifestRepository: DownloadManifestRepository(storage: storage),
            keychain: KeychainStore(passwordReader: { id in missingCredentialIDs.contains(id) ? nil : try credentials.read() },
                passwordWriter: { value, _ in credentials.write(value) }, passwordRemover: { _ in }),
            startsJobsOnInitialization: false)
        return (store, credentials, profile)
    }

    func testServerEditingRetainsDraftUntilSuccessfulSaveOrExplicitRevert() throws {
        let (store, _, profile) = try editingStore()
        let session = ServerProfileEditingSession()
        session.edit(profile, using: store)
        XCTAssertFalse(session.hasUnsavedChanges)
        session.draft?.name = "Edited desk"
        session.password = "replacement"
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(store.serverProfiles.first?.name, "Desk")
        XCTAssertTrue(session.save(using: store))
        XCTAssertEqual(store.serverProfiles.first?.name, "Edited desk")
        XCTAssertFalse(session.hasUnsavedChanges)
        session.beginNew(ServerProfile(name: "New draft"))
        XCTAssertTrue(session.isNewProfile)
        XCTAssertFalse(session.save(using: store))
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(store.serverProfiles.count, 1)
        session.edit(store.serverProfiles.first, using: store)
        XCTAssertFalse(session.isNewProfile)
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testOpenJobRefreshesSharedConnectionAndPasswordWithoutCreatingEdits() throws {
        let (store, _, profile) = try editingStore()
        var job = SyncJob(name: "Live shared server")
        job.left = profile.endpoint(remotePath: "/job/incoming")
        job.right = Endpoint(kind: .local, localPath: "/destination", bookmark: Data([1]))
        XCTAssertTrue(store.saveJob(job, leftPassword: "", rightPassword: ""))
        let session = JobEditingSession()
        session.edit(try XCTUnwrap(store.jobs.first))
        session.loadCredentials(using: store)
        XCTAssertFalse(session.hasUnsavedChanges)

        var changed = profile
        changed.kind = .ftp
        changed.host = "new.example.test"
        changed.port = 2121
        changed.username = "new-user"
        XCTAssertTrue(store.saveServerProfile(changed, password: "new shared password"))
        session.refreshServerProfiles(using: store)

        let current = try XCTUnwrap(store.serverProfiles.first)
        XCTAssertEqual(session.draft.left, current.endpoint(remotePath: "/job/incoming"))
        XCTAssertEqual(session.leftPassword, "new shared password")
        XCTAssertNil(session.credentialLoadError)
        XCTAssertFalse(session.hasUnsavedChanges)
        session.markDiscarded()
        XCTAssertEqual(session.draft.left, current.endpoint(remotePath: "/job/incoming"))
    }

    func testSharedConnectionRefreshPreservesUnsavedPathsNameAndCustomPassword() throws {
        let (store, _, profile) = try editingStore()
        var job = SyncJob(name: "Saved name")
        job.left = profile.endpoint(remotePath: "/saved")
        job.right = Endpoint(kind: .ftp, host: "custom.example.test", username: "custom")
        let session = JobEditingSession()
        // A transient draft can have two remote endpoints while choosing which
        // side is local. It must retain edits but is not a persistable job.
        session.edit(job)
        session.loadCredentials(using: store)
        session.draft.name = "Local name edit"
        session.draft.left.remotePath = "/local/folder/edit"
        session.rightPassword = "typed custom replacement"

        var changed = profile
        changed.port = 2990
        XCTAssertTrue(store.saveServerProfile(changed, password: "rotated shared password"))
        session.refreshServerProfiles(using: store)
        XCTAssertEqual(session.draft.name, "Local name edit")
        XCTAssertEqual(session.draft.left.remotePath, "/local/folder/edit")
        XCTAssertEqual(session.draft.left.port, 2990)
        XCTAssertEqual(session.leftPassword, "rotated shared password")
        XCTAssertEqual(session.rightPassword, "typed custom replacement")
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    func testSharedConnectionReloadFailureBlocksSaveAndRetryPreservesDraft() throws {
        let (store, credentials, profile) = try editingStore()
        var job = SyncJob(name: "Keep these edits")
        var stale = profile
        stale.port = 1111
        stale.credentialID = "obsolete-credential"
        job.left = stale.endpoint(remotePath: "/incoming")
        job.right = Endpoint(kind: .local, localPath: "/destination", bookmark: Data([1]))
        let session = JobEditingSession()
        session.edit(job)
        session.draft.right.localPath = "/keep/local/edit"
        credentials.fail(true)
        session.refreshServerProfiles(using: store)
        XCTAssertEqual(session.draft.left, profile.endpoint(remotePath: "/incoming"))
        XCTAssertNotNil(session.credentialLoadError)
        XCTAssertFalse(session.save(using: store))
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(session.draft.right.localPath, "/keep/local/edit")

        credentials.fail(false)
        session.loadCredentials(using: store)
        XCTAssertNil(session.credentialLoadError)
        XCTAssertEqual(session.leftPassword, "saved password")
        XCTAssertEqual(session.draft.right.localPath, "/keep/local/edit")
        XCTAssertEqual(session.draft.name, "Keep these edits")
        XCTAssertTrue(session.save(using: store))
    }

    func testSavingBeforeProfileObserverRunsUsesCurrentSharedConnection() throws {
        let (store, _, profile) = try editingStore()
        var job = SyncJob(name: "Saved job")
        job.left = profile.endpoint(remotePath: "/incoming")
        job.right = Endpoint(kind: .local, localPath: "/destination", bookmark: Data([1]))
        XCTAssertTrue(store.saveJob(job, leftPassword: "", rightPassword: ""))
        let session = JobEditingSession()
        session.edit(try XCTUnwrap(store.jobs.first))
        session.loadCredentials(using: store)
        session.draft.name = "Local name edit"
        var changed = profile
        changed.port = 2990
        XCTAssertTrue(store.saveServerProfile(changed, password: "rotated password"))
        XCTAssertTrue(session.save(using: store), store.alertMessage ?? "")
        XCTAssertEqual(store.jobs.first?.left.port, 2990)
        XCTAssertEqual(store.jobs.first?.name, "Local name edit")
        XCTAssertEqual(session.leftPassword, "rotated password")
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testDiscardAfterLocallyChoosingProfileRestoresOriginalCustomPassword() throws {
        let (store, _, profile) = try editingStore()
        var job = SyncJob(name: "Custom connection")
        job.left = Endpoint(kind: .ftp, host: "custom.example.test", username: "custom")
        job.right = Endpoint(kind: .local, localPath: "/destination", bookmark: Data([1]))
        XCTAssertTrue(store.saveJob(job, leftPassword: "original custom password", rightPassword: ""))
        let original = try XCTUnwrap(store.jobs.first)
        let session = JobEditingSession()
        session.edit(original)
        session.loadCredentials(using: store)
        session.draft.left = profile.endpoint(remotePath: "/selected")
        session.leftPassword = try store.password(for: profile)
        var changed = profile
        changed.port = 2990
        XCTAssertTrue(store.saveServerProfile(changed, password: "new profile password"))
        session.refreshServerProfiles(using: store)
        XCTAssertEqual(session.leftPassword, "new profile password")
        session.markDiscarded()
        XCTAssertEqual(session.draft.left, original.left)
        XCTAssertEqual(session.leftPassword, "original custom password")
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertTrue(session.save(using: store))
        XCTAssertEqual(try store.password(for: try XCTUnwrap(store.jobs.first).left), "original custom password")
    }

    func testConnectionTestUsesCurrentProfileAndRejectsStaleCompletion() throws {
        let (store, _, profile) = try editingStore()
        let stale = profile.endpoint(remotePath: "/job/folder")
        let first = try EndpointConnectionTestInput(endpoint: stale, password: "obsolete", profiles: store.serverProfiles,
            loadPassword: { try store.password(for: $0) })
        XCTAssertEqual(first.password, "saved password")
        var changed = profile
        changed.host = "replacement.example.test"
        changed.port = 2121
        XCTAssertTrue(store.saveServerProfile(changed, password: "replacement password"))
        XCTAssertFalse(first.isCurrent(endpoint: stale, password: "obsolete", profiles: store.serverProfiles))
        let next = try EndpointConnectionTestInput(endpoint: stale, password: "obsolete", profiles: store.serverProfiles,
            loadPassword: { try store.password(for: $0) })
        XCTAssertEqual(next.endpoint.host, "replacement.example.test")
        XCTAssertEqual(next.endpoint.port, 2121)
        XCTAssertEqual(next.endpoint.remotePath, "/job/folder")
        XCTAssertEqual(next.password, "replacement password")
        XCTAssertTrue(next.isCurrent(endpoint: stale, password: "obsolete", profiles: store.serverProfiles))
        XCTAssertTrue(store.saveServerProfile(try XCTUnwrap(store.serverProfiles.first), password: "password-only rotation"))
        XCTAssertFalse(next.isCurrent(endpoint: stale, password: "obsolete", profiles: store.serverProfiles))
        XCTAssertThrowsError(try EndpointConnectionTestInput(endpoint: stale, password: "obsolete", profiles: [],
            loadPassword: { _ in XCTFail("Missing profile must fail before loading a password"); return "" }))
        XCTAssertFalse(next.isCurrent(endpoint: stale, password: "obsolete", profiles: []))
        XCTAssertThrowsError(try EndpointConnectionTestInput(endpoint: stale, password: "obsolete", profiles: store.serverProfiles,
            loadPassword: { _ in throw AppError.transferFailed("Keychain unavailable") }))
    }

    func testDetachingProfilePreservesTypedOriginalPasswordDuringBaselineRefresh() throws {
        let (store, _, profile) = try editingStore(missingCredentialIDs: ["unsaved-custom"])
        var job = SyncJob(name: "Detach shared server")
        job.left = profile.endpoint(remotePath: "/incoming")
        job.right = Endpoint(kind: .local, localPath: "/destination", bookmark: Data([1]))
        XCTAssertTrue(store.saveJob(job, leftPassword: "", rightPassword: ""))
        let session = JobEditingSession()
        session.edit(try XCTUnwrap(store.jobs.first))
        session.loadCredentials(using: store)
        session.draft.left.serverProfileID = nil
        session.draft.left.credentialID = "unsaved-custom"
        // The user deliberately reuses the old profile password for this new
        // custom connection; equal text does not mean the field is untouched.
        session.leftPassword = "saved password"
        var changed = profile
        changed.port = 2990
        XCTAssertTrue(store.saveServerProfile(changed, password: "saved password"))
        session.refreshServerProfiles(using: store)
        XCTAssertNil(session.draft.left.serverProfileID)
        XCTAssertEqual(session.draft.left.port, profile.port)
        XCTAssertEqual(session.leftPassword, "saved password")
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(session.save(using: store), store.alertMessage ?? "")
        XCTAssertEqual(try store.password(for: try XCTUnwrap(store.jobs.first).left), "saved password")
    }

    func testConnectionTestTracksTypedCustomPasswordWithoutReadingSavedCredentials() throws {
        let endpoint = Endpoint(kind: .ftp, host: "custom.example.test", username: "custom")
        let input = try EndpointConnectionTestInput(endpoint: endpoint, password: "typed password", profiles: [],
            loadPassword: { _ in XCTFail("A custom test must use its draft password"); return "" })
        XCTAssertEqual(input.password, "typed password")
        XCTAssertTrue(input.isCurrent(endpoint: endpoint, password: "typed password", profiles: []))
        XCTAssertFalse(input.isCurrent(endpoint: endpoint, password: "changed password", profiles: []))
        var changed = endpoint
        changed.remotePath = "/other"
        XCTAssertFalse(input.isCurrent(endpoint: changed, password: "typed password", profiles: []))
    }

    func testStaleServerDraftCannotOverwriteChangedOrDeletedProfile() throws {
        let (store, _, profile) = try editingStore()
        let session = ServerProfileEditingSession()
        session.edit(profile, using: store)
        session.draft?.name = "Keep this draft"
        var latest = profile
        latest.host = "changed.example.test"
        XCTAssertTrue(store.saveServerProfile(latest, password: "saved password"))
        XCTAssertFalse(session.save(using: store))
        XCTAssertEqual(store.serverProfiles.first, latest)
        XCTAssertEqual(session.draft?.name, "Keep this draft")
        XCTAssertTrue(store.removeServerProfile(profile.id))
        XCTAssertFalse(session.save(using: store))
        XCTAssertTrue(store.serverProfiles.isEmpty)
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    func testPasswordOnlyChangeInAnotherWindowCannotBeOverwrittenByStaleDraft() throws {
        let (store, credentials, profile) = try editingStore()
        let first = ServerProfileEditingSession()
        let second = ServerProfileEditingSession()
        first.edit(profile, using: store)
        second.edit(profile, using: store)
        first.password = "new password"
        XCTAssertTrue(first.save(using: store))
        XCTAssertNotEqual(store.serverProfiles.first?.credentialID, profile.credentialID)
        second.draft?.name = "Other window edit"
        XCTAssertFalse(second.save(using: store))
        XCTAssertEqual(try credentials.read(), "new password")
        XCTAssertEqual(second.draft?.name, "Other window edit")
        XCTAssertEqual(store.serverProfiles.first?.name, "Desk")
    }

    func testCredentialFailureAndRetryPreserveServerDraftAndTypedPassword() throws {
        let (store, credentials, profile) = try editingStore()
        let session = ServerProfileEditingSession()
        credentials.fail(true)
        session.edit(profile, using: store)
        XCTAssertNotNil(session.credentialLoadError)
        session.draft?.name = "Keep my edit"
        session.password = "typed replacement"
        XCTAssertFalse(session.save(using: store))
        credentials.fail(false)
        session.retryCredentials(using: store)
        XCTAssertNil(session.credentialLoadError)
        XCTAssertEqual(session.password, "typed replacement")
        XCTAssertTrue(session.save(using: store))
        XCTAssertEqual(store.serverProfiles.first?.name, "Keep my edit")
        XCTAssertEqual(try credentials.read(), "typed replacement")
    }

    func testStoreLoadsProfilesFromDedicatedRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-profile-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let serverRepository = ServerProfileRepository(fileURL: root.appendingPathComponent("servers.json"))
        let profile = ServerProfile(
            name: "Picture desk",
            kind: .ftps,
            host: "photos.example.test",
            username: "desk"
        )
        let jobRepository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        var referencedEndpoint = profile.endpoint(remotePath: "/incoming/picture-desk")
        referencedEndpoint.host = "stale.example.test"
        let job = SyncJob(
            name: "Profile job",
            left: referencedEndpoint,
            isEnabled: false,
            startOnAppLaunch: false
        )
        try serverRepository.save([profile])
        try jobRepository.save([job])

        let store = AppStore(
            repository: jobRepository,
            serverProfileRepository: serverRepository
        )

        XCTAssertEqual(store.serverProfiles, [profile])
        XCTAssertEqual(store.jobs.first?.left.serverProfileID, profile.id)
        XCTAssertEqual(store.jobs.first?.left.remotePath, "/incoming/picture-desk")
        XCTAssertEqual(store.jobs.first?.left.host, "photos.example.test")
        XCTAssertEqual(
            store.serverProfileUsages(for: profile.id),
            [
                ServerProfileUsage(
                    jobID: job.id,
                    jobName: job.name,
                    usesLocationA: true,
                    usesLocationB: false
                )
            ]
        )
        XCTAssertFalse(store.removeServerProfile(profile.id))
        XCTAssertEqual(store.serverProfiles, [profile])
        XCTAssertTrue(store.alertMessage?.contains(job.name) == true)
    }
}
