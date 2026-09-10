import Darwin
import Foundation

/// Prepares locations supplied by a trusted bootstrap (for example Foundation's
/// sandbox-aware Application Support and temporary directory). Canonicalizing a
/// trusted system-parent alias is deliberate; this API must not receive paths
/// selected from imported configurations or other untrusted documents.
struct Version3StartupPaths: Sendable {
    let root: URL
    let temporaryDirectory: URL

    enum Failure: Error { case invalidURL, unsafeDirectory, changed, fileSystem(Int32) }

    /// Creates only the final root component and a fresh private temporary child.
    /// Existing roots/parents are never replaced, chmodded, or cleaned. The caller
    /// owns temporary cleanup after every converter/SQLite handle has closed.
    static func prepare(root requestedRoot: URL, temporaryParent: URL) throws -> Self {
        try validate(requestedRoot)
        guard requestedRoot.path != "/" else { throw Failure.invalidURL }
        let name = requestedRoot.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw Failure.invalidURL }
        let parent = try canonicalDirectory(requestedRoot.deletingLastPathComponent())
        let temporaryParent = try canonicalDirectory(temporaryParent)
        let root = try childDirectory(parent: parent, name: name, mustBeNew: false)
        let temporary = try childDirectory(parent: temporaryParent,
            name: "aagedal-v3-startup-\(UUID().uuidString)", mustBeNew: true)
        return Self(root: root, temporaryDirectory: temporary)
    }

    /// realpath provides the physical path spelling needed by no-follow admission.
    /// Foundation's resolvingSymlinksInPath may retain a system alias on macOS.
    /// The final component must itself be a directory, never a symlink.
    static func canonicalDirectory(_ requested: URL) throws -> URL {
        try validate(requested)
        var before = stat()
        guard lstat(requested.path, &before) == 0 else { throw Failure.fileSystem(errno) }
        guard before.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeDirectory }
        guard let path = realpath(requested.path, nil) else { throw Failure.fileSystem(errno) }
        defer { free(path) }
        let resolved = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw Failure.fileSystem(errno) }
        guard after.st_mode & S_IFMT == S_IFDIR, before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw Failure.changed
        }
        return resolved
    }

    private static func childDirectory(parent: URL, name: String, mustBeNew: Bool) throws -> URL {
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.fileSystem(errno) }
        defer { Darwin.close(descriptor) }
        if mkdirat(descriptor, name, 0o700) != 0 {
            let code = errno
            guard !mustBeNew, code == EEXIST else { throw Failure.fileSystem(code) }
        } else {
            guard fsync(descriptor) == 0 else { throw Failure.fileSystem(errno) }
        }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw Failure.unsafeDirectory }
        defer { Darwin.close(child) }
        var opened = stat(), named = stat()
        guard fstat(child, &opened) == 0,
              fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.fileSystem(errno) }
        guard opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw Failure.changed }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        let canonical = try canonicalDirectory(url)
        var resolved = stat()
        guard lstat(canonical.path, &resolved) == 0,
              resolved.st_dev == opened.st_dev, resolved.st_ino == opened.st_ino else { throw Failure.changed }
        return canonical
    }

    private static func validate(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              !url.path.utf8.contains(0), !url.pathComponents.contains(".."),
              !url.pathComponents.contains(".") else { throw Failure.invalidURL }
    }
}
