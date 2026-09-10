import Darwin
import Foundation

/// Lifetime exclusion for cooperating v3 processes sharing one existing root.
/// This does not exclude older app versions, unrelated repository writers, or
/// noncooperating processes. The caller must establish that separate exclusion
/// before migration, and retain this lease until every related writer/handle is
/// closed. No production startup path acquires a lease automatically.
///
/// Root/ancestor directories must remain trusted and stable. All cooperating
/// processes must use this persistent lock name and must never unlink/replace it.
/// Identity checks detect observed path replacement; they do not defend against
/// an attacker replacing directories or lock files between filesystem calls.
final class Version3StorageLease: Sendable {
    static let lockName = ".v3-runtime.lock"

    enum Failure: Error, Equatable {
        case unsafeRoot, unsafeLock, alreadyHeld, identityChanged
        case systemCall(String, Int32)
    }
    private struct Identity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }
    private let root: URL
    private let rootDescriptor: Int32
    private let lockDescriptor: Int32
    private let rootIdentity: Identity
    private let lockIdentity: Identity

    private init(root: URL, rootDescriptor: Int32, lockDescriptor: Int32,
                 rootIdentity: Identity, lockIdentity: Identity) {
        self.root = root
        self.rootDescriptor = rootDescriptor
        self.lockDescriptor = lockDescriptor
        self.rootIdentity = rootIdentity
        self.lockIdentity = lockIdentity
    }

    /// Acquires immediately or fails; never waits, creates the root, removes a
    /// lock file, truncates existing contents, or changes existing permissions.
    /// The descriptor has close-on-exec. Keep the returned object alive for the
    /// entire writer lifetime, not merely the duration of migration/validation.
    static func acquire(root: URL) throws -> Version3StorageLease {
        let rootDescriptor = try openRoot(root)
        var transferred = false
        defer { if !transferred { Darwin.close(rootDescriptor) } }
        let rootInfo = try directoryInfo(rootDescriptor)
        let lockDescriptor = openat(rootDescriptor, lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockDescriptor >= 0 else {
            if errno == ELOOP { throw Failure.unsafeLock }
            throw Failure.systemCall("open lease", errno)
        }
        defer { if !transferred { Darwin.close(lockDescriptor) } }
        let lockInfo = try regularInfo(lockDescriptor)
        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.alreadyHeld }
            throw Failure.systemCall("acquire lease", code)
        }
        let lease = Version3StorageLease(root: root, rootDescriptor: rootDescriptor, lockDescriptor: lockDescriptor,
            rootIdentity: Identity(rootInfo), lockIdentity: Identity(lockInfo))
        // The object now owns both descriptors even if validation below throws.
        transferred = true
        try lease.validate()
        return lease
    }

    /// Rechecks descriptor/path identity while retaining the lock. This is useful
    /// at migration boundaries; it is not a substitute for stable directories or
    /// a way to establish exclusion of processes that do not honor this lease.
    func validate() throws {
        let rootInfo = try Self.directoryInfo(rootDescriptor)
        guard Identity(rootInfo) == rootIdentity else { throw Failure.identityChanged }
        let reopenedRoot = try Self.openRoot(root)
        defer { Darwin.close(reopenedRoot) }
        guard Identity(try Self.directoryInfo(reopenedRoot)) == rootIdentity else { throw Failure.identityChanged }
        let lockInfo = try Self.regularInfo(lockDescriptor)
        var named = stat()
        guard fstatat(reopenedRoot, Self.lockName, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw Failure.identityChanged }
            throw Failure.systemCall("inspect lease path", errno)
        }
        guard named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 else { throw Failure.unsafeLock }
        guard Identity(lockInfo) == lockIdentity, Identity(named) == lockIdentity else { throw Failure.identityChanged }
    }

    deinit {
        // Never unlink: a waiting/contending process must keep addressing the
        // same inode after this lifetime ends. Close also releases the flock.
        _ = flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        Darwin.close(rootDescriptor)
    }

    private static func regularInfo(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.systemCall("inspect lease", errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafeLock }
        return info
    }
    private static func directoryInfo(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.systemCall("inspect lease root", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeRoot }
        return info
    }
    private static func openRoot(_ root: URL) throws -> Int32 {
        guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost",
              root.query == nil, root.fragment == nil, root.path.hasPrefix("/"),
              !root.path.utf8.contains(0), !root.pathComponents.contains(".."), !root.pathComponents.contains(".") else {
            throw Failure.unsafeRoot
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.systemCall("open filesystem root", errno) }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        for component in root.pathComponents where component != "/" {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.unsafeRoot }
            Darwin.close(descriptor)
            descriptor = next
        }
        _ = try directoryInfo(descriptor)
        transferred = true
        return descriptor
    }
}
