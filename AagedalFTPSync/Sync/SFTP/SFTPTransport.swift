import Citadel
import Foundation
import NIOCore
import NIOSSH

actor SFTPTransport {
    private let endpoint: Endpoint
    private let password: String
    private var sshClient: SSHClientBox?
    private var sftpClient: SFTPClient?

    init(endpoint: Endpoint, password: String) {
        self.endpoint = endpoint
        self.password = password
    }

    func testConnection() async throws {
        let sftp = try await connect()
        _ = try await sftp.listDirectory(atPath: normalizedRoot)
    }

    func listFiles() async throws -> [String: SyncFile] {
        let sftp = try await connect()
        var result: [String: SyncFile] = [:]
        var directories: [(remote: String, relative: String)] = [(normalizedRoot, "")]
        while !directories.isEmpty {
            try Task.checkCancellation()
            let directory = directories.removeFirst()
            let responses = try await sftp.listDirectory(atPath: directory.remote)
            for entry in responses.flatMap(\.components) {
                guard PathSafety.isSafeServerName(entry.filename) else { continue }
                let relative = directory.relative.isEmpty ? entry.filename : "\(directory.relative)/\(entry.filename)"
                let remote = join(directory.remote, entry.filename)
                let mode = entry.attributes.permissions ?? 0
                let kind = mode & 0o170000
                if kind == 0o040000 {
                    directories.append((remote, relative))
                } else if kind != 0o120000 {
                    result[relative] = SyncFile(
                        relativePath: relative,
                        size: Int64(entry.attributes.size ?? 0),
                        modifiedAt: entry.attributes.accessModificationTime?.modificationTime ?? .distantPast
                    )
                }
            }
        }
        return result
    }

    func download(file: SyncFile, to temporaryURL: URL) async throws {
        let sftp = try await connect()
        _ = FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }
        try await sftp.withFile(filePath: remotePath(for: file.relativePath), flags: .read) { remoteFile in
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let buffer = try await remoteFile.read(from: offset, length: 512 * 1_024)
                guard buffer.readableBytes > 0 else { break }
                try output.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(buffer.readableBytes)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: file.modifiedAt], ofItemAtPath: temporaryURL.path)
    }

    func upload(localURL: URL, file: SyncFile, preserveDate: Bool) async throws {
        let sftp = try await connect()
        let remotePath = remotePath(for: file.relativePath)
        try await ensureDirectory((remotePath as NSString).deletingLastPathComponent, sftp: sftp)
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { remoteFile in
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: 512 * 1_024), !data.isEmpty else { break }
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: offset)
                offset += UInt64(data.count)
            }
        }
        if preserveDate {
            let attributes = SFTPFileAttributes(
                accessModificationTime: .init(accessTime: file.modifiedAt, modificationTime: file.modifiedAt)
            )
            try await sftp.setAttributes(at: remotePath, to: attributes)
        }
    }

    func close() async {
        if let sftpClient { try? await sftpClient.close() }
        if let sshClient { await sshClient.close() }
        sftpClient = nil
        sshClient = nil
    }

    private func connect() async throws -> SFTPClient {
        if let sftpClient, sftpClient.isActive { return sftpClient }
        let hostID = "\(endpoint.host.lowercased()):\(endpoint.port)"
        let validator = SSHHostKeyValidator.custom(TrustOnFirstUseValidator(hostID: hostID))
        let username = endpoint.username
        let secret = password
        let settings = SSHClientSettings(
            host: endpoint.host,
            port: endpoint.port,
            authenticationMethod: { .passwordBased(username: username, password: secret) },
            hostKeyValidator: validator
        )
        let ssh = try await SSHClient.connect(to: settings)
        let sftp = try await ssh.openSFTP()
        sshClient = SSHClientBox(ssh)
        sftpClient = sftp
        return sftp
    }

    private func ensureDirectory(_ path: String, sftp: SFTPClient) async throws {
        guard path != "/", !path.isEmpty else { return }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/\(component)"
            if (try? await sftp.getAttributes(at: current)) == nil {
                try await sftp.createDirectory(atPath: current)
            }
        }
    }

    private var normalizedRoot: String {
        let root = endpoint.remotePath.isEmpty ? "/" : endpoint.remotePath
        return root.hasPrefix("/") ? root : "/" + root
    }

    private func remotePath(for relative: String) -> String { join(normalizedRoot, relative) }

    private func join(_ root: String, _ child: String) -> String {
        root.hasSuffix("/") ? root + child : root + "/" + child
    }
}

private final class SSHClientBox: @unchecked Sendable {
    private let client: SSHClient

    init(_ client: SSHClient) { self.client = client }

    func close() async { try? await client.close() }
}

private final class TrustOnFirstUseValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let hostID: String
    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    init(hostID: String) { self.hostID = hostID }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let publicKey = String(openSSHPublicKey: hostKey)
        let storageKey = "trusted-ssh-host-key.\(hostID)"
        lock.lock()
        defer { lock.unlock() }
        if let trusted = defaults.string(forKey: storageKey) {
            if trusted == publicKey { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(AppError.transferFailed("The SSH host key for \(hostID) changed. Connection refused to protect your files.")) }
        } else {
            defaults.set(publicKey, forKey: storageKey)
            validationCompletePromise.succeed(())
        }
    }
}
