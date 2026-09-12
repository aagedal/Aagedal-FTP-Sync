import CryptoKit
import Darwin
import Foundation
import zlib

/// A recognition snapshot package, not a lossless backup of companion-app editor
/// state. The strict manifest declares every exported file. Directory packages
/// and bounded ZIP packages are admitted without a subprocess. No app-group
/// access or implicit destination replacement is performed.
struct PeopleLibraryPackageService: Sendable {
    enum Failure: Error, Equatable {
        case invalidPackage, destinationExists, snapshotChanged, unsafeFile, io
    }
    static let pathExtension = "aagedalpeople"
    static let zipPathExtension = "aagedalpeople.zip"
    private let limits: PeopleLibraryManifest.Limits
    private let beforePublish: @Sendable () throws -> Void

    init(limits: PeopleLibraryManifest.Limits = .init(), beforePublish: @escaping @Sendable () throws -> Void = {}) {
        self.limits = limits; self.beforePublish = beforePublish
    }

    func importPackage(at package: URL, into repository: PeopleLibraryRepository) throws -> PeopleLibrarySnapshot {
        let kind = try Self.packageKind(package)
        try Task.checkCancellation()
        if kind == .zip { return try importZIP(at: package, into: repository) }
        // The service's admission limits apply before the receiving repository
        // can create directories or change its current selection. Callers must
        // keep the selected package stable through both validation and import.
        let validator = PeopleLibraryRepository(root: package.deletingLastPathComponent(), limits: limits)
        _ = try validator.validateSnapshot(at: package)
        try Task.checkCancellation()
        return try repository.importSnapshot(from: package)
    }

