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
        try serverRepository.save([profile])

        let store = AppStore(
            repository: JobRepository(fileURL: root.appendingPathComponent("jobs.json")),
            serverProfileRepository: serverRepository
        )

        XCTAssertEqual(store.serverProfiles, [profile])
        XCTAssertTrue(store.jobs.isEmpty)
    }
}
