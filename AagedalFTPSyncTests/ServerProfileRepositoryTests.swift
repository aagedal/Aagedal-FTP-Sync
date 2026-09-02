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
