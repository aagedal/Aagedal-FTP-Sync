import CryptoKit
import Darwin
import Foundation

/// Opt-in migration primitive. No production repository uses this yet.
/// The caller MUST stop all related writers, close/checkpoint SQLite, enumerate the
/// complete related file set (including backups), and keep it quiescent until return.
/// Root and ancestor directories must be trusted and stable for the operation.
/// Stable symlinks are rejected; this helper does not defend against an attacker
/// swapping ancestor directories between filesystem calls. Re-reading files
/// detects many races; it cannot establish a cross-store transaction.
struct VersionedAppStorage {
    struct Plan {
        /// Relative regular-file paths; absent legacy files are recorded as absent.
        let legacyFiles: [String]
        let maximumFiles: Int
        let maximumBytes: Int

        // Allow 4,096 runtime maps plus fixed stores, retained legacy files and
        // backups. The independent aggregate byte limit remains unchanged.
        init(legacyFiles: [String], maximumFiles: Int = 8_192, maximumBytes: Int = 256 * 1_024 * 1_024) {
            self.legacyFiles = legacyFiles
            self.maximumFiles = maximumFiles
            self.maximumBytes = maximumBytes
        }
    }

    enum Failure: Error, Equatable {
        case invalidPath(String), unsafeFile(String), inputChanged(String)
        case limitExceeded, migrationInProgress, invalidManifest, sqliteNotQuiescent(String)
        case recoveryRequired, committedStorageMissing
        case systemCall(String, Int32)
    }

    enum Checkpoint { case snapshotCaptured, stageValidated, boundaryPrepared, installed }
    typealias Files = [String: Data]
    typealias Validator = (Files) throws -> Void
    /// Pure inventory resolver over the current bytes of initial-manifest stores.
    /// Every returned path is required. The caller owns registry semantics and
    /// complete directory enumeration; undeclared files are not discovered here.
    typealias CurrentStorePaths = (Files) throws -> [String]

    private struct Entry: Codable, Equatable {
        let path: String
        let bytes: Int?
        let sha256: String?
    }
    private struct Manifest: Codable {
        let format: String
        let version: Int
        let migrationID: UUID
        let sources: [Entry]
        let stores: [Entry]
    }
    private struct Boundary: Codable {
        enum State: String, Codable { case prepared, committed }
        let format: String
        let version: Int
        let migrationID: UUID
        let manifestSHA256: String
        let state: State
    }
    private struct Captured {
        let data: Data
        let identity: String
    }

    let root: URL
    private let fileManager = FileManager.default
    private let boundaryName = ".v3-storage-boundary.json"
    private let manifestName = "storage-manifest.json"
    // Two sets of thousands of bounded source/store entries can exceed 1 MiB.
    private let maximumManifestBytes = 32 * 1_024 * 1_024

