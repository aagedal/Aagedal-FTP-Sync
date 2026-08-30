import Foundation
import XCTest
@testable import AagedalFTPSync

final class SSHHostKeyFingerprintTests: XCTestCase {
    func testCreatesStandardSHA256FingerprintFromOpenSSHKeyBlob() {
        let fingerprint = SSHHostKeyFingerprint.make(fromOpenSSHKey: "ssh-ed25519 YWJj comment")

        XCTAssertEqual(fingerprint, "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }

    func testNormalizesFingerprintPrefixAndPadding() {
        let fingerprint = "sha256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="

        XCTAssertEqual(
            SSHHostKeyFingerprint.normalized(fingerprint),
            "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"
        )
    }

    func testRejectsMalformedOrWrongLengthFingerprints() {
        XCTAssertNil(SSHHostKeyFingerprint.normalized("MD5:aa:bb"))
        XCTAssertNil(SSHHostKeyFingerprint.normalized("SHA256:not-base64"))
        XCTAssertNil(SSHHostKeyFingerprint.normalized("SHA256:YWJj"))
    }

    func testSFTPRequiresFingerprintForSavingButNotDiscovery() {
        let endpoint = Endpoint(kind: .sftp, host: "photos.example.com", username: "desk")

        XCTAssertNil(endpoint.connectionValidationMessage)
        XCTAssertEqual(endpoint.validationMessage, "Verify and trust the server's SSH host-key fingerprint.")
    }

    func testConnectionTesterReachesHostKeyDiscoveryWithoutSavedFingerprint() async {
        let endpoint = Endpoint(kind: .sftp, host: "photos.example.com", username: "desk")

        do {
            try await EndpointConnectionTester.test(
                endpoint: endpoint,
                password: "secret",
                sessionFactory: { _, _ in UntrustedHostSession() }
            )
            XCTFail("Host-key discovery should report the untrusted fingerprint")
        } catch let AppError.untrustedSSHHostKey(hostID, fingerprint) {
            XCTAssertEqual(hostID, "photos.example.com:22")
            XCTAssertEqual(fingerprint, "SHA256:test-fingerprint")
        } catch {
            XCTFail("Unexpected discovery error: \(error)")
        }
    }
}

private struct UntrustedHostSession: EndpointSession {
    func testConnection() async throws {
        throw AppError.untrustedSSHHostKey(
            hostID: "photos.example.com:22",
            fingerprint: "SHA256:test-fingerprint"
        )
    }

    func listFiles() async throws -> [String: SyncFile] { [:] }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {}

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {}
}
