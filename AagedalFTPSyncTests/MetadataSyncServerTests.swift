import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataSyncServerTests: XCTestCase {
    func testAddressesAcceptIndependentDomainsAndDeploymentPaths() throws {
        for (input, expected) in [
            (" sync.example.org ", "https://sync.example.org/index.php"),
            ("https://EXAMPLE.NET/team/sync", "https://example.net/team/sync/index.php"),
            ("https://example.net/team/sync/", "https://example.net/team/sync/index.php"),
            ("https://example.net/team/sync/index.php", "https://example.net/team/sync/index.php"),
            ("https://example.net:8443/", "https://example.net:8443/index.php")
        ] {
            let server = try MetadataSyncServer(address: input)
            XCTAssertEqual(server.endpointURL.absoluteString, expected)
            XCTAssertEqual(try MetadataSyncServer(address: server.baseURL.absoluteString), server)
        }
    }

    func testAddressesRejectInsecureURLsAndEmbeddedSecrets() {
        for address in ["", "  ", "http://example.org", "ftp://example.org", "https://",
                        "https://user:password@example.org/", "https://user@example.org/",
                        "https://example.org/?token=secret", "https://example.org/#secret",
                        "https://example.org:0", "https://example.org:65536", "https://bad host/"] {
            XCTAssertThrowsError(try MetadataSyncServer(address: address), address)
        }
    }

    func testDiscoveryChecksProtocolInsteadOfAcceptingArbitraryJSON() throws {
        let valid = Data(#"{"service":"aagedal-metadata-sync","protocolVersion":1,"stage":"hosting-check","checks":[{"name":"PHP runtime","passed":true}]}"#.utf8)
        XCTAssertEqual(try MetadataSyncServerInfo.decode(valid).checks.count, 1)
        for text in [
            "<html>Default hosting page</html>",
            #"{"service":"unrelated","protocolVersion":1,"stage":"hosting-check","checks":[]}"#,
            #"{"service":"aagedal-metadata-sync","protocolVersion":2,"stage":"hosting-check","checks":[]}"#,
            #"{"service":"aagedal-metadata-sync","protocolVersion":1,"stage":"production","checks":[]}"#
        ] {
            XCTAssertThrowsError(try MetadataSyncServerInfo.decode(Data(text.utf8)))
        }
        XCTAssertThrowsError(try MetadataSyncServerInfo.decode(Data(repeating: 32, count: 65_537)))
    }

    func testRedirectDelegateNeverForwardsSetupCredential() async {
        let url = URL(string: "https://example.org/index.php")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let request = URLRequest(url: URL(string: "https://other.example/index.php")!)
        let followed: URLRequest? = await withCheckedContinuation { continuation in
            MetadataSyncNoRedirectDelegate().urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: request
            ) { request in continuation.resume(returning: request) }
        }
        XCTAssertNil(followed)
    }

    func testInvalidSetupKeyFailsBeforeNetworkAccess() async throws {
        let server = try MetadataSyncServer(address: "https://example.invalid")
        do {
            _ = try await MetadataSyncServerClient().check(server: server, setupKey: "short\r\nkey")
            XCTFail("Expected invalid setup key")
        } catch {
            XCTAssertEqual(error as? MetadataSyncServerError, .invalidSetupKey)
        }
    }
}