    /// Returns the v3 root after migration, or validates and opens an existing v3.
    /// `convert` receives original bytes, never file URLs. It must emit explicit
    /// versioned store envelopes. `validate` must enforce schema versions and all
    /// cross-store references and is called again whenever committed storage opens.
    /// For COMMITTED storage, `currentStorePaths` may declare additional required
    /// stores, such as runtime maps registered since migration. Initial stores stay
    /// required; the final validator receives their union. PREPARED validation uses
    /// only the immutable manifest and exact initial hashes, never this resolver.
    /// The caller must hold all writer/registry exclusions around this entire call.
    func openOrMigrate(
        plan: Plan,
        convert: (Files) throws -> Files,
        validate: Validator,
        currentStorePaths: CurrentStorePaths? = nil,
        checkpoint: (Checkpoint) throws -> Void = { _ in }
    ) throws -> URL {
        try withLock {
            if try exists(boundaryName) {
                return try openCommitted(validate: validate, maximumFiles: plan.maximumFiles, maximumBytes: plan.maximumBytes,
                                         currentStorePaths: currentStorePaths)
            }
            // A v3 directory without its boundary is damage, never a reason to
            // overwrite it or load older settings.
            guard try !exists("v3") else { throw Failure.invalidManifest }
            try validatePaths(plan.legacyFiles, maximum: plan.maximumFiles)
            guard plan.maximumBytes > 0 else { throw Failure.limitExceeded }
            try rejectSQLiteCompanions(plan.legacyFiles)
            var captured: [String: Captured] = [:]
            var total = 0
            for path in plan.legacyFiles.sorted() {
                if let value = try read(path, maximumBytes: plan.maximumBytes, allowMissing: true) {
                    total += value.data.count
                    guard total <= plan.maximumBytes else { throw Failure.limitExceeded }
                    captured[path] = value
                }
            }
            try checkpoint(.snapshotCaptured)
            let sourceFiles = captured.mapValues(\.data)
            let stores = try convert(sourceFiles)
            try validatePaths(Array(stores.keys), maximum: plan.maximumFiles)
            guard !stores.isEmpty, stores.keys.allSatisfy({ $0 != manifestName }),
                  stores.values.reduce(0, { $0 + $1.count }) <= plan.maximumBytes else { throw Failure.limitExceeded }
            try validate(stores)
            let id = UUID()
            let archive = archiveName(id)
            try makeDirectory(archive)
            // This separate snapshot remains outside mutable v3/ after install.
            // Failed attempts retain their snapshot for explicit recovery/inspection.
            try makeDirectory(archive + "/legacy")
            try makeDirectory(archive + "/install")
            for (path, data) in sourceFiles { try writeNew(data, path: archive + "/legacy/" + path) }
            for (path, data) in stores { try writeNew(data, path: archive + "/install/" + path) }
            let manifest = Manifest(
                format: "AagedalFTPSync.storage", version: 3, migrationID: id,
                sources: plan.legacyFiles.sorted().map { entry($0, data: sourceFiles[$0]) },
                stores: stores.keys.sorted().map { entry($0, data: stores[$0]) }
            )
            let bytes = try encoder().encode(manifest)
            try writeNew(bytes, path: archive + "/" + manifestName)
            try writeNew(bytes, path: archive + "/install/" + manifestName)
            let boundary = Boundary(format: "AagedalFTPSync.storage-boundary", version: 3,
                                    migrationID: id, manifestSHA256: digest(bytes), state: .prepared)
            _ = try validateInstallation(boundary, installed: false, initial: true,
                                         maximumFiles: plan.maximumFiles, maximumBytes: plan.maximumBytes, validate: validate)
            try checkpoint(.stageValidated)
            // Check presence, inode/timestamps and content after conversion/staging.
            // The caller's writer exclusion, not these checks, guarantees consistency.
            for path in plan.legacyFiles {
                let current = try read(path, maximumBytes: plan.maximumBytes, allowMissing: true)
                guard current?.identity == captured[path]?.identity,
                      current?.data == captured[path]?.data else { throw Failure.inputChanged(path) }
            }
            try rejectSQLiteCompanions(plan.legacyFiles)
            try prepareBoundary(boundary)
            try checkpoint(.boundaryPrepared)
            try install(boundary, checkpoint: checkpoint)
            return root.appendingPathComponent("v3", isDirectory: true)
        }
    }

    /// Explicit recovery finishes only the exact PREPARED snapshot. It never
    /// recopies legacy stores. A missing COMMITTED installation requires v3 backup
    /// recovery by a higher-level UI; initial migration state is not current data.
    func recoverPreparedInstallation(
        maximumFiles: Int = 8_192, maximumBytes: Int = 256 * 1_024 * 1_024,
        validate: Validator, currentStorePaths: CurrentStorePaths? = nil
    ) throws -> URL {
        try withLock {
            let boundary = try readBoundary()
            if try exists("v3") {
                return try openCommitted(validate: validate, maximumFiles: maximumFiles, maximumBytes: maximumBytes,
                                         currentStorePaths: currentStorePaths)
            }
            guard boundary.state == .prepared else { throw Failure.committedStorageMissing }
            _ = try validateInstallation(boundary, installed: false, initial: true,
                                         maximumFiles: maximumFiles, maximumBytes: maximumBytes, validate: validate)
            try install(boundary, checkpoint: { _ in })
            return root.appendingPathComponent("v3", isDirectory: true)
        }
    }

    private func openCommitted(validate: Validator, maximumFiles: Int, maximumBytes: Int,
                               currentStorePaths: CurrentStorePaths?) throws -> URL {
        let boundary = try readBoundary()
        guard try exists("v3") else {
            throw boundary.state == .committed ? Failure.committedStorageMissing : Failure.recoveryRequired
        }
        _ = try validateInstallation(boundary, installed: true, initial: boundary.state == .prepared,
                                     maximumFiles: maximumFiles, maximumBytes: maximumBytes, validate: validate,
                                     currentStorePaths: currentStorePaths)
        if boundary.state == .prepared { try commitBoundary(boundary) }
        return root.appendingPathComponent("v3", isDirectory: true)
    }

