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
                guard PathSafety.isSafeServerName(entry.filename),
                      !PathSafety.isInternalStagingPath(entry.filename) else { continue }
                let relative = directory.relative.isEmpty ? entry.filename : "\(directory.relative)/\(entry.filename)"
                let remote = join(directory.remote, entry.filename)
                let mode = entry.attributes.permissions ?? 0
                let kind = mode & 0o170000
                if kind == 0o040000 {
                    directories.append((remote, relative))
                } else if kind != 0o120000 {
                    if let existing = result[relative],
                       !PathSafety.hasIdenticalRepresentation(existing.relativePath, relative) {
                        throw AppError.transferFailed(
                            "Two server paths differ only by Unicode representation: \(existing.relativePath) and \(relative)."
                        )
                    }
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

    func upload(localURL: URL, file: SyncFile, preserveDate: Bool, verifySize: Bool) async throws {
        let sftp = try await connect()
        let remotePath = remotePath(for: file.relativePath)
        try await ensureDirectory((remotePath as NSString).deletingLastPathComponent, sftp: sftp)
        let temporaryPath = stagingPath(nextTo: remotePath, suffix: "part")
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        do {
            try await sftp.withFile(filePath: temporaryPath, flags: [.write, .create, .truncate]) { remoteFile in
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

            if verifySize {
                let attributes = try await sftp.getAttributes(at: temporaryPath)
                let uploadedSize = Int64(attributes.size ?? 0)
                guard uploadedSize == file.size else {
                    throw AppError.transferFailed(
                        "Size verification failed for \(file.relativePath): expected \(file.size) bytes, uploaded \(uploadedSize) bytes."
                    )
                }
            }

            if preserveDate {
                let attributes = SFTPFileAttributes(
                    accessModificationTime: .init(accessTime: file.modifiedAt, modificationTime: file.modifiedAt)
                )
                try await sftp.setAttributes(at: temporaryPath, to: attributes)
            }
            try await replaceUploadedFile(at: temporaryPath, destination: remotePath, sftp: sftp)
        } catch {
            try? await sftp.remove(at: temporaryPath)
            throw error
        }
    }

    func remove(file: SyncFile) async throws {
        let sftp = try await connect()
        try await sftp.remove(at: remotePath(for: file.relativePath))
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
        let validator = SSHHostKeyValidator.custom(PinnedHostKeyValidator(
            hostID: hostID,
            expectedFingerprint: endpoint.hostKeyFingerprint
        ))
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

    private func replaceUploadedFile(at temporaryPath: String, destination: String, sftp: SFTPClient) async throws {
        do {
            try await sftp.rename(at: temporaryPath, to: destination)
            return
        } catch let directRenameError {
            let backupPath = stagingPath(nextTo: destination, suffix: "backup")
            do {
                try await sftp.rename(at: destination, to: backupPath)
            } catch {
                throw directRenameError
            }

            do {
                try await sftp.rename(at: temporaryPath, to: destination)
                try? await sftp.remove(at: backupPath)
            } catch let replacementError {
                do {
                    try await sftp.rename(at: backupPath, to: destination)
                } catch {
                    throw AppError.transferFailed(
                        "Could not replace \(destination). The previous file remains at \(backupPath)."
                    )
                }
                throw replacementError
            }
        }
    }

    private func stagingPath(nextTo path: String, suffix: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let name = ".aagedal-sync-\(UUID().uuidString).\(suffix)"
        return parent == "/" ? "/\(name)" : "\(parent)/\(name)"
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

private final class PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let hostID: String
    private let expectedFingerprint: String?

    init(hostID: String, expectedFingerprint: String) {
        self.hostID = hostID
        self.expectedFingerprint = SSHHostKeyFingerprint.normalized(expectedFingerprint)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let publicKey = String(openSSHPublicKey: hostKey)
        guard let actualFingerprint = SSHHostKeyFingerprint.make(fromOpenSSHKey: publicKey) else {
            validationCompletePromise.fail(AppError.transferFailed("The SSH server returned an invalid host key."))
            return
        }
        guard let expectedFingerprint else {
            validationCompletePromise.fail(AppError.untrustedSSHHostKey(
                hostID: hostID,
                fingerprint: actualFingerprint
            ))
            return
        }
        guard expectedFingerprint == actualFingerprint else {
            validationCompletePromise.fail(AppError.changedSSHHostKey(
                hostID: hostID,
                expected: expectedFingerprint,
                actual: actualFingerprint
            ))
            return
        }
        validationCompletePromise.succeed(())
    }
}
