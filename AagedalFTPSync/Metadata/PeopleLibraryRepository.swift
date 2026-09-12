import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Retained by an operation: replacing/removing the current selection never
/// invalidates its decoded vectors or deletes its immutable reference files.
struct PeopleLibrarySnapshot: Sendable {
    let manifest: PeopleLibraryManifest
    let gallery: FaceRecognitionGallery
    let directoryURL: URL
}

struct PeopleLibraryRepository: Sendable {
    enum Failure: Error, Equatable {
        case unsafeFile, invalidDirectory, unexpectedFiles, sizeLimit, hashMismatch
        case invalidThumbnail, invalidPointer, revisionCollision, selectionChanged, busy, io
    }

    let root: URL
    private let limits: PeopleLibraryManifest.Limits
    private let beforeActivate: @Sendable () throws -> Void
    private static let pointerName = "current.json"

    init(root: URL, limits: PeopleLibraryManifest.Limits = .init(),
         beforeActivate: @escaping @Sendable () throws -> Void = {}) {
        self.root = root
        self.limits = limits
        self.beforeActivate = beforeActivate
    }

    /// The parent of this app-owned root must already exist. Input is an already
    /// unpacked, self-contained directory; this API never extracts ZIP archives.
    func importSnapshot(from source: URL) throws -> PeopleLibrarySnapshot {
        let rootFD = try Self.openRoot(root, create: true)
        defer { close(rootFD) }
        let expected = try readPointer(rootFD)
        let sourceFD = try Self.openDirectory(source.path)
        defer { close(sourceFD) }
        let manifestBytes = try Self.readFile(sourceFD, path: PeopleLibraryManifest.fileName, maximum: limits.maximumManifestBytes)
        let manifest = try PeopleLibraryManifest.decode(manifestBytes, limits: limits)
        try manifest.validate(limits: limits)
        let expectedFiles = Set(manifest.files.map(\.path)).union([PeopleLibraryManifest.fileName])
        guard try Self.enumerate(sourceFD, maximum: limits.maximumFiles + 1) == expectedFiles else { throw Failure.unexpectedFiles }
        let stageName = ".staging-" + UUID().uuidString.lowercased()
        guard mkdirat(rootFD, stageName, S_IRWXU) == 0 else { throw Failure.io }
        let stageFD = try Self.openChildDirectory(rootFD, stageName)
        var transferred = false
        defer {
            if !transferred { Self.cleanStage(rootFD: rootFD, name: stageName, stageFD: stageFD, paths: expectedFiles) }
            close(stageFD)
        }
        try Self.writeFile(stageFD, path: PeopleLibraryManifest.fileName, data: manifestBytes)
        for file in manifest.files {
            try Task.checkCancellation()
            let bytes = try Self.readFile(sourceFD, path: file.path, maximum: file.byteCount)
            guard bytes.count == file.byteCount else { throw Failure.sizeLimit }
            guard Self.digest(bytes) == file.sha256 else { throw Failure.hashMismatch }
            if file.path.hasSuffix(".jpg") { try Self.validateThumbnail(bytes) }
            try Self.writeFile(stageFD, path: file.path, data: bytes)
        }
        // Read only the captured copy from here onward: subsequent source changes
        // cannot mix gallery values with a different selected snapshot.
        let captured = try loadSnapshot(stageFD, directory: root.appendingPathComponent(stageName))
        let lock = try Self.lock(rootFD)
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        guard try readPointer(rootFD) == expected else { throw Failure.selectionChanged }
        let destinationName = Self.snapshotName(manifest.libraryID, manifest.revision)
        let destinationURL = root.appendingPathComponent(destinationName, isDirectory: true)
        let snapshot: PeopleLibrarySnapshot
        if Self.entryExists(rootFD, destinationName) {
            let existingFD = try Self.openChildDirectory(rootFD, destinationName)
            defer { close(existingFD) }
            let existing = try loadSnapshot(existingFD, directory: destinationURL)
            // Export time is deliberately outside revision identity. Equivalent
            // re-exports may reuse a verified snapshot; different bytes never do.
            guard existing.manifest.libraryID == manifest.libraryID, existing.manifest.revision == manifest.revision,
                  existing.manifest.files.sorted(by: { $0.path < $1.path }) == manifest.files.sorted(by: { $0.path < $1.path }),
                  existing.manifest.peopleCount == manifest.peopleCount,
                  existing.manifest.embeddingCount == manifest.embeddingCount else { throw Failure.revisionCollision }
            for file in manifest.files {
                guard try Self.readFile(existingFD, path: file.path, maximum: file.byteCount)
                    == Self.readFile(stageFD, path: file.path, maximum: file.byteCount) else { throw Failure.revisionCollision }
            }
            snapshot = existing
        } else {
            try Self.seal(stageFD, paths: expectedFiles)
            guard renameatx_np(rootFD, stageName, rootFD, destinationName, UInt32(RENAME_EXCL)) == 0 else { throw Failure.io }
            transferred = true
            guard fsync(rootFD) == 0 else { throw Failure.io }
            snapshot = PeopleLibrarySnapshot(manifest: captured.manifest, gallery: captured.gallery, directoryURL: destinationURL)
        }
        try Task.checkCancellation()
        try beforeActivate()
        let pointer = Pointer(selectionID: UUID(), libraryID: manifest.libraryID, revision: manifest.revision)
        try Self.writePointer(pointer, rootFD: rootFD)
        return snapshot
    }