    private func validateInstallation(
        _ boundary: Boundary, installed: Bool, initial: Bool,
        maximumFiles: Int, maximumBytes: Int, validate: Validator,
        currentStorePaths: CurrentStorePaths? = nil
    ) throws -> Manifest {
        guard maximumFiles > 0, maximumBytes > 0 else { throw Failure.limitExceeded }
        let archive = archiveName(boundary.migrationID)
        let directory = installed ? "v3" : archive + "/install"
        guard let bytes = try read(directory + "/" + manifestName, maximumBytes: maximumManifestBytes, allowMissing: false)?.data,
              digest(bytes) == boundary.manifestSHA256,
              let snapshotManifest = try read(archive + "/" + manifestName, maximumBytes: maximumManifestBytes, allowMissing: false)?.data,
              snapshotManifest == bytes else { throw Failure.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard manifest.format == "AagedalFTPSync.storage", manifest.version == 3,
              manifest.migrationID == boundary.migrationID, !manifest.stores.isEmpty,
              !manifest.stores.contains(where: { $0.path == manifestName }) else { throw Failure.invalidManifest }
        try validatePaths(manifest.sources.map(\.path), maximum: maximumFiles)
        try validatePaths(manifest.stores.map(\.path), maximum: maximumFiles)
        var total = 0
        for expected in manifest.sources {
            let data = try read(archive + "/legacy/" + expected.path, maximumBytes: maximumBytes, allowMissing: true)?.data
            guard entry(expected.path, data: data) == expected else { throw Failure.invalidManifest }
            total += data?.count ?? 0
            guard total <= maximumBytes else { throw Failure.limitExceeded }
        }
        total = 0
        var stores: Files = [:]
        var capturedStores: [String: Captured] = [:]
        for expected in manifest.stores {
            guard let captured = try read(directory + "/" + expected.path, maximumBytes: maximumBytes, allowMissing: false),
                  expected.bytes != nil, expected.sha256 != nil else { throw Failure.invalidManifest }
            let data = captured.data
            if initial, entry(expected.path, data: data) != expected { throw Failure.invalidManifest }
            total += data.count
            guard total <= maximumBytes else { throw Failure.limitExceeded }
            stores[expected.path] = data
            capturedStores[expected.path] = captured
        }
        if !initial, let currentStorePaths {
            let declared = try currentStorePaths(stores)
            try validatePaths(declared, maximum: maximumFiles)
            guard !declared.contains(manifestName) else { throw Failure.invalidManifest }
            let combined = Set(stores.keys).union(declared).sorted()
            try validatePaths(combined, maximum: maximumFiles)
            try rejectSQLiteCompanions(combined.map { directory + "/" + $0 })
            for path in combined where stores[path] == nil {
                guard let captured = try read(directory + "/" + path, maximumBytes: maximumBytes, allowMissing: false) else {
                    throw Failure.unsafeFile(path)
                }
                guard captured.data.count <= maximumBytes - total else { throw Failure.limitExceeded }
                total += captured.data.count
                stores[path] = captured.data
                capturedStores[path] = captured
            }
            // The resolver must be pure and writers excluded. Rechecks additionally
            // catch observed replacement/removal of a registry or map during the
            // collection, but cannot establish an uncoordinated cross-store snapshot.
            for path in combined {
                let current = try read(directory + "/" + path, maximumBytes: maximumBytes, allowMissing: false)
                guard current?.identity == capturedStores[path]?.identity,
                      current?.data == capturedStores[path]?.data else { throw Failure.inputChanged(path) }
            }
            try rejectSQLiteCompanions(combined.map { directory + "/" + $0 })
        }
        try validate(stores)
        return manifest
    }

    private func readBoundary() throws -> Boundary {
        guard let data = try read(boundaryName, maximumBytes: 16_384, allowMissing: false)?.data else { throw Failure.invalidManifest }
        let value = try JSONDecoder().decode(Boundary.self, from: data)
        guard value.format == "AagedalFTPSync.storage-boundary", value.version == 3,
              value.manifestSHA256.count == 64 else { throw Failure.invalidManifest }
        return value
    }

    private func install(_ boundary: Boundary, checkpoint: (Checkpoint) throws -> Void) throws {
        let source = root.appendingPathComponent(archiveName(boundary.migrationID) + "/install")
        let target = root.appendingPathComponent("v3")
        // renamex_np with RENAME_EXCL cannot replace a concurrently created target.
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure.systemCall("install", errno)
        }
        try syncDirectory(source.deletingLastPathComponent())
        try syncDirectory(root)
        try checkpoint(.installed)
        try commitBoundary(boundary)
    }

