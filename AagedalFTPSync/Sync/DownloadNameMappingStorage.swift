import Darwin
import Foundation

/// Versioned mapping receipts are initialized only by an explicit provisioning or
/// migration decision. Absence cannot distinguish a new destination from lost
/// committed history; ordinary naming sessions must never initialize a v3 map.
enum DownloadNameMappingStorage {
    struct Version3State: Codable {
        let mappingID: String
        let names: [String: String]
        let newestDates: [String: Date]
    }

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    enum StorageError: Error {
        case unsafePath, alreadyExists, changedDuringSession, invalidIdentity, invalidReplacementDates
        case fileSystem(Int32)
    }

    static func identity(at url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { throw VersionedStoreCodec.HeaderError.missingStore }
            throw StorageError.fileSystem(errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw StorageError.unsafePath }
        return Identity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                        changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    /// The caller must establish that this mapping identity is genuinely new, then
    /// durably register it before enabling transfers. This API does not infer that
    /// authorization from filesystem absence. The future lifecycle registry owns
    /// that decision; SyncEngine deliberately never calls this initializer.
    /// Parent directories must already exist, be trusted/stable and nonsymlinked.
    /// Publication is exclusive and atomic, so interruption cannot expose partial
    /// JSON or overwrite a previously committed map. A post-publication fsync error
    /// may leave the complete map; retry will refuse to replace it.
    static func initializeNewVersion3Mapping(at url: URL, overwriteCaseVariants: Bool) throws {
        try validateNewDestination(url)
        let codec = VersionedStoreCodec(format: .version3,
                                       store: overwriteCaseVariants ? .downloadReplacementNames : .downloadNames)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try codec.encode(Version3State(mappingID: url.lastPathComponent, names: [:], newestDates: [:]), encoder: encoder)
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".download-name-initialization-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StorageError.fileSystem(errno) }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StorageError.fileSystem(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw StorageError.fileSystem(errno) }
        try validateNewDestination(url)
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw StorageError.alreadyExists }
            throw StorageError.fileSystem(errno)
        }
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw StorageError.fileSystem(errno) }
        defer { Darwin.close(parentFD) }
        guard fsync(parentFD) == 0 else { throw StorageError.fileSystem(errno) }
    }

    private static func validateNewDestination(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0),
              url.path == url.standardizedFileURL.path, url.lastPathComponent != "/",
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw StorageError.unsafePath }
        var parent = url.deletingLastPathComponent()
        while true {
            var info = stat()
            guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw StorageError.unsafePath }
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
        var info = stat()
        if lstat(url.path, &info) == 0 { throw StorageError.alreadyExists }
        guard errno == ENOENT else { throw StorageError.fileSystem(errno) }
    }
}
