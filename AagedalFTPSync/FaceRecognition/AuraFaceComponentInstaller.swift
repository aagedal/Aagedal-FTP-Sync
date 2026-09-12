import CoreML
import Darwin
import Foundation

struct AuraFaceDownloadResponse: Equatable, Sendable {
    let statusCode: Int
    let finalURL: URL
    let byteCount: Int
}

struct AuraFaceDownloadClient: @unchecked Sendable {
    typealias Progress = @Sendable (_ bytesReceived: Int, _ expectedBytes: Int?) -> Void
    var download: @Sendable (_ url: URL, _ destination: URL, _ maximumBytes: Int,
                             _ progress: @escaping Progress) async throws -> AuraFaceDownloadResponse

    static let live = AuraFaceDownloadClient { url, destination, maximumBytes, progress in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let delegate = AuraFaceNoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuraFaceComponentError.invalidServerResponse
        }
        let expected = http.expectedContentLength >= 0 ? Int(http.expectedContentLength) : nil
        if let expected, expected > maximumBytes { throw AuraFaceComponentError.responseTooLarge }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                          S_IRUSR | S_IWUSR)
        guard output >= 0 else {
            throw AuraFaceComponentError.io
        }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        defer { try? handle.close() }
        var buffer = Data(), received = 0
        buffer.reserveCapacity(65_536)
        for try await byte in bytes {
            try Task.checkCancellation()
            received += 1
            guard received <= maximumBytes else { throw AuraFaceComponentError.responseTooLarge }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(received, expected)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
        progress(received, expected)
        return .init(statusCode: http.statusCode, finalURL: http.url ?? url, byteCount: received)
    }
}

private final class AuraFaceNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

enum AuraFaceComponentAvailability: Equatable, Sendable {
    case notInstalled
    /// The signed source component is installed. Recognition remains a separate gate.
    case installed(version: String)
    case verificationFailed
}

struct AuraFaceComponentResolution: Equatable, Sendable {
    let availability: AuraFaceComponentAvailability
}