    func currentSnapshot() throws -> PeopleLibrarySnapshot? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let rootFD = try Self.openRoot(root, create: false)
        defer { close(rootFD) }
        guard let pointer = try readPointer(rootFD), let libraryID = pointer.libraryID,
              let revision = pointer.revision else { return nil }
        let directoryName = Self.snapshotName(libraryID, revision)
        let directoryFD = try Self.openChildDirectory(rootFD, directoryName)
        defer { close(directoryFD) }
        let snapshot = try loadSnapshot(directoryFD, directory: root.appendingPathComponent(directoryName, isDirectory: true))
        guard snapshot.manifest.libraryID == libraryID, snapshot.manifest.revision == revision else { throw Failure.invalidPointer }
        return snapshot
    }

    /// Revalidates one unpacked immutable package without reading or changing the
    /// repository's current selection. Export uses this before copying private data.
    func validateSnapshot(at directory: URL) throws -> PeopleLibrarySnapshot {
        let descriptor = try Self.openDirectory(directory.path)
        defer { close(descriptor) }
        return try loadSnapshot(descriptor, directory: directory)
    }

    func removeCurrentSnapshot() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let rootFD = try Self.openRoot(root, create: false)
        defer { close(rootFD) }
        let expected = try readPointer(rootFD)
        let lock = try Self.lock(rootFD)
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        guard try readPointer(rootFD) == expected else { throw Failure.selectionChanged }
        // Retain a new generation even when deselected. Unlinking would allow a
        // nil -> selected -> nil ABA and let an older staged import activate.
        try Self.writePointer(.deselected(), rootFD: rootFD)
    }

    private func loadSnapshot(_ fd: Int32, directory: URL) throws -> PeopleLibrarySnapshot {
        let bytes = try Self.readFile(fd, path: PeopleLibraryManifest.fileName, maximum: limits.maximumManifestBytes)
        let manifest = try PeopleLibraryManifest.decode(bytes, limits: limits)
        try manifest.validate(limits: limits)
        guard try Self.enumerate(fd, maximum: limits.maximumFiles + 1)
            == Set(manifest.files.map(\.path)).union([PeopleLibraryManifest.fileName]) else { throw Failure.unexpectedFiles }
        let declarations = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        for file in manifest.files {
            try Task.checkCancellation()
            _ = try Self.verifiedFile(fd, declaration: file)
        }
        guard let payloadDeclaration = declarations[PeopleLibraryManifest.payloadFileName] else { throw Failure.unexpectedFiles }
        let payload = try PeopleLibraryPayload.decode(
            Self.verifiedFile(fd, declaration: payloadDeclaration), limits: limits)
        try manifest.validate(payload: payload, limits: limits)
        if let editorPayload = manifest.editorPayload {
            guard let declaration = declarations[editorPayload.path] else { throw Failure.unexpectedFiles }
            _ = try PeopleLibraryEditorPayload.decode(
                Self.verifiedFile(fd, declaration: declaration),
                manifest: manifest,
                payload: payload,
                limits: limits
            )
        }
        var people: [FaceRecognitionPerson] = []
        for person in payload.people {
            try Task.checkCancellation()
            let examples = try person.examples.map { example in
                try Task.checkCancellation()
                guard let declaration = declarations[example.embeddingPath] else { throw Failure.unexpectedFiles }
                return try FaceRecognitionEmbeddingCodec.decode(Self.verifiedFile(fd, declaration: declaration))
            }
            people.append(try FaceRecognitionPerson(id: person.id, name: person.name, examples: examples))
        }
        return PeopleLibrarySnapshot(manifest: manifest, gallery: try FaceRecognitionGallery(people: people), directoryURL: directory)
    }

    private struct Pointer: Codable, Equatable {
        let selectionID: UUID
        let libraryID: UUID?
        let revision: String?
        private enum CodingKeys: String, CodingKey { case schemaVersion, selectionID, libraryID, revision }
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(selectionID: UUID, libraryID: UUID, revision: String) {
            self.selectionID = selectionID; self.libraryID = libraryID; self.revision = revision
        }
        static func deselected() -> Self {
            Self(selectionID: UUID(), libraryID: nil, revision: nil)
        }
        private init(selectionID: UUID, libraryID: UUID?, revision: String?) {
            self.selectionID = selectionID; self.libraryID = libraryID; self.revision = revision
        }
        init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: Key.self)
            let keys = Set(all.allKeys.map(\.stringValue))
            guard Set(["schemaVersion", "selectionID"]).isSubset(of: keys),
                  keys.isSubset(of: ["schemaVersion", "selectionID", "libraryID", "revision"]) else { throw Failure.invalidPointer }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw Failure.invalidPointer }
            selectionID = try values.decode(UUID.self, forKey: .selectionID)
            let hasLibrary = values.contains(.libraryID), hasRevision = values.contains(.revision)
            guard hasLibrary == hasRevision else { throw Failure.invalidPointer }
            if hasLibrary {
                libraryID = try values.decode(UUID.self, forKey: .libraryID)
                revision = try values.decode(String.self, forKey: .revision)
            } else {
                libraryID = nil; revision = nil
            }
            if let revision {
                guard revision.utf8.count == 64, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidPointer }
            }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(1, forKey: .schemaVersion)
            try values.encode(selectionID, forKey: .selectionID)
            try values.encodeIfPresent(libraryID, forKey: .libraryID)
            try values.encodeIfPresent(revision, forKey: .revision)
        }
    }

    private func readPointer(_ rootFD: Int32) throws -> Pointer? {
        guard Self.entryExists(rootFD, Self.pointerName) else { return nil }
        let data = try Self.readFile(rootFD, path: Self.pointerName, maximum: 4096)
        try PeopleLibraryManifest.validateJSONStructure(data)
        return try JSONDecoder().decode(Pointer.self, from: data)
    }
    private static func snapshotName(_ libraryID: UUID, _ revision: String) -> String { "snapshot-" + libraryID.uuidString.lowercased() + "-" + revision }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func verifiedFile(_ parent: Int32, declaration: PeopleLibraryManifest.FileDeclaration) throws -> Data {
        let data = try readFile(parent, path: declaration.path, maximum: declaration.byteCount)
        guard data.count == declaration.byteCount else { throw Failure.sizeLimit }
        guard digest(data) == declaration.sha256 else { throw Failure.hashMismatch }
        if declaration.path.hasSuffix(".jpg") { try validateThumbnail(data) }
        return data
    }

    private static func openRoot(_ url: URL, create: Bool) throws -> Int32 {
        if create, mkdir(url.path, S_IRWXU) != 0, errno != EEXIST { throw Failure.io }
        let fd = try openDirectory(url.path)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { close(fd); throw Failure.unsafeFile }
        return fd
    }
    private static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.invalidDirectory }
        return fd
    }
    private static func openChildDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.invalidDirectory }
        return fd
    }
    private static func entryExists(_ parent: Int32, _ name: String) -> Bool {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }
    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure.unsafeFile }
        return parts
    }
    private static func readFile(_ parent: Int32, path: String, maximum: Int) throws -> Data {
        let parts = try components(path)
        let directory = parts.count == 2 ? try openChildDirectory(parent, parts[0]) : dup(parent)
        guard directory >= 0 else { throw Failure.io }
        defer { close(directory) }
        let fd = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximum else { throw Failure.unsafeFile }
        var bytes = Data(count: Int(before.st_size))
        let expected = bytes.count
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < expected {
                let count = read(fd, buffer.baseAddress!.advanced(by: offset), expected - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.unsafeFile }
        return bytes
    }
    private static func writeFile(_ parent: Int32, path: String, data: Data) throws {
        let parts = try components(path)
        if parts.count == 2, mkdirat(parent, parts[0], S_IRWXU) != 0, errno != EEXIST { throw Failure.io }
        let directory = parts.count == 2 ? try openChildDirectory(parent, parts[0]) : dup(parent)
        guard directory >= 0 else { throw Failure.io }
        defer { close(directory) }
        let fd = openat(directory, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard fsync(fd) == 0, fchmod(fd, S_IRUSR) == 0, fsync(directory) == 0 else { throw Failure.io }
    }
    private static func enumerate(_ fd: Int32, maximum: Int, prefix: String = "") throws -> Set<String> {
        let copy = dup(fd)
        guard copy >= 0 else { throw Failure.io }
        guard let stream = fdopendir(copy) else { close(copy); throw Failure.io }
        defer { closedir(stream) }
        var result: Set<String> = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw Failure.unsafeFile }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard prefix.isEmpty, ["embeddings", "thumbnails", "embedding_thumbnails", "editor"].contains(name) else { throw Failure.unexpectedFiles }
                let child = try openChildDirectory(fd, name)
                defer { close(child) }
                let nested = try enumerate(child, maximum: maximum - result.count, prefix: name + "/")
                guard !nested.isEmpty else { throw Failure.unexpectedFiles }
                result.formUnion(nested)
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafeFile }
                result.insert(prefix + name)
            }
            guard result.count <= maximum else { throw Failure.sizeLimit }
        }
        return result
    }
    private static func validateThumbnail(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_777_216,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil else { throw Failure.invalidThumbnail }
    }
    private static func lock(_ root: Int32) throws -> Int32 {
        let fd = openat(root, ".selection-lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { close(fd); throw Failure.unsafeFile }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
        return fd
    }
    private static func seal(_ fd: Int32, paths: Set<String>) throws {
        for directory in Set(paths.compactMap { path -> String? in path.contains("/") ? path.components(separatedBy: "/").first : nil }) {
            let child = try openChildDirectory(fd, directory)
            defer { close(child) }
            guard fchmod(child, S_IRUSR | S_IXUSR) == 0, fsync(child) == 0 else { throw Failure.io }
        }
        guard fchmod(fd, S_IRUSR | S_IXUSR) == 0, fsync(fd) == 0 else { throw Failure.io }
    }
    private static func cleanStage(rootFD: Int32, name: String, stageFD: Int32, paths: Set<String>) {
        // Delete only this call's known staged paths. Never traverse unknown dirs.
        _ = fchmod(stageFD, S_IRWXU)
        for path in paths {
            guard let parts = try? components(path) else { continue }
            if parts.count == 2, let child = try? openChildDirectory(stageFD, parts[0]) {
                _ = fchmod(child, S_IRWXU); _ = unlinkat(child, parts[1], 0); close(child)
            } else if parts.count == 1 { _ = unlinkat(stageFD, parts[0], 0) }
        }
        for directory in Set(paths.compactMap { $0.contains("/") ? $0.components(separatedBy: "/").first : nil }) {
            _ = unlinkat(stageFD, directory, AT_REMOVEDIR)
        }
        var current = stat(), held = stat()
        if fstatat(rootFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0, fstat(stageFD, &held) == 0,
           current.st_dev == held.st_dev, current.st_ino == held.st_ino { _ = unlinkat(rootFD, name, AT_REMOVEDIR) }
    }
    private static func writePointer(_ pointer: Pointer, rootFD: Int32) throws {
        let name = ".current-" + UUID().uuidString.lowercased()
        let data = try JSONEncoder().encode(pointer)
        try writeFile(rootFD, path: name, data: data)
        defer { _ = unlinkat(rootFD, name, 0) }
        guard renameat(rootFD, name, rootFD, pointerName) == 0 else { throw Failure.io }
        guard fsync(rootFD) == 0 else { throw Failure.io }
    }
}
