import CryptoKit
import Darwin
import Foundation

/// A recognition snapshot package, not a lossless backup of companion-app editor
/// state. The current strict manifest declares every exported file. No ZIP,
/// process, app-group access, or implicit destination replacement is performed.
struct PeopleLibraryPackageService: Sendable {
    enum Failure: Error, Equatable {
        case invalidPackage, destinationExists, snapshotChanged, unsafeFile, io
    }
    static let pathExtension = "aagedalpeople"
    private let limits: PeopleLibraryManifest.Limits
    private let beforePublish: @Sendable () throws -> Void

    init(limits: PeopleLibraryManifest.Limits = .init(), beforePublish: @escaping @Sendable () throws -> Void = {}) {
        self.limits = limits; self.beforePublish = beforePublish
    }

    func importPackage(at directory: URL, into repository: PeopleLibraryRepository) throws -> PeopleLibrarySnapshot {
        try Self.validatePackageURL(directory)
        try Task.checkCancellation()
        // The service's admission limits apply before the receiving repository
        // can create directories or change its current selection. Callers must
        // keep the selected package stable through both validation and import.
        let validator = PeopleLibraryRepository(root: directory.deletingLastPathComponent(), limits: limits)
        _ = try validator.validateSnapshot(at: directory)
        try Task.checkCancellation()
        return try repository.importSnapshot(from: directory)
    }

    /// Parent directories are trusted, user-selected, and must remain stable for
    /// this call. Final directories and every copied child are opened no-follow.
    /// Internal staging failures clean the new sibling stage. Once the external
    /// publication hook can observe it, failures preserve the private stage for
    /// later recovery; cleanup must not remove substituted child entries.
    @discardableResult
    func export(_ snapshot: PeopleLibrarySnapshot, to destination: URL) throws -> URL {
        try Self.validatePackageURL(destination)
        try limits.validate(); try Task.checkCancellation()
        guard snapshot.directoryURL.isFileURL, !snapshot.directoryURL.path.contains("\0") else { throw Failure.unsafeFile }
        let validator = PeopleLibraryRepository(root: snapshot.directoryURL.deletingLastPathComponent(), limits: limits)
        try Self.requireSame(validator.validateSnapshot(at: snapshot.directoryURL), snapshot)
        let sourceFD = try Self.openDirectory(snapshot.directoryURL.path)
        defer { close(sourceFD) }
        let parent = destination.deletingLastPathComponent()
        let parentFD = try Self.openDirectory(parent.path)
        defer { close(parentFD) }
        let name = destination.lastPathComponent
        var existing = stat()
        if fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.destinationExists }
        guard errno == ENOENT else { throw Failure.io }

        let manifestBytes = try Self.readFile(sourceFD, path: PeopleLibraryManifest.fileName, maximum: limits.maximumManifestBytes)
        guard try PeopleLibraryManifest.decode(manifestBytes, limits: limits) == snapshot.manifest else { throw Failure.snapshotChanged }
        let paths = Set(snapshot.manifest.files.map(\.path)).union([PeopleLibraryManifest.fileName])
        let stageName = ".aagedalpeople-export-" + UUID().uuidString.lowercased()
        guard mkdirat(parentFD, stageName, S_IRWXU) == 0 else { throw Failure.io }
        let stageFD: Int32
        do { stageFD = try Self.openChild(parentFD, stageName) }
        catch { _ = unlinkat(parentFD, stageName, AT_REMOVEDIR); throw error }
        var published = false
        var cleanupAllowed = true
        defer {
            if !published && cleanupAllowed { Self.cleanStage(parent: parentFD, name: stageName, stage: stageFD, paths: paths) }
            close(stageFD)
        }
        try Self.writeFile(stageFD, path: PeopleLibraryManifest.fileName, bytes: manifestBytes)
        for declaration in snapshot.manifest.files {
            try Task.checkCancellation()
            let bytes = try Self.readFile(sourceFD, path: declaration.path, maximum: declaration.byteCount)
            guard bytes.count == declaration.byteCount,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == declaration.sha256 else {
                throw Failure.snapshotChanged
            }
            try Self.writeFile(stageFD, path: declaration.path, bytes: bytes)
        }
        let stageURL = parent.appendingPathComponent(stageName, isDirectory: true)
        try Self.requireSame(validator.validateSnapshot(at: stageURL), snapshot)
        cleanupAllowed = false
        try beforePublish()
        try Task.checkCancellation()
        // Recheck both original manifest/content and the owned stage before the
        // exclusive publication. The output always contains the captured bytes.
        try Self.requireSame(validator.validateSnapshot(at: snapshot.directoryURL), snapshot)
        try Self.requireSame(validator.validateSnapshot(at: stageURL), snapshot)
        var named = stat(), held = stat()
        guard fstatat(parentFD, stageName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(stageFD, &held) == 0, named.st_dev == held.st_dev, named.st_ino == held.st_ino,
              fsync(stageFD) == 0 else { throw Failure.unsafeFile }
        try Task.checkCancellation()
        guard renameatx_np(parentFD, stageName, parentFD, name, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY { throw Failure.destinationExists }
            throw Failure.io
        }
        published = true
        // A post-rename durability error must leave the user's new package in
        // place; cleanup never removes a published destination.
        guard fsync(parentFD) == 0 else { throw Failure.io }
        return destination
    }

    private static func validatePackageURL(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension == pathExtension, !url.path.contains("\0"),
              !url.lastPathComponent.isEmpty else { throw Failure.invalidPackage }
    }
    private static func requireSame(_ actual: PeopleLibrarySnapshot, _ expected: PeopleLibrarySnapshot) throws {
        guard actual.manifest == expected.manifest, actual.gallery == expected.gallery else { throw Failure.snapshotChanged }
    }
    private static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unsafeFile }; return fd
    }
    private static func openChild(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unsafeFile }; return fd
    }
    private static func directory(_ parent: Int32, path: String, create: Bool) throws -> (Int32, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") }) else { throw Failure.unsafeFile }
        if parts.count == 1 {
            let fd = dup(parent); guard fd >= 0 else { throw Failure.io }; return (fd, parts[0])
        }
        if create, mkdirat(parent, parts[0], S_IRWXU) != 0, errno != EEXIST { throw Failure.io }
        return (try openChild(parent, parts[0]), parts[1])
    }
    private static func readFile(_ parent: Int32, path: String, maximum: Int) throws -> Data {
        let (directory, name) = try Self.directory(parent, path: path, create: false)
        defer { close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unsafeFile }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximum else { throw Failure.unsafeFile }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = read(fd, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.unsafeFile }
        return bytes
    }
    private static func writeFile(_ parent: Int32, path: String, bytes: Data) throws {
        let (directory, name) = try Self.directory(parent, path: path, create: true)
        defer { close(directory) }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw Failure.io }
    }
    private static func cleanStage(parent: Int32, name: String, stage: Int32, paths: Set<String>) {
        for path in paths {
            if let (directory, file) = try? Self.directory(stage, path: path, create: false) {
                _ = unlinkat(directory, file, 0); close(directory)
            }
        }
        for folder in Set(paths.compactMap({ $0.contains("/") ? $0.components(separatedBy: "/").first : nil })) {
            _ = unlinkat(stage, folder, AT_REMOVEDIR)
        }
        var named = stat(), held = stat()
        if fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(stage, &held) == 0,
           named.st_dev == held.st_dev, named.st_ino == held.st_ino { _ = unlinkat(parent, name, AT_REMOVEDIR) }
    }
}
