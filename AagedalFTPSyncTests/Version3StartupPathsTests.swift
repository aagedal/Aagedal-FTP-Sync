import Darwin
import Foundation
import XCTest
@testable import AagedalFTPSync

final class Version3StartupPathsTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("startup-paths-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCreatesPrivateLocationsReusesRootAndWorksWithLeaseAndMigration() throws {
        let parent = try fixture()
        let first = try Version3StartupPaths.prepare(root: parent.appendingPathComponent("profile"), temporaryParent: parent)
        let marker = first.root.appendingPathComponent("marker")
        try Data("preserved".utf8).write(to: marker)
        let second = try Version3StartupPaths.prepare(root: first.root, temporaryParent: parent)
        XCTAssertEqual(first.root, second.root)
        XCTAssertNotEqual(first.temporaryDirectory, second.temporaryDirectory)
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserved".utf8))
        var info = stat()
        XCTAssertEqual(lstat(first.temporaryDirectory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let lease = try Version3StorageLease.acquire(root: first.root)
        defer { withExtendedLifetime(lease) {} }
        try lease.validate()
        try FileManager.default.removeItem(at: marker)
        let choices = Dictionary(uniqueKeysWithValues: Version3JSONStoreConversion.primaryFilenames.map {
            ($0, Version3MigrationDriver.Source.absent)
        })
        let driver = Version3MigrationDriver(root: first.root, temporaryDirectory: first.temporaryDirectory)
        let admission = try driver.migrateSelectedSources(.init(legacyFiles: Array(Version3MigrationDriver.fixedLegacyPaths),
            primarySources: choices, signatures: .absent, calendar: Calendar(identifier: .gregorian), migrationDate: Date()))
        XCTAssertEqual(admission.storage.root, first.root.appendingPathComponent("v3", isDirectory: true))
    }

    func testCanonicalizesTrustedAncestorAliasAndRejectsFinalSymlinks() throws {
        let physical = try fixture()
        let aliased = URL(fileURLWithPath: "/tmp").appendingPathComponent(physical.lastPathComponent)
        let canonical = try Version3StartupPaths.canonicalDirectory(aliased)
        XCTAssertEqual(canonical.path, physical.path)
        let paths = try Version3StartupPaths.prepare(root: aliased.appendingPathComponent("profile"), temporaryParent: aliased)
        XCTAssertTrue(paths.root.path.hasPrefix("/private/tmp/"))
        let link = physical.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.root)
        XCTAssertThrowsError(try Version3StartupPaths.canonicalDirectory(link))
        XCTAssertThrowsError(try Version3StartupPaths.prepare(root: link, temporaryParent: physical))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.root.path).isEmpty)
    }

    func testFoundationTemporaryLocationProducesLeaseCompatiblePhysicalPaths() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("foundation-startup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: requested) }
        let paths = try Version3StartupPaths.prepare(root: requested,
            temporaryParent: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: paths.temporaryDirectory) }
        let lease = try Version3StorageLease.acquire(root: paths.root)
        defer { withExtendedLifetime(lease) {} }
        try lease.validate()
        XCTAssertEqual(try Version3StartupPaths.canonicalDirectory(paths.root), paths.root)
        XCTAssertEqual(try Version3StartupPaths.canonicalDirectory(paths.temporaryDirectory), paths.temporaryDirectory)
    }

    func testInvalidParentsAndExistingFilesNeverBecomeRoots() throws {
        let parent = try fixture()
        let file = parent.appendingPathComponent("file")
        try Data("unchanged".utf8).write(to: file)
        XCTAssertThrowsError(try Version3StartupPaths.prepare(root: file, temporaryParent: parent))
        XCTAssertThrowsError(try Version3StartupPaths.prepare(root: parent.appendingPathComponent("missing/profile"), temporaryParent: parent))
        XCTAssertThrowsError(try Version3StartupPaths.prepare(root: parent.appendingPathComponent("profile"), temporaryParent: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("profile").path))
        XCTAssertEqual(try Data(contentsOf: file), Data("unchanged".utf8))
        XCTAssertThrowsError(try Version3StartupPaths.canonicalDirectory(URL(string: "https://example.invalid")!))
    }
}
