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
}
