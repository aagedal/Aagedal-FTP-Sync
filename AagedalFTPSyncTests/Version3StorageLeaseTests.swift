import Darwin
import Foundation
import XCTest
@testable import AagedalFTPSync

final class Version3StorageLeaseTests: XCTestCase {
    private typealias Lease = Version3StorageLease
    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("v3-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }
    private func inode(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return UInt64(info.st_ino)
    }

    func testExclusiveLifetimeReleaseAndPersistentLockIdentity() throws {
        try fixture { root in
            let lock = root.appendingPathComponent(Lease.lockName)
            let contents = Data("existing lock contents are not store state".utf8)
            try contents.write(to: lock)
            let originalInode = try inode(lock)
            var first: Lease? = try Lease.acquire(root: root)
            try first?.validate()
            XCTAssertThrowsError(try Lease.acquire(root: root)) { XCTAssertEqual($0 as? Lease.Failure, .alreadyHeld) }
            XCTAssertEqual(try Data(contentsOf: lock), contents)
            XCTAssertEqual(try inode(lock), originalInode)
            withExtendedLifetime(first) {}
            first = nil
            let next = try Lease.acquire(root: root)
            try next.validate()
            XCTAssertEqual(try inode(lock), originalInode)
            XCTAssertEqual(try Data(contentsOf: lock), contents)
            withExtendedLifetime(next) {}
        }
    }

    func testExceptionScopeReleasesLeaseWithoutRemovingLock() throws {
        enum Stop: Error { case fixture }
        try fixture { root in
            func failingOperation() throws {
                let lease = try Lease.acquire(root: root)
                defer { withExtendedLifetime(lease) {} }
                throw Stop.fixture
            }
            XCTAssertThrowsError(try failingOperation())
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(Lease.lockName).path))
            let lease = try Lease.acquire(root: root)
            try lease.validate()
            withExtendedLifetime(lease) {}
        }
    }

    func testMissingNonDirectoryAndSymlinkedRootsNeverCreateStorage() throws {
        try fixture { root in
            let missing = root.appendingPathComponent("missing")
            XCTAssertThrowsError(try Lease.acquire(root: missing)) { XCTAssertEqual($0 as? Lease.Failure, .unsafeRoot) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            let regular = root.appendingPathComponent("file")
            try Data().write(to: regular)
            XCTAssertThrowsError(try Lease.acquire(root: regular))
            let nested = root.appendingPathComponent("actual/nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("actual"))
            XCTAssertThrowsError(try Lease.acquire(root: alias.appendingPathComponent("nested")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent(Lease.lockName).path))
            XCTAssertThrowsError(try Lease.acquire(root: URL(string: "https://example.invalid/storage")!))
        }
    }

    func testSymlinkHardlinkDirectoryAndFIFOLeaseFilesAreRejected() throws {
        for kind in 0..<4 {
            try fixture { root in
                let target = root.appendingPathComponent("target")
                try Data("untouched".utf8).write(to: target)
                let lock = root.appendingPathComponent(Lease.lockName)
                if kind == 0 { try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target) }
                if kind == 1 { XCTAssertEqual(Darwin.link(target.path, lock.path), 0) }
                if kind == 2 { try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false) }
                if kind == 3 { XCTAssertEqual(mkfifo(lock.path, 0o600), 0) }
                XCTAssertThrowsError(try Lease.acquire(root: root))
                XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
            }
        }
    }

    func testLeaseDetectsObservedLockReplacementWithoutRemovingEitherFile() throws {
        try fixture { root in
            let lease = try Lease.acquire(root: root)
            defer { withExtendedLifetime(lease) {} }
            let lock = root.appendingPathComponent(Lease.lockName)
            let retained = root.appendingPathComponent("retained-lock")
            try FileManager.default.moveItem(at: lock, to: retained)
            try Data("replacement".utf8).write(to: lock)
            XCTAssertThrowsError(try lease.validate()) { XCTAssertEqual($0 as? Lease.Failure, .identityChanged) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
            XCTAssertEqual(try Data(contentsOf: lock), Data("replacement".utf8))
        }
    }

    func testLeaseDetectsObservedRootReplacementAndAdditionalHardlink() throws {
        try fixture { outer in
            let root = outer.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let lease = try Lease.acquire(root: root)
            defer { withExtendedLifetime(lease) {} }
            try FileManager.default.moveItem(at: root, to: outer.appendingPathComponent("retained-root"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            XCTAssertThrowsError(try lease.validate()) { XCTAssertEqual($0 as? Lease.Failure, .identityChanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(Lease.lockName).path))
        }
        try fixture { root in
            let lease = try Lease.acquire(root: root)
            defer { withExtendedLifetime(lease) {} }
            XCTAssertEqual(Darwin.link(root.appendingPathComponent(Lease.lockName).path, root.appendingPathComponent("hardlink").path), 0)
            XCTAssertThrowsError(try lease.validate()) { XCTAssertEqual($0 as? Lease.Failure, .unsafeLock) }
        }
    }
}