    private func importZIP(at package: URL, into repository: PeopleLibraryRepository) throws -> PeopleLibrarySnapshot {
        try limits.validate()
        let archiveFD = open(package.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard archiveFD >= 0 else { throw Failure.unsafeFile }
        defer { close(archiveFD) }
        var archiveIdentity = stat()
        guard fstat(archiveFD, &archiveIdentity) == 0,
              archiveIdentity.st_mode & S_IFMT == S_IFREG,
              archiveIdentity.st_nlink == 1,
              archiveIdentity.st_size >= 0 else { throw Failure.unsafeFile }
        let archive = try ZIPArchive(fd: archiveFD, size: Int(archiveIdentity.st_size), limits: limits)
        try Task.checkCancellation()

        // The extraction stage is a private sibling of the receiving repository.
        // All archive metadata and declared limits have already been admitted.
        let parentURL = repository.root.deletingLastPathComponent()
        let parentFD = try Self.openTrustedDirectory(parentURL.path)
        defer { close(parentFD) }
        let stageName = ".aagedalpeople-import-" + UUID().uuidString.lowercased()
        guard mkdirat(parentFD, stageName, S_IRWXU) == 0 else { throw Failure.io }
        let stageFD: Int32
        do { stageFD = try Self.openChild(parentFD, stageName) }
        catch {
            _ = unlinkat(parentFD, stageName, AT_REMOVEDIR)
            throw error
        }
        var heldStage = stat(), namedStage = stat()
        guard fstat(stageFD, &heldStage) == 0,
              heldStage.st_mode & S_IFMT == S_IFDIR,
              fstatat(parentFD, stageName, &namedStage, AT_SYMLINK_NOFOLLOW) == 0,
              namedStage.st_dev == heldStage.st_dev,
              namedStage.st_ino == heldStage.st_ino else {
            close(stageFD)
            Self.removeOwnedDirectory(parent: parentFD, name: stageName, identity: heldStage)
            throw Failure.unsafeFile
        }
        var created: [OwnedEntry] = []
        var createdDirectories: [OwnedDirectory] = []
        defer {
            Self.cleanImportStage(parent: parentFD, name: stageName, stage: stageFD,
                entries: created, directories: createdDirectories)
            close(stageFD)
        }
        for directory in Set(archive.files.compactMap({ $0.packagePath.contains("/")
            ? $0.packagePath.components(separatedBy: "/").first : nil })).sorted() {
            createdDirectories.append(try Self.createDirectoryRecordingIdentity(stageFD, name: directory))
        }
        for item in archive.files {
            try Task.checkCancellation()
            let bytes = try archive.contents(of: item)
            let identity = try Self.writeFileRecordingIdentity(stageFD, path: item.packagePath, bytes: bytes)
            created.append(.init(path: item.packagePath, identity: identity))
        }
        var archiveAfter = stat()
        guard fstat(archiveFD, &archiveAfter) == 0,
              Self.sameFile(archiveIdentity, archiveAfter) else { throw Failure.unsafeFile }
        let stageURL = parentURL.appendingPathComponent(stageName, isDirectory: true)
        let validator = PeopleLibraryRepository(root: parentURL, limits: limits)
        _ = try validator.validateSnapshot(at: stageURL)
        try Task.checkCancellation()
        return try repository.importSnapshot(from: stageURL)
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

    private enum PackageKind { case directory, zip }
    private static func packageKind(_ url: URL) throws -> PackageKind {
        guard url.isFileURL, url.pathExtension == pathExtension, !url.path.contains("\0"),
              !url.lastPathComponent.isEmpty else {
            guard url.isFileURL, url.lastPathComponent.hasSuffix("." + zipPathExtension),
                  !url.path.contains("\0"), !url.lastPathComponent.isEmpty else { throw Failure.invalidPackage }
            return .zip
        }
        return .directory
    }
    private static func validatePackageURL(_ url: URL) throws {
        guard try packageKind(url) == .directory else { throw Failure.invalidPackage }
    }
    private static func requireSame(_ actual: PeopleLibrarySnapshot, _ expected: PeopleLibrarySnapshot) throws {
        guard actual.manifest == expected.manifest, actual.gallery == expected.gallery else { throw Failure.snapshotChanged }
    }
    private static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unsafeFile }; return fd
    }
    private static func openTrustedDirectory(_ path: String) throws -> Int32 {
        let fd = try openDirectory(path)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { close(fd); throw Failure.unsafeFile }
        return fd
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
    private struct FileIdentity { let device: dev_t; let inode: ino_t }
    private struct OwnedEntry { let path: String; let identity: FileIdentity }
    private struct OwnedDirectory { let name: String; let identity: FileIdentity }
    private static func createDirectoryRecordingIdentity(_ parent: Int32, name: String) throws -> OwnedDirectory {
        guard mkdirat(parent, name, S_IRWXU) == 0 else { throw Failure.io }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { _ = unlinkat(parent, name, AT_REMOVEDIR); throw Failure.unsafeFile }
        defer { close(fd) }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, held.st_mode & S_IFMT == S_IFDIR,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino else {
            Self.removeOwnedDirectory(parent: parent, name: name, identity: held)
            throw Failure.unsafeFile
        }
        return .init(name: name, identity: .init(device: held.st_dev, inode: held.st_ino))
    }
    private static func writeFileRecordingIdentity(_ parent: Int32, path: String, bytes: Data) throws -> FileIdentity {
        let (directory, name) = try Self.directory(parent, path: path, create: true)
        defer { close(directory) }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.io }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_nlink == 1 else { close(fd); throw Failure.unsafeFile }
        let identity = FileIdentity(device: initial.st_dev, inode: initial.st_ino)
        var completed = false
        defer {
            close(fd)
            if !completed {
                var named = stat()
                if fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   named.st_dev == identity.device, named.st_ino == identity.inode {
                    _ = unlinkat(directory, name, 0)
                }
            }
        }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        var final = stat()
        guard fsync(fd) == 0, fsync(directory) == 0, fstat(fd, &final) == 0,
              final.st_dev == identity.device, final.st_ino == identity.inode,
              final.st_mode & S_IFMT == S_IFREG, final.st_nlink == 1,
              final.st_size == bytes.count else { throw Failure.unsafeFile }
        completed = true
        return identity
    }
    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
        lhs.st_mode & S_IFMT == S_IFREG && rhs.st_mode & S_IFMT == S_IFREG &&
        lhs.st_nlink == 1 && rhs.st_nlink == 1 && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
    private static func removeOwnedDirectory(parent: Int32, name: String, identity: stat) {
        var named = stat()
        if fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
           named.st_dev == identity.st_dev, named.st_ino == identity.st_ino {
            _ = unlinkat(parent, name, AT_REMOVEDIR)
        }
    }
    private static func cleanImportStage(parent: Int32, name: String, stage: Int32,
                                         entries: [OwnedEntry], directories: [OwnedDirectory]) {
        _ = fchmod(stage, S_IRWXU)
        for entry in entries {
            guard let (directory, file) = try? Self.directory(stage, path: entry.path, create: false) else { continue }
            var info = stat()
            if fstatat(directory, file, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_dev == entry.identity.device, info.st_ino == entry.identity.inode {
                _ = unlinkat(directory, file, 0)
            }
            close(directory)
        }
        for directory in directories {
            var info = stat()
            if fstatat(stage, directory.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_dev == directory.identity.device, info.st_ino == directory.identity.inode {
                _ = unlinkat(stage, directory.name, AT_REMOVEDIR)
            }
        }
        var named = stat(), held = stat()
        if fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(stage, &held) == 0,
           named.st_dev == held.st_dev, named.st_ino == held.st_ino { _ = unlinkat(parent, name, AT_REMOVEDIR) }
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

    /// Minimal ZIP32 reader for package admission. It deliberately supports only
    /// stored and raw-DEFLATE entries and creates filesystem objects itself.
    private struct ZIPArchive {
        struct File {
            let packagePath: String
            let nameBytes: Data
            let method: UInt16
            let crc32: UInt32
            let compressedSize: Int
            let uncompressedSize: Int
            let dataOffset: Int
        }
        private struct Entry {
            enum Kind: Equatable { case file, directory }
            let path: String
            let nameBytes: Data
            let kind: Kind
            let method: UInt16
            let flags: UInt16
            let crc32: UInt32
            let compressedSize: Int
            let uncompressedSize: Int
            let localOffset: Int
            var dataOffset = 0
        }

        let fd: Int32
        let files: [File]

        init(fd: Int32, size: Int, limits: PeopleLibraryManifest.Limits) throws {
            let maximumArchiveBytes = limits.maximumTotalBytes + limits.maximumManifestBytes
                + (limits.maximumFiles + 6) * 1_024 + 1_048_576
            guard size >= 22, size <= maximumArchiveBytes else { throw Failure.invalidPackage }
            let tailSize = min(size, 65_535 + 22)
            let tail = try Self.read(fd, offset: size - tailSize, count: tailSize)
            guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                tail.u32($0) == 0x0605_4b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
            }) else { throw Failure.invalidPackage }
            guard tail.u16(eocd + 4) == 0, tail.u16(eocd + 6) == 0 else { throw Failure.invalidPackage }
            let diskCount = Int(tail.u16(eocd + 8)), count = Int(tail.u16(eocd + 10))
            let maximumArchiveEntries = min(limits.maximumFiles + 6, limits.maximumEmbeddings + 6)
            guard diskCount == count, count > 0, count <= maximumArchiveEntries else { throw Failure.invalidPackage }
            let centralSize32 = tail.u32(eocd + 12), centralOffset32 = tail.u32(eocd + 16)
            guard centralSize32 != UInt32.max, centralOffset32 != UInt32.max,
                  count != Int(UInt16.max) else { throw Failure.invalidPackage }
            let centralSize = Int(centralSize32), centralOffset = Int(centralOffset32)
            let eocdOffset = size - tailSize + eocd
            let maximumCentralDirectoryBytes = max(1_048_576, limits.maximumManifestBytes * 2)
            guard centralOffset >= 0, centralSize >= 0,
                  centralSize <= maximumCentralDirectoryBytes,
                  centralOffset <= eocdOffset, centralSize == eocdOffset - centralOffset else { throw Failure.invalidPackage }
            let central = try Self.read(fd, offset: centralOffset, count: centralSize)
            var entries: [Entry] = [], cursor = 0, collisionKeys: Set<String> = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                try Task.checkCancellation()
                guard cursor <= central.count - 46, central.u32(cursor) == 0x0201_4b50 else { throw Failure.invalidPackage }
                let versionMadeBy = central.u16(cursor + 4)
                let flags = central.u16(cursor + 8), method = central.u16(cursor + 10)
                let crc = central.u32(cursor + 16)
                let compressed32 = central.u32(cursor + 20), uncompressed32 = central.u32(cursor + 24)
                let nameLength = Int(central.u16(cursor + 28)), extraLength = Int(central.u16(cursor + 30))
                let commentLength = Int(central.u16(cursor + 32))
                let disk = central.u16(cursor + 34), external = central.u32(cursor + 38)
                let localOffset32 = central.u32(cursor + 42)
                let recordLength = 46 + nameLength + extraLength + commentLength
                guard nameLength > 0, nameLength <= 1_024, cursor <= central.count - recordLength,
                      disk == 0, compressed32 != UInt32.max, uncompressed32 != UInt32.max,
                      localOffset32 != UInt32.max, flags & ~UInt16(0x080e) == 0,
                      flags & 0x0001 == 0, method == 0 || method == 8 else { throw Failure.invalidPackage }
                let nameBytes = central.subdata(in: cursor + 46..<cursor + 46 + nameLength)
                guard let path = String(data: nameBytes, encoding: .utf8) else { throw Failure.unsafeFile }
                let extra = central.subdata(in: cursor + 46 + nameLength..<cursor + 46 + nameLength + extraLength)
                try Self.validateExtraFields(extra)
                let kind = try Self.kind(path: path, versionMadeBy: versionMadeBy, external: external)
                try Self.validatePath(path, kind: kind)
                let collisionKey = Self.collisionKey(path, kind: kind)
                guard collisionKeys.insert(collisionKey).inserted else { throw Failure.unsafeFile }
                let compressedSize = Int(compressed32), uncompressedSize = Int(uncompressed32)
                if kind == .directory {
                    guard method == 0, compressedSize == 0, uncompressedSize == 0 else { throw Failure.invalidPackage }
                } else {
                    let overhead = max(64, uncompressedSize / 1_000 + 64)
                    guard uncompressedSize > 0,
                          uncompressedSize <= max(limits.maximumFileBytes, limits.maximumManifestBytes),
                          compressedSize > 0, compressedSize <= uncompressedSize + overhead else { throw Failure.invalidPackage }
                }
                entries.append(.init(path: path, nameBytes: nameBytes, kind: kind, method: method,
                    flags: flags, crc32: crc, compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize, localOffset: Int(localOffset32)))
                cursor += recordLength
            }
            guard cursor == central.count else { throw Failure.invalidPackage }

            for index in entries.indices {
                let entry = entries[index]
                guard entry.localOffset >= 0, entry.localOffset <= centralOffset - 30 else { throw Failure.invalidPackage }
                let local = try Self.read(fd, offset: entry.localOffset, count: 30)
                guard local.u32(0) == 0x0403_4b50, local.u16(6) == entry.flags,
                      local.u16(8) == entry.method else { throw Failure.invalidPackage }
                if entry.flags & 0x0008 == 0 {
                    guard local.u32(14) == entry.crc32,
                          local.u32(18) == UInt32(entry.compressedSize),
                          local.u32(22) == UInt32(entry.uncompressedSize) else { throw Failure.invalidPackage }
                }
                let localNameLength = Int(local.u16(26)), localExtraLength = Int(local.u16(28))
                guard localNameLength == entry.nameBytes.count else { throw Failure.invalidPackage }
                let localVariable = try Self.read(fd, offset: entry.localOffset + 30,
                    count: localNameLength + localExtraLength)
                guard localVariable.prefix(localNameLength) == entry.nameBytes else { throw Failure.invalidPackage }
                try Self.validateExtraFields(localVariable.subdata(in: localNameLength..<localVariable.count))
                let dataOffset = entry.localOffset + 30 + localNameLength + localExtraLength
                guard dataOffset <= centralOffset, entry.compressedSize <= centralOffset - dataOffset else { throw Failure.invalidPackage }
                entries[index].dataOffset = dataOffset
            }
            var nextOffset = 0
            let sortedEntries = entries.sorted(by: { $0.localOffset < $1.localOffset })
            for (index, entry) in sortedEntries.enumerated() {
                guard entry.localOffset == nextOffset else { throw Failure.invalidPackage }
                let dataEnd = entry.dataOffset + entry.compressedSize
                let boundary = index + 1 < sortedEntries.count ? sortedEntries[index + 1].localOffset : centralOffset
                if entry.flags & 0x0008 != 0 {
                    var matches = false
                    if dataEnd + 12 == boundary {
                        let descriptor = try Self.read(fd, offset: dataEnd, count: 12)
                        matches = descriptor.u32(0) == entry.crc32 &&
                            descriptor.u32(4) == UInt32(entry.compressedSize) &&
                            descriptor.u32(8) == UInt32(entry.uncompressedSize)
                    }
                    if !matches, dataEnd + 16 == boundary {
                        let descriptor = try Self.read(fd, offset: dataEnd, count: 16)
                        matches = descriptor.u32(0) == 0x0807_4b50 && descriptor.u32(4) == entry.crc32 &&
                            descriptor.u32(8) == UInt32(entry.compressedSize) &&
                            descriptor.u32(12) == UInt32(entry.uncompressedSize)
                    }
                    guard matches else { throw Failure.invalidPackage }
                } else {
                    guard dataEnd == boundary else { throw Failure.invalidPackage }
                }
                nextOffset = boundary
            }
            guard nextOffset == centralOffset else { throw Failure.invalidPackage }

            let manifests = entries.filter {
                $0.kind == .file && $0.path.split(separator: "/", omittingEmptySubsequences: false).last == Substring(PeopleLibraryManifest.fileName)
            }
            guard manifests.count == 1 else { throw Failure.invalidPackage }
            let manifestEntry = manifests[0]
            let components = manifestEntry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let rootComponents = Array(components.dropLast())
            guard rootComponents.count <= 1,
                  rootComponents.isEmpty || rootComponents[0].hasSuffix("." + PeopleLibraryPackageService.pathExtension) else {
                throw Failure.invalidPackage
            }
            let root = rootComponents.first
            let manifestData = try Self.contents(fd: fd, entry: manifestEntry)
            let manifest = try PeopleLibraryManifest.decode(manifestData, limits: limits)
            let expected = Set(manifest.files.map(\.path)).union([PeopleLibraryManifest.fileName])
            let expectedDirectories = Set(expected.compactMap { $0.contains("/") ? $0.components(separatedBy: "/")[0] : nil })
            var result: [File] = [], actual: Set<String> = [], total = 0
            for entry in entries {
                let relative: String
                if let root {
                    if entry.path == root + "/" { continue }
                    guard entry.path.hasPrefix(root + "/") else { throw Failure.invalidPackage }
                    relative = String(entry.path.dropFirst(root.count + 1))
                } else {
                    relative = entry.path
                }
                if entry.kind == .directory {
                    guard relative.hasSuffix("/"), expectedDirectories.contains(String(relative.dropLast())) else {
                        throw Failure.invalidPackage
                    }
                    continue
                }
                guard expected.contains(relative), actual.insert(relative).inserted else { throw Failure.invalidPackage }
                if relative == PeopleLibraryManifest.fileName {
                    guard entry.uncompressedSize == manifestData.count,
                          entry.uncompressedSize <= limits.maximumManifestBytes else { throw Failure.invalidPackage }
                } else {
                    let expectedSize = manifest.files.first(where: { $0.path == relative })!.byteCount
                    guard entry.uncompressedSize == expectedSize,
                          entry.uncompressedSize <= limits.maximumTotalBytes - total else { throw Failure.invalidPackage }
                    total += entry.uncompressedSize
                }
                result.append(.init(packagePath: relative, nameBytes: entry.nameBytes, method: entry.method,
                    crc32: entry.crc32, compressedSize: entry.compressedSize,
                    uncompressedSize: entry.uncompressedSize, dataOffset: entry.dataOffset))
            }
            guard actual == expected else { throw Failure.invalidPackage }
            self.fd = fd
            self.files = result
        }

        func contents(of file: File) throws -> Data {
            let compressed = try Self.read(fd, offset: file.dataOffset, count: file.compressedSize)
            let bytes: Data
            if file.method == 0 {
                guard compressed.count == file.uncompressedSize else { throw Failure.invalidPackage }
                bytes = compressed
            } else {
                bytes = try Self.inflateRaw(compressed, expectedSize: file.uncompressedSize)
            }
            guard Self.crc32(bytes) == file.crc32 else { throw Failure.invalidPackage }
            return bytes
        }

        private static func contents(fd: Int32, entry: Entry) throws -> Data {
            let compressed = try read(fd, offset: entry.dataOffset, count: entry.compressedSize)
            let bytes = entry.method == 0 ? compressed : try inflateRaw(compressed, expectedSize: entry.uncompressedSize)
            guard bytes.count == entry.uncompressedSize, crc32(bytes) == entry.crc32 else { throw Failure.invalidPackage }
            return bytes
        }
        private static func read(_ fd: Int32, offset: Int, count: Int) throws -> Data {
            guard offset >= 0, count >= 0 else { throw Failure.invalidPackage }
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { buffer in
                var consumed = 0
                while consumed < count {
                    try Task.checkCancellation()
                    let amount = pread(fd, buffer.baseAddress!.advanced(by: consumed),
                        min(65_536, count - consumed), off_t(offset + consumed))
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw Failure.io }
                    consumed += amount
                }
            }
            return data
        }
        private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
            guard expectedSize > 0 else { throw Failure.invalidPackage }
            var output = Data(count: expectedSize), stream = z_stream()
            let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initialized == Z_OK else { throw Failure.io }
            defer { inflateEnd(&stream) }
            let status: Int32 = try compressed.withUnsafeBytes { input in
                try output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                    var result: Int32 = Z_OK
                    while result == Z_OK {
                        try Task.checkCancellation()
                        let remaining = expectedSize - Int(stream.total_out)
                        guard remaining > 0 else { throw Failure.invalidPackage }
                        stream.avail_out = uInt(min(65_536, remaining))
                        result = inflate(&stream, Z_NO_FLUSH)
                    }
                    return result
                }
            }
            guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize,
                  Int(stream.total_in) == compressed.count else { throw Failure.invalidPackage }
            return output
        }
        private static func crc32(_ data: Data) -> UInt32 {
            var value: UInt32 = 0xffff_ffff
            for byte in data {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
            }
            return value ^ 0xffff_ffff
        }
        private static func validateExtraFields(_ data: Data) throws {
            var cursor = 0
            while cursor < data.count {
                guard cursor <= data.count - 4 else { throw Failure.invalidPackage }
                let identifier = data.u16(cursor), length = Int(data.u16(cursor + 2))
                guard cursor + 4 <= data.count - length,
                      identifier != 0x0001, identifier != 0x000d, identifier != 0x756e else {
                    throw Failure.unsafeFile
                }
                cursor += 4 + length
            }
        }
        private static func kind(path: String, versionMadeBy: UInt16, external: UInt32) throws -> Entry.Kind {
            let slashDirectory = path.hasSuffix("/")
            let dosDirectory = external & 0x10 != 0
            let host = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
            let mode = mode_t(external >> 16), fileType = mode & mode_t(S_IFMT)
            if fileType != 0 {
                guard fileType == S_IFREG || fileType == S_IFDIR else { throw Failure.unsafeFile }
                guard (fileType == S_IFDIR) == slashDirectory else { throw Failure.unsafeFile }
            }
            guard host != 3 && host != 19 || fileType != 0 else { throw Failure.unsafeFile }
            guard !dosDirectory || slashDirectory else { throw Failure.unsafeFile }
            return slashDirectory ? .directory : .file
        }
        private static func validatePath(_ path: String, kind: Entry.Kind) throws {
            guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
                  !path.contains("\\"), !path.contains("\0") else { throw Failure.unsafeFile }
            var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if kind == .directory {
                guard components.last == "" else { throw Failure.unsafeFile }
                components.removeLast()
            }
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.unsafeFile }
        }
        private static func collisionKey(_ path: String, kind: Entry.Kind) -> String {
            let value = kind == .directory ? String(path.dropLast()) : path
            return value.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 |
        UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