    private func prepareBoundary(_ value: Boundary) throws {
        let name = ".v3-boundary-" + UUID().uuidString + ".tmp"
        try writeNew(try encoder().encode(value), path: name)
        guard renamex_np(root.appendingPathComponent(name).path,
                         root.appendingPathComponent(boundaryName).path, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure.systemCall("prepare boundary", errno)
        }
        try syncDirectory(root)
    }

    private func commitBoundary(_ value: Boundary) throws {
        let committed = Boundary(format: value.format, version: value.version, migrationID: value.migrationID,
                                 manifestSHA256: value.manifestSHA256, state: .committed)
        let name = ".v3-boundary-" + UUID().uuidString + ".tmp"
        try writeNew(try encoder().encode(committed), path: name)
        guard rename(root.appendingPathComponent(name).path, root.appendingPathComponent(boundaryName).path) == 0 else {
            throw Failure.systemCall("commit boundary", errno)
        }
        try syncDirectory(root)
    }

    private func withLock<T>(_ action: () throws -> T) throws -> T {
        // Reject symlinked roots and ancestors, not just the final directory.
        guard root.isFileURL, root.path.hasPrefix("/"),
              !root.pathComponents.contains("."), !root.pathComponents.contains("..") else { throw Failure.invalidPath(root.path) }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw Failure.unsafeFile(current.path)
            }
        }
        let fd = Darwin.open(root.appendingPathComponent(".v3-migration.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.systemCall("open migration lock", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafeFile("migration lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.migrationInProgress }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }

    private func rejectSQLiteCompanions(_ paths: [String]) throws {
        for path in paths where path.hasSuffix(".sqlite3") || path.hasSuffix(".sqlite") || path.hasSuffix(".db") {
            for suffix in ["-wal", "-shm", "-journal"] where try exists(path + suffix) {
                throw Failure.sqliteNotQuiescent(path)
            }
        }
    }

    private func validatePaths(_ paths: [String], maximum: Int) throws {
        guard maximum > 0, paths.count <= maximum, Set(paths).count == paths.count else { throw Failure.limitExceeded }
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, path.utf8.count <= 1_024, components.count <= 16,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
                  !path.hasPrefix("/"), !path.contains("\\") else { throw Failure.invalidPath(path) }
        }
        // A file cannot also be another file's parent.
        let set = Set(paths)
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !set.contains(parent) else { throw Failure.invalidPath(path) }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    /// Each path component is opened without following links. fstat before/after
    /// detects replacement or mutation during a read; hard links are also refused.
    private func read(_ path: String, maximumBytes: Int, allowMissing: Bool) throws -> Captured? {
        try validatePaths([path], maximum: 1)
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.systemCall("open root", errno) }
        defer { close(fd) }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let isFile = index == components.count - 1
            let next = openat(fd, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isFile ? O_NONBLOCK : O_DIRECTORY))
            if next < 0 {
                if allowMissing && errno == ENOENT { return nil }
                throw Failure.unsafeFile(path)
            }
            close(fd)
            fd = next
        }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1 else { throw Failure.unsafeFile(path) }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw Failure.limitExceeded }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.systemCall("read", errno)
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else { throw Failure.limitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, identity(before) == identity(after), data.count == before.st_size else { throw Failure.inputChanged(path) }
        return Captured(data: data, identity: identity(after))
    }

    private func exists(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(root.appendingPathComponent(path).path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.systemCall("inspect", errno) }
        return false
    }

    private func makeDirectory(_ path: String) throws {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func writeNew(_ data: Data, path: String) throws {
        let parts = path.split(separator: "/").map(String.init)
        var parent = ""
        for part in parts.dropLast() {
            parent = parent.isEmpty ? part : parent + "/" + part
            if try !exists(parent) { try makeDirectory(parent) }
            var info = stat()
            guard lstat(root.appendingPathComponent(parent).path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafeFile(parent) }
        }
        let url = root.appendingPathComponent(path)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.systemCall("create", errno) }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.systemCall("write", errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.systemCall("sync file", errno) }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.systemCall("open directory", errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.systemCall("sync directory", errno) }
    }
    private func identity(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    private func archiveName(_ id: UUID) -> String { ".v3-migration-" + id.uuidString }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func entry(_ path: String, data: Data?) -> Entry { Entry(path: path, bytes: data?.count, sha256: data.map(digest)) }
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
