import Crypto
@testable import Citadel
import NIO
import NIOSSH
import XCTest

final class SFTPRequestDeadlineTests: XCTestCase {
    func testUnresponsiveServerRequestTimesOutAndClosesSFTPChannel() async throws {
        let fixture = try await HungSFTPFixture(port: 23_231)
        defer { fixture.probe.release() }

        let sftp = try await fixture.client.openSFTP(requestTimeout: .milliseconds(100))
        let request = Task { try await sftp.getAttributes(at: "/unresponsive") }
        await fixture.probe.waitUntilRequestStarts()

        do {
            _ = try await request.value
            XCTFail("Expected the unanswered SFTP request to time out")
        } catch SFTPError.requestTimedOut {
            // Expected.
        } catch {
            XCTFail("Expected requestTimedOut, received \(error)")
        }

        XCTAssertFalse(sftp.isActive)
        fixture.probe.release()
        try await fixture.close()
    }

    func testCancellingUnresponsiveRequestClosesSFTPChannel() async throws {
        let fixture = try await HungSFTPFixture(port: 23_232)
        defer { fixture.probe.release() }

        let sftp = try await fixture.client.openSFTP(requestTimeout: .seconds(30))
        let request = Task { try await sftp.getAttributes(at: "/unresponsive") }
        await fixture.probe.waitUntilRequestStarts()
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected the cancelled SFTP request to fail")
        } catch {
            // Closing the channel releases the pending protocol request.
        }

        XCTAssertFalse(sftp.isActive)
        fixture.probe.release()
        try await fixture.close()
    }
}

private final class HungSFTPFixture: @unchecked Sendable {
    let probe = HungSFTPProbe()
    let server: SSHServer
    let client: SSHClient

    init(port: Int) async throws {
        let password = UUID().uuidString
        let hostKey = NIOSSHPrivateKey(p521Key: .init())
        server = try await SSHServer.host(
            host: "127.0.0.1",
            port: port,
            hostKeys: [hostKey],
            authenticationDelegate: PasswordAuthenticationDelegate(password: password)
        )
        server.enableSFTP(withDelegate: HungSFTPDelegate(probe: probe))
        client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: port,
            authenticationMethod: .passwordBased(username: "deadline-test", password: password),
            hostKeyValidator: .trustedKeys([hostKey.publicKey]),
            reconnect: .never
        )
    }

    func close() async throws {
        try? await client.close()
        try await server.close()
    }
}

private struct PasswordAuthenticationDelegate: NIOSSHServerUserAuthenticationDelegate {
    let password: String

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard case .password(let request) = request.request, request.password == password else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

private actor HungSFTPProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilRequestStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func blockRequest() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    nonisolated func release() {
        Task { await resumeRequest() }
    }

    private func resumeRequest() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum HungSFTPError: Error {
    case unsupported
}

private struct HungSFTPDelegate: SFTPDelegate {
    let probe: HungSFTPProbe

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        await probe.blockRequest()
        return .none
    }

    func openFile(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        flags: SFTPOpenFileFlags,
        context: SSHContext
    ) async throws -> SFTPFileHandle {
        throw HungSFTPError.unsupported
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        throw HungSFTPError.unsupported
    }

    func createDirectory(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        throw HungSFTPError.unsupported
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        throw HungSFTPError.unsupported
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        throw HungSFTPError.unsupported
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        throw HungSFTPError.unsupported
    }

    func setFileAttributes(
        to attributes: SFTPFileAttributes,
        atPath path: String,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        throw HungSFTPError.unsupported
    }

    func addSymlink(
        linkPath: String,
        targetPath: String,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        throw HungSFTPError.unsupported
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        throw HungSFTPError.unsupported
    }

    func rename(
        oldPath: String,
        newPath: String,
        flags: UInt32,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        throw HungSFTPError.unsupported
    }
}
