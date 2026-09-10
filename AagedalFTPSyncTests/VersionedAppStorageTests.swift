import Foundation
import XCTest
@testable import AagedalFTPSync

final class VersionedAppStorageTests: XCTestCase {
    private enum Injected: Error { case interruption, invalidSchema }
    private let legacy = Data("[{\"headline\":\"{gps:city}\"}]".utf8)
    private let validStore = Data("{\"version\":3,\"headline\":\"{gps:city}\",\"activated\":false}".utf8)

    private func fixture(_ action: (URL, VersionedAppStorage) throws -> Void) throws {
        // Foundation normalizes the standard /private/var temp alias back to
        // /var on this host. Use an explicit non-symlink root for this contract.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try legacy.write(to: root.appendingPathComponent("jobs-v2.json"))
        try action(root, VersionedAppStorage(root: root))
    }
    private var plan: VersionedAppStorage.Plan { .init(legacyFiles: ["jobs-v2.json", "jobs-v2.json.backup"]) }
    private func validate(_ files: VersionedAppStorage.Files) throws {
        guard let data = files["jobs.json"],
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 3 else { throw Injected.invalidSchema }
    }
    private func archives(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".v3-migration-") }
    }

    func testMigrationRetainsLegacyAndSeparateSnapshotAndLiteralBraces() throws {
        try fixture { root, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { files in
                XCTAssertEqual(files["jobs-v2.json"], legacy)
                XCTAssertNil(files["jobs-v2.json.backup"])
                return ["jobs.json": validStore]
            }, validate: validate)
            XCTAssertEqual(v3, root.appendingPathComponent("v3", isDirectory: true))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("jobs-v2.json")), legacy)
            XCTAssertEqual(try Data(contentsOf: v3.appendingPathComponent("jobs.json")), validStore)
            let snapshots = try archives(root)
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(snapshots.first).appendingPathComponent("legacy/jobs-v2.json")), legacy)
        }
    }

    func testValidLaterStoreEditsOpenWithoutReconversionOrInitialHashRequirement() throws {
        try fixture { root, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            let edited = Data("{\"version\":3,\"headline\":\"new\",\"activated\":true}".utf8)
            try edited.write(to: v3.appendingPathComponent("jobs.json"), options: .atomic)
            try Data("new legacy settings".utf8).write(to: root.appendingPathComponent("jobs-v2.json"))
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail("Must not re-import legacy"); return [:] }, validate: validate)
            XCTAssertEqual(try Data(contentsOf: v3.appendingPathComponent("jobs.json")), edited)
        }
    }

    func testCommittedMissingOrInvalidStoresNeverFallBack() throws {
        try fixture { root, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            try Data("{\"version\":99}".utf8).write(to: v3.appendingPathComponent("jobs.json"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate))
            try FileManager.default.removeItem(at: v3)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate)) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .committedStorageMissing)
            }
            XCTAssertThrowsError(try storage.recoverPreparedInstallation(validate: validate)) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .committedStorageMissing)
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("jobs-v2.json")), legacy)
        }
    }

    func testPreparedBoundaryRequiresExplicitRecoveryAndUsesFrozenSnapshot() throws {
        try fixture { root, storage in
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate, checkpoint: {
                if case .boundaryPrepared = $0 { throw Injected.interruption }
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
            try Data("changed by old app".utf8).write(to: root.appendingPathComponent("jobs-v2.json"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate)) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .recoveryRequired)
            }
            let v3 = try storage.recoverPreparedInstallation(validate: validate)
            XCTAssertEqual(try Data(contentsOf: v3.appendingPathComponent("jobs.json")), validStore)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(try archives(root).first).appendingPathComponent("legacy/jobs-v2.json")), legacy)
        }
    }

    func testInterruptionAfterAtomicInstallFinishesBoundaryWithoutReimport() throws {
        try fixture { _, storage in
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate, checkpoint: {
                if case .installed = $0 { throw Injected.interruption }
            }))
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate)
        }
    }

    func testCorruptedPreparedStageFailsClosedAndCanBeRepairedFromKnownBytes() throws {
        try fixture { root, storage in
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate, checkpoint: {
                if case .boundaryPrepared = $0 { throw Injected.interruption }
            }))
            let staged = try XCTUnwrap(try archives(root).first).appendingPathComponent("install/jobs.json")
            try Data("{\"version\":3,\"changed\":true}".utf8).write(to: staged)
            XCTAssertThrowsError(try storage.recoverPreparedInstallation(validate: validate))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
            try validStore.write(to: staged)
            _ = try storage.recoverPreparedInstallation(validate: validate)
        }
    }

    func testFailureBeforeBoundaryLeavesOriginalsAndAllowsFreshAttempt() throws {
        for checkpoint in [VersionedAppStorage.Checkpoint.snapshotCaptured, .stageValidated] {
            try fixture { root, storage in
                XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate, checkpoint: {
                    if String(describing: $0) == String(describing: checkpoint) { throw Injected.interruption }
                }))
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("jobs-v2.json")), legacy)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".v3-storage-boundary.json").path))
                _ = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            }
        }
    }

    func testChangedAndNewlyAppearingInputsAbortBeforeBoundary() throws {
        for path in ["jobs-v2.json", "jobs-v2.json.backup"] {
            try fixture { root, storage in
                XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in
                    try Data("changed".utf8).write(to: root.appendingPathComponent(path), options: .atomic)
                    return ["jobs.json": validStore]
                }, validate: validate)) {
                    XCTAssertEqual($0 as? VersionedAppStorage.Failure, .inputChanged(path))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".v3-storage-boundary.json").path))
            }
        }
    }

    func testConcurrentMigrationCannotEnterConversion() throws {
        try fixture { root, storage in
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in
                let competing = VersionedAppStorage(root: root)
                XCTAssertThrowsError(try competing.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate)) {
                    XCTAssertEqual($0 as? VersionedAppStorage.Failure, .migrationInProgress)
                }
                return ["jobs.json": validStore]
            }, validate: validate)
        }
    }

    func testSymlinkedSourcesAndRootAndHardlinksAreRejected() throws {
        try fixture { root, storage in
            let target = root.appendingPathComponent("real.json")
            try legacy.write(to: target)
            let source = root.appendingPathComponent("jobs-v2.json")
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate))
            try FileManager.default.removeItem(at: source)
            try FileManager.default.linkItem(at: target, to: source)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate))
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            XCTAssertThrowsError(try VersionedAppStorage(root: alias).openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate))
        }
    }

    func testSymlinkedParentAndSQLiteCompanionsAreRejected() throws {
        try fixture { root, storage in
            let actual = root.appendingPathComponent("actual")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
            try legacy.write(to: actual.appendingPathComponent("jobs.json"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: actual)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: .init(legacyFiles: ["linked/jobs.json"]), convert: { _ in XCTFail(); return [:] }, validate: validate))
            try legacy.write(to: root.appendingPathComponent("signatures.sqlite3"))
            for suffix in ["-wal", "-shm", "-journal"] {
                let companion = root.appendingPathComponent("signatures.sqlite3" + suffix)
                try Data().write(to: companion)
                XCTAssertThrowsError(try storage.openOrMigrate(plan: .init(legacyFiles: ["signatures.sqlite3"]), convert: { _ in XCTFail(); return [:] }, validate: validate)) {
                    XCTAssertEqual($0 as? VersionedAppStorage.Failure, .sqliteNotQuiescent("signatures.sqlite3"))
                }
                try FileManager.default.removeItem(at: companion)
            }
        }
    }

    func testPathTraversalLimitsAndUnsupportedSchemaDoNotInstall() throws {
        try fixture { root, storage in
            for path in ["../outside", "/absolute", "a//b", "a/./b", "a\\b"] {
                XCTAssertThrowsError(try storage.openOrMigrate(plan: .init(legacyFiles: [path]), convert: { _ in XCTFail(); return [:] }, validate: validate))
            }
            XCTAssertThrowsError(try storage.openOrMigrate(plan: .init(legacyFiles: ["jobs-v2.json"], maximumBytes: 1), convert: { _ in XCTFail(); return [:] }, validate: validate))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["../outside": validStore] }, validate: validate))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": Data("{\"version\":4}".utf8)] }, validate: validate))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
        }
    }

    func testMalformedBoundaryFailsClosedAndOrphanTemporaryFilesAreNotSelected() throws {
        try fixture { root, storage in
            try Data("unfinished".utf8).write(to: root.appendingPathComponent(".v3-boundary-orphan.tmp"))
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".v3-boundary-orphan.tmp").path))
            try Data("{".utf8).write(to: root.appendingPathComponent(".v3-storage-boundary.json"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate))
            XCTAssertThrowsError(try storage.recoverPreparedInstallation(validate: validate))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("jobs-v2.json")), legacy)
        }
    }

    func testSnapshotTamperingAndMissingBoundaryAreDetected() throws {
        try fixture { root, storage in
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            try Data("tampered".utf8).write(to: XCTUnwrap(try archives(root).first).appendingPathComponent("legacy/jobs-v2.json"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate))
            try FileManager.default.removeItem(at: root.appendingPathComponent(".v3-storage-boundary.json"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate)) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
        }
    }
}
