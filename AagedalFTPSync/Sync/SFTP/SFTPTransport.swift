import Citadel
import Foundation
import NIOCore
import NIOSSH

enum SFTPPathContainment {
    static func validateExistingParent(
        path: String,
        permissions: UInt32?,
        canonicalPath: String,
        root: String
    ) throws {
        let kind = (permissions ?? 0) & 0o170000
        guard kind == 0o040000 else {
            throw AppError.transferFailed(
                "The SFTP upload parent is a symbolic link or special file and was rejected: \(path)"
            )
        }
        guard canonicalPath == root
                || canonicalPath.hasPrefix(root == "/" ? "/" : root + "/") else {
            throw AppError.transferFailed(
                "The SFTP upload parent resolved outside its configured root: \(path)"
            )
        }
    }
}

actor SFTPTransport {
    private let endpoint: Endpoint
    private let password: String
    private let inactivityTimeoutSeconds: Int64
    private var sshClient: SSHClientBox?
    private var sftpClient: SFTPClient?
    private var canonicalRoot: String?

    init(endpoint: Endpoint, password: String, inactivityTimeoutSeconds: Int64 = 30) {
        self.endpoint = endpoint
        self.password = password
        self.inactivityTimeoutSeconds = max(inactivityTimeoutSeconds, 1)
    }

    func testConnection() async throws {
        try await perform(operation: "connection test") {
            let sftp = try await self.connect()
            _ = try await sftp.listDirectory(atPath: try await self.resolvedRoot(using: sftp))
        }
    }

    func listFiles() async throws -> [String: SyncFile] {
        try await perform(operation: "listing") {
            try await self.walkFiles(onCompletedDirectory: nil)
        }
    }

    func listFilesIncrementally(
        onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void
    ) async throws -> [String: SyncFile] {
        try await perform(operation: "listing") {
            try await self.walkFiles(onCompletedDirectory: onCompletedDirectory)
        }
    }

    private func walkFiles(
        onCompletedDirectory: (@Sendable (CompletedDirectoryListing) async throws -> Void)?
    ) async throws -> [String: SyncFile] {
        let sftp = try await connect()
        return try await RemoteTreeWalker.listFiles(
            root: try await resolvedRoot(using: sftp),
            join: { root, child in
                root.hasSuffix("/") ? root + child : root + "/" + child
            },
            listDirectory: { remoteDirectory in
                let responses = try await sftp.listDirectory(atPath: remoteDirectory)
                return try responses.flatMap(\.components).compactMap { entry in
                    guard PathSafety.isSafeServerName(entry.filename) else { return nil }
                    let kind = (entry.attributes.permissions ?? 0) & 0o170000
                    guard kind == 0o040000 || kind == 0o100000 else { return nil }
                    let modificationTime = entry.attributes.accessModificationTime?.modificationTime
                    let size = kind == 0o040000
                        ? 0
                        : try RemoteFileSize.checked(
                            entry.attributes.size,
                            protocolName: "SFTP",
                            path: entry.filename
                        )
                    return RemoteDirectoryEntry(
                        name: entry.filename,
                        isDirectory: kind == 0o040000,
                        size: size,
                        modifiedAt: modificationTime ?? .distantPast,
                        hasAuthoritativeTimestamp: kind == 0o040000 || modificationTime != nil
                    )
                }
            },
            onCompletedDirectory: onCompletedDirectory
        )
    }

    func download(file: SyncFile, to temporaryURL: URL, maximumSize: Int64? = nil) async throws {
        try await perform(operation: "read") {
            try await self.downloadWithoutDeadlineMapping(
                file: file,
                to: temporaryURL,
                maximumSize: maximumSize
            )
        }
    }

    private func downloadWithoutDeadlineMapping(
        file: SyncFile,
        to temporaryURL: URL,
        maximumSize: Int64?
    ) async throws {
        let initialSizeLimit = try maximumSize.map(TransferSizeLimit.init(maximumBytes:))
        let sftp = try await connect()
        _ = FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }
        let sourcePath = try await remotePath(for: file.relativePath, sftp: sftp)
        try await sftp.withFile(filePath: sourcePath, flags: .read) { remoteFile in
            var offset: UInt64 = 0
            var sizeLimit = initialSizeLimit
            while true {
                try Task.checkCancellation()
                let buffer = try await remoteFile.read(from: offset, length: 512 * 1_024)
                guard buffer.readableBytes > 0 else { break }
                try sizeLimit?.record(buffer.readableBytes)
                try output.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(buffer.readableBytes)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: file.modifiedAt], ofItemAtPath: temporaryURL.path)
    }

    func upload(localURL: URL, file: SyncFile, preserveDate: Bool, verifySize: Bool) async throws {
        try await perform(operation: "write") {
            try await self.uploadWithoutDeadlineMapping(
                localURL: localURL,
                file: file,
                preserveDate: preserveDate,
                verifySize: verifySize
            )
        }
    }

    private func uploadWithoutDeadlineMapping(
        localURL: URL,
        file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        let sftp = try await connect()
        let remotePath = try await remotePath(for: file.relativePath, sftp: sftp)
        try await ensureSafeUploadParent(
            (remotePath as NSString).deletingLastPathComponent,
            sftp: sftp
        )
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
                let uploadedSize = try RemoteFileSize.checked(
                    attributes.size,
                    protocolName: "SFTP",
                    path: file.relativePath
                )
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
        try await perform(operation: "removal") {
            let sftp = try await self.connect()
            try await sftp.remove(at: try await self.remotePath(for: file.relativePath, sftp: sftp))
        }
    }

    func removeTransactionally(files: [SyncFile]) async throws {
        try await perform(operation: "transactional removal") {
            try await self.removeTransactionallyWithoutDeadlineMapping(files: files)
        }
    }

    private func removeTransactionallyWithoutDeadlineMapping(files: [SyncFile]) async throws {
        let sftp = try await connect()
        var sources: [String] = []
        for file in files {
            sources.append(try await remotePath(for: file.relativePath, sftp: sftp))
        }
        let staged = sources.map { stagingPath(nextTo: $0, suffix: "hold") }
        try await TransactionalRemoval.stageAndDelete(
            sources: sources,
            holdings: staged,
            labels: files.map(\.relativePath),
            move: { source, destination in
                try await sftp.rename(at: source, to: destination)
            },
            delete: { holding in try await sftp.remove(at: holding) }
        )
    }

    func close() async {
        let sftp = sftpClient
        let ssh = sshClient
        sftpClient = nil
        sshClient = nil
        canonicalRoot = nil
        if let sftp { try? await sftp.close() }
        if let ssh { await ssh.close() }
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
        let sftp = try await ssh.openSFTP(
            requestTimeout: .seconds(inactivityTimeoutSeconds)
        )
        sshClient = SSHClientBox(ssh)
        sftpClient = sftp
        return sftp
    }

    private func perform<T: Sendable>(
        operation: String,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withTaskCancellationHandler {
                try await body()
            } onCancel: {
                Task { await self.close() }
            }
        } catch is CancellationError {
            await close()
            throw CancellationError()
        } catch SFTPError.requestTimedOut {
            await close()
            throw AppError.remoteOperationTimedOut(
                protocolName: "SFTP",
                operation: operation,
                seconds: inactivityTimeoutSeconds
            )
        } catch SFTPError.missingResponse {
            await close()
            throw AppError.remoteOperationTimedOut(
                protocolName: "SFTP",
                operation: operation,
                seconds: inactivityTimeoutSeconds
            )
        } catch {
            if Task.isCancelled {
                await close()
                throw CancellationError()
            }
            throw error
        }
    }

    private func ensureSafeUploadParent(_ path: String, sftp: SFTPClient) async throws {
        let root = try await resolvedRoot(using: sftp)
        guard isContained(path, beneath: root) else {
            throw AppError.transferFailed("An SFTP upload path attempted to leave its configured root.")
        }
        guard path != root else { return }

        var current = root
        let suffix = String(path.dropFirst(root.count)).split(separator: "/")
        for component in suffix {
            current = join(current, String(component))
            if let attributes = try await sftp.getLinkAttributes(at: current) {
                let canonical = try await sftp.getRealPath(atPath: current)
                try SFTPPathContainment.validateExistingParent(
                    path: current,
                    permissions: attributes.permissions,
                    canonicalPath: canonical,
                    root: root
                )
            } else {
                try await sftp.createDirectory(atPath: current)
                guard let attributes = try await sftp.getLinkAttributes(at: current),
                      (attributes.permissions ?? 0) & 0o170000 == 0o040000 else {
                    throw AppError.transferFailed("The SFTP server did not create a real directory at \(current).")
                }
            }
            let canonical = try await sftp.getRealPath(atPath: current)
            guard isContained(canonical, beneath: root) else {
                throw AppError.transferFailed("The SFTP upload parent resolved outside its configured root: \(current)")
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

    private func resolvedRoot(using sftp: SFTPClient) async throws -> String {
        if let canonicalRoot { return canonicalRoot }
        let resolved = try await sftp.getRealPath(atPath: normalizedRoot)
        guard resolved.hasPrefix("/") else {
            throw AppError.transferFailed("The SFTP server returned a non-absolute configured root.")
        }
        canonicalRoot = resolved.count > 1 && resolved.hasSuffix("/")
            ? String(resolved.dropLast())
            : resolved
        guard let attributes = try await sftp.getLinkAttributes(at: canonicalRoot!),
              (attributes.permissions ?? 0) & 0o170000 == 0o040000 else {
            canonicalRoot = nil
            throw AppError.transferFailed("The configured SFTP root is not a real directory.")
        }
        return canonicalRoot!
    }

    private func remotePath(for relative: String, sftp: SFTPClient) async throws -> String {
        guard PathSafety.isSafeRelativePath(relative) else {
            throw AppError.transferFailed("An SFTP file contained an unsafe relative path.")
        }
        return join(try await resolvedRoot(using: sftp), relative)
    }

    private func isContained(_ path: String, beneath root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

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