actor AuraFaceComponentInstaller {
    typealias Compiler = @Sendable (_ package: URL, _ destination: URL) throws -> Void
    typealias Progress = @Sendable (_ fraction: Double?) -> Void

    private let trust: AuraFaceDistributionTrust
    private let root: URL
    private let downloads: AuraFaceDownloadClient
    private let compile: Compiler
    private let files: FileManager

    init(trust: AuraFaceDistributionTrust, root: URL,
         downloads: AuraFaceDownloadClient = .live,
         compile: @escaping Compiler = AuraFaceComponentInstaller.compileCoreML,
         files: FileManager = .default) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"),
              root.lastPathComponent == "AuraFace",
              root.deletingLastPathComponent().lastPathComponent == "Components" else {
            throw AuraFaceComponentError.invalidTrustConfiguration
        }
        self.trust = trust
        self.root = root.standardizedFileURL
        self.downloads = downloads
        self.compile = compile
        self.files = files
    }

    /// Keeps the optional, re-downloadable component outside the exact v3 store inventory.
    static func componentRoot(forValidatedStorage storage: AppStorageLayout) throws -> URL {
        guard case .version3 = storage.storageFormat,
              storage.root.lastPathComponent == "v3" else {
            throw AuraFaceComponentError.invalidTrustConfiguration
        }
        return storage.root.deletingLastPathComponent()
            .appendingPathComponent("Components/AuraFace", isDirectory: true)
    }

    func downloadAndInstall(progress: @escaping Progress = { _ in }) async throws
        -> AuraFaceDistributionDescriptor {
        try Task.checkCancellation()
        try prepareRoot()
        let lock = try acquireRootLock()
        defer { releaseRootLock(lock) }
        // Reconcile an interrupted previous publication before manipulating rollback.
        _ = try resolveInstalledLocked()
        let transaction = root.appendingPathComponent("staging-" + UUID().uuidString.lowercased(),
                                                      isDirectory: true)
        try files.createDirectory(at: transaction, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        let transactionIdentity = try directoryIdentity(transaction)
        defer { try? removeOwnedDirectory(transaction, identity: transactionIdentity) }

        let descriptorURL = transaction.appendingPathComponent("incoming-descriptor")
        let signatureURL = transaction.appendingPathComponent("incoming-signature")
        _ = try await fetch(trust.descriptorURL, to: descriptorURL,
                            maximum: AuraFaceDistributionContract.maximumDescriptorBytes) { _, _ in }
        _ = try await fetch(trust.signatureURL, to: signatureURL,
                            maximum: AuraFaceDistributionContract.maximumSignatureBytes) { _, _ in }
        try Task.checkCancellation()
        let descriptorData = try boundedRead(descriptorURL,
            maximum: AuraFaceDistributionContract.maximumDescriptorBytes)
        let signatureData = try boundedRead(signatureURL,
            maximum: AuraFaceDistributionContract.maximumSignatureBytes)
        let descriptor = try AuraFaceDistributionContract.verify(
            descriptorData: descriptorData, signatureData: signatureData, trust: trust)

        let archiveURL = transaction.appendingPathComponent(descriptor.archive.fileName)
        let response = try await fetch(descriptor.downloadURL, to: archiveURL,
                                       maximum: descriptor.archive.byteCount) { received, expected in
            let denominator = expected ?? descriptor.archive.byteCount
            progress(denominator > 0 ? min(1, Double(received) / Double(denominator)) : nil)
        }
        guard response.byteCount == descriptor.archive.byteCount else {
            throw AuraFaceComponentError.archiveSizeMismatch
        }
        let archiveDigest = try AuraFaceDistributionContract.digest(
            file: archiveURL, maximumBytes: descriptor.archive.byteCount)
        guard archiveDigest.bytes == descriptor.archive.byteCount,
              archiveDigest.sha256 == descriptor.archive.sha256 else {
            throw AuraFaceComponentError.archiveHashMismatch
        }
        try Task.checkCancellation()

        let candidate = transaction.appendingPathComponent("candidate", isDirectory: true)
        try files.createDirectory(at: candidate, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        let package = candidate.appendingPathComponent(AuraFaceDistributionContract.packageDirectory,
                                                       isDirectory: true)
        let archive = try AuraFaceZIPArchive(url: archiveURL, descriptor: descriptor)
        try archive.extract(to: package, descriptor: descriptor)
        try Task.checkCancellation()
        try compile(package, candidate.appendingPathComponent(
            AuraFaceDistributionContract.compiledDirectory, isDirectory: true))
        try Task.checkCancellation()
        try descriptorData.write(to: candidate.appendingPathComponent(
            AuraFaceDistributionContract.descriptorFile), options: [.atomic])
        try signatureData.write(to: candidate.appendingPathComponent(
            AuraFaceDistributionContract.signatureFile), options: [.atomic])
        _ = try verifyDirectory(candidate)
        try syncDirectory(candidate)
        try Task.checkCancellation()
        try publish(candidate: candidate, transaction: transaction)
        return descriptor
    }

    /// Repairs the only interrupted publication state (`rollback` valid, `current` absent)
    /// and never contacts the network.
    func resolveInstalled() throws -> AuraFaceComponentResolution {
        try prepareRoot()
        let lock = try acquireRootLock()
        defer { releaseRootLock(lock) }
        return try resolveInstalledLocked()
    }

    private func resolveInstalledLocked() throws -> AuraFaceComponentResolution {
        try removeAbandonedStages()
        let current = root.appendingPathComponent("current", isDirectory: true)
        let rollback = root.appendingPathComponent("rollback", isDirectory: true)
        if let descriptor = try validDescriptorIfPresent(current) {
            return ready(descriptor)
        }
        if let descriptor = try validDescriptorIfPresent(rollback) {
            let invalid = root.appendingPathComponent("invalid-" + UUID().uuidString.lowercased(),
                                                     isDirectory: true)
            if files.fileExists(atPath: current.path) { try files.moveItem(at: current, to: invalid) }
            do { try files.moveItem(at: rollback, to: current) }
            catch {
                if files.fileExists(atPath: invalid.path), !files.fileExists(atPath: current.path) {
                    try? files.moveItem(at: invalid, to: current)
                }
                throw AuraFaceComponentError.installationFailed
            }
            try syncDirectory(root)
            try? files.removeItem(at: invalid)
            return ready(descriptor)
        }
        let exists = files.fileExists(atPath: current.path) || files.fileExists(atPath: rollback.path)
        return .init(availability: exists ? .verificationFailed : .notInstalled)
    }

    /// Offline and idempotent. Existing users must retain their already captured immutable URL
    /// until their operation ends; this method performs no runtime publication itself.
    func removeInstalled() throws {
        try Task.checkCancellation()
        try prepareRoot()
        let lock = try acquireRootLock()
        defer { releaseRootLock(lock) }
        for name in ["current", "rollback"] {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
        try removeAbandonedStages()
        try syncDirectory(root)
    }

    private func fetch(_ url: URL, to destination: URL, maximum: Int,
                       progress: @escaping AuraFaceDownloadClient.Progress) async throws
        -> AuraFaceDownloadResponse {
        guard trust.allowedOrigins.contains(where: { $0.contains(url) }) else {
            throw AuraFaceComponentError.invalidDescriptor
        }
        let response = try await downloads.download(url, destination, maximum, progress)
        guard (200..<300).contains(response.statusCode) else {
            throw AuraFaceComponentError.invalidServerResponse
        }
        guard response.finalURL == url else { throw AuraFaceComponentError.redirectedResponse }
        guard response.byteCount >= 0, response.byteCount <= maximum else {
            throw AuraFaceComponentError.responseTooLarge
        }
        return response
    }

    private func verifyDirectory(_ directory: URL) throws -> AuraFaceDistributionDescriptor {
        guard isDirectory(directory) else { throw AuraFaceComponentError.invalidInstalledComponent }
        let descriptorData = try boundedRead(directory.appendingPathComponent(
            AuraFaceDistributionContract.descriptorFile), maximum: AuraFaceDistributionContract.maximumDescriptorBytes)
        let signatureData = try boundedRead(directory.appendingPathComponent(
            AuraFaceDistributionContract.signatureFile), maximum: AuraFaceDistributionContract.maximumSignatureBytes)
        let descriptor = try AuraFaceDistributionContract.verify(
            descriptorData: descriptorData, signatureData: signatureData, trust: trust)
        let package = directory.appendingPathComponent(AuraFaceDistributionContract.packageDirectory,
                                                       isDirectory: true)
        let compiled = directory.appendingPathComponent(
            AuraFaceDistributionContract.compiledDirectory, isDirectory: true)
        guard isDirectory(package), isDirectory(compiled) else {
            throw AuraFaceComponentError.invalidInstalledComponent
        }
        let enumerator = files.enumerator(at: package,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
        var actual: Set<String> = []
        let expectedDirectories: Set<String> = ["Data", "Data/com.apple.CoreML",
                                                "Data/com.apple.CoreML/weights"]
        while let url = enumerator?.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw AuraFaceComponentError.invalidInstalledComponent }
            let prefix = package.standardizedFileURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else {
                throw AuraFaceComponentError.invalidInstalledComponent
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            if values.isRegularFile == true {
                actual.insert(relative)
            } else if values.isDirectory == true {
                guard expectedDirectories.contains(relative) else {
                    throw AuraFaceComponentError.invalidInstalledComponent
                }
            } else {
                throw AuraFaceComponentError.invalidInstalledComponent
            }
        }
        guard actual == AuraFaceDistributionContract.packagePaths else {
            throw AuraFaceComponentError.packageFileSetMismatch
        }
        for path in actual.sorted() {
            guard let expected = descriptor.packageFiles[path] else {
                throw AuraFaceComponentError.packageFileSetMismatch
            }
            let measured = try AuraFaceDistributionContract.digest(
                file: package.appendingPathComponent(path), maximumBytes: expected.byteCount)
            guard measured.bytes == expected.byteCount else {
                throw AuraFaceComponentError.packageSizeMismatch(path)
            }
            guard measured.sha256 == expected.sha256 else {
                throw AuraFaceComponentError.packageHashMismatch(path)
            }
        }
        let compiledEnumerator = files.enumerator(at: compiled,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
        var compiledFiles = 0
        while let url = compiledEnumerator?.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AuraFaceComponentError.invalidInstalledComponent }
            if values.isRegularFile == true { compiledFiles += 1 }
            else if values.isDirectory != true { throw AuraFaceComponentError.invalidInstalledComponent }
        }
        guard compiledFiles > 0 else { throw AuraFaceComponentError.invalidInstalledComponent }
        return descriptor
    }

    private func validDescriptorIfPresent(_ directory: URL) throws -> AuraFaceDistributionDescriptor? {
        do { return try verifyDirectory(directory) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// Publication is an intentionally synchronous, non-cancellable rename sequence.
    /// Cancellation is honored immediately before entering this commit boundary.
    private func publish(candidate: URL, transaction: URL) throws {
        try Task.checkCancellation()
        let current = root.appendingPathComponent("current", isDirectory: true)
        let rollback = root.appendingPathComponent("rollback", isDirectory: true)
        let retired = transaction.appendingPathComponent("retired-rollback", isDirectory: true)
        var retiredRollback = false, movedCurrent = false, movedCandidate = false
        do {
            if files.fileExists(atPath: rollback.path) {
                try files.moveItem(at: rollback, to: retired)
                retiredRollback = true
                try syncDirectory(root)
                try syncDirectory(transaction)
            }
            if files.fileExists(atPath: current.path) {
                try files.moveItem(at: current, to: rollback)
                movedCurrent = true
                try syncDirectory(root)
            }
            try files.moveItem(at: candidate, to: current)
            movedCandidate = true
            try syncDirectory(root)
        } catch {
            if movedCandidate, files.fileExists(atPath: current.path), !files.fileExists(atPath: candidate.path) {
                try? files.moveItem(at: current, to: candidate)
            }
            if movedCurrent, files.fileExists(atPath: rollback.path), !files.fileExists(atPath: current.path) {
                try? files.moveItem(at: rollback, to: current)
            }
            if retiredRollback, files.fileExists(atPath: retired.path), !files.fileExists(atPath: rollback.path) {
                try? files.moveItem(at: retired, to: rollback)
            }
            throw AuraFaceComponentError.installationFailed
        }
    }

    private func prepareRoot() throws {
        let components = root.deletingLastPathComponent()
        let applicationRoot = components.deletingLastPathComponent()
        let applicationFD = open(applicationRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard applicationFD >= 0 else { throw AuraFaceComponentError.io }
        defer { close(applicationFD) }
        try validateDirectoryDescriptor(applicationFD, requirePrivate: false)

        if mkdirat(applicationFD, components.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw AuraFaceComponentError.io
        }
        let componentsFD = openat(applicationFD, components.lastPathComponent,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard componentsFD >= 0 else { throw AuraFaceComponentError.io }
        defer { close(componentsFD) }
        try validateDirectoryDescriptor(componentsFD, requirePrivate: true)

        if mkdirat(componentsFD, root.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw AuraFaceComponentError.io
        }
        let rootFD = openat(componentsFD, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw AuraFaceComponentError.io }
        defer { close(rootFD) }
        try validateDirectoryDescriptor(rootFD, requirePrivate: true)
    }

    private func acquireRootLock() throws -> Int32 {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw AuraFaceComponentError.io }
        defer { close(rootFD) }
        let lock = openat(rootFD, ".installer.lock", O_RDWR | O_CREAT | O_NOFOLLOW,
                          S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw AuraFaceComponentError.io }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid(), info.st_size == 0 else {
            close(lock)
            throw AuraFaceComponentError.io
        }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                close(lock)
                throw AuraFaceComponentError.io
            }
            do { try Task.checkCancellation() }
            catch {
                close(lock)
                throw error
            }
            usleep(10_000)
        }
        return lock
    }

    private func releaseRootLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func validateDirectoryDescriptor(_ descriptor: Int32, requirePrivate: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), !requirePrivate || info.st_mode & 0o077 == 0 else {
            throw AuraFaceComponentError.io
        }
    }

    private func removeAbandonedStages() throws {
        for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            where isStageName(url.lastPathComponent) {
            try Task.checkCancellation()
            guard let identity = try? directoryIdentity(url), identity.owner == getuid(),
                  identity.permissions & 0o077 == 0 else { continue }
            try removeOwnedDirectory(url, identity: identity)
        }
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let permissions: mode_t
    }

    private func directoryIdentity(_ url: URL) throws -> DirectoryIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw AuraFaceComponentError.io
        }
        return .init(device: info.st_dev, inode: info.st_ino, owner: info.st_uid,
                     permissions: info.st_mode & 0o777)
    }

    private func removeOwnedDirectory(_ url: URL, identity: DirectoryIdentity) throws {
        guard try directoryIdentity(url) == identity else { throw AuraFaceComponentError.io }
        try files.removeItem(at: url)
    }

    private func isStageName(_ name: String) -> Bool {
        guard name.hasPrefix("staging-") else { return false }
        return UUID(uuidString: String(name.dropFirst("staging-".count))) != nil
    }

    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        try AuraFaceDistributionContract.read(file: url, maximumBytes: maximum)
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AuraFaceComponentError.io }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AuraFaceComponentError.io }
    }

    private func ready(_ descriptor: AuraFaceDistributionDescriptor) -> AuraFaceComponentResolution {
        .init(availability: .installed(version: descriptor.modelVersion))
    }

    private nonisolated static func compileCoreML(_ package: URL, _ destination: URL) throws {
        let compiled = try MLModel.compileModel(at: package)
        try FileManager.default.moveItem(at: compiled, to: destination)
    }
}
