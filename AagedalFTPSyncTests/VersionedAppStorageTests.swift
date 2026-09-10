import Foundation
import SQLite3
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

    func testCommittedCollectorPassesRuntimeStoresWithoutChangingInitialManifest() throws {
        try fixture { root, storage in
            let initialRegistry = try JSONEncoder().encode([String]())
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in
                ["jobs.json": validStore, "registry.json": initialRegistry]
            }, validate: validate, currentStorePaths: { _ in XCTFail("Initial installation must not use current inventory"); return [] })
            let manifestURL = v3.appendingPathComponent("storage-manifest.json")
            let manifestBefore = try Data(contentsOf: manifestURL)
            let archiveManifest = try XCTUnwrap(try archives(root).first).appendingPathComponent("storage-manifest.json")
            let boundaryBefore = try Data(contentsOf: root.appendingPathComponent(".v3-storage-boundary.json"))
            let maps = v3.appendingPathComponent("maps", isDirectory: true)
            try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: false)
            let map = Data("new committed mapping".utf8)
            try map.write(to: maps.appendingPathComponent("runtime.json"))
            try JSONEncoder().encode(["maps/runtime.json"]).write(to: v3.appendingPathComponent("registry.json"), options: .atomic)
            var validated = false
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: { files in
                try validate(files)
                XCTAssertEqual(files["maps/runtime.json"], map)
                XCTAssertEqual(files.count, 3)
                validated = true
            }, currentStorePaths: { files in
                XCTAssertEqual(Set(files.keys), ["jobs.json", "registry.json"])
                // An initial path can also be declared; the union reads it once.
                return try JSONDecoder().decode([String].self, from: XCTUnwrap(files["registry.json"])) + ["jobs.json"]
            })
            XCTAssertTrue(validated)
            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
            XCTAssertEqual(try Data(contentsOf: archiveManifest), manifestBefore)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".v3-storage-boundary.json")), boundaryBefore)
            _ = try storage.recoverPreparedInstallation(validate: { XCTAssertEqual($0["maps/runtime.json"], map) },
                                                       currentStorePaths: { _ in ["maps/runtime.json"] })
        }
    }

    func testCommittedCollectorRejectsMissingRequiredMapBeforeValidation() throws {
        try fixture { _, storage in
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] },
                validate: { _ in XCTFail("Missing map must fail before final validation") },
                currentStorePaths: { _ in ["maps/lost.json"] })) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .unsafeFile("v3/maps/lost.json"))
            }
        }
    }

    func testCommittedCollectorEnforcesPathUnionAndResourceBounds() throws {
        try fixture { _, storage in
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            for paths in [["../outside"], ["/absolute"], ["a//b"], ["a/./b"], ["a\\b"], ["a\0b"],
                          [String(repeating: "a", count: 1025)], [Array(repeating: "a", count: 17).joined(separator: "/")],
                          ["jobs.json/child"], ["storage-manifest.json"], ["same", "same"]] {
                XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] },
                    validate: { _ in XCTFail() }, currentStorePaths: { _ in paths }))
            }
            let smallPlan = VersionedAppStorage.Plan(legacyFiles: [], maximumFiles: 2)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: smallPlan, convert: { _ in XCTFail(); return [:] },
                validate: { _ in XCTFail() }, currentStorePaths: { _ in ["one", "two"] })) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .limitExceeded)
            }
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] },
                validate: { _ in XCTFail() }, currentStorePaths: { _ in throw Injected.invalidSchema }))
        }
    }

    func testCommittedCollectorRejectsOversizedAndAggregateStoreBytes() throws {
        try fixture { _, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            let maximum = validStore.count + 32
            let bounded = VersionedAppStorage.Plan(legacyFiles: [], maximumBytes: maximum)
            let first = v3.appendingPathComponent("first.json")
            try Data(repeating: 1, count: maximum + 1).write(to: first)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: bounded, convert: { _ in XCTFail(); return [:] },
                validate: { _ in XCTFail() }, currentStorePaths: { _ in ["first.json"] })) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .limitExceeded)
            }
            try Data(repeating: 1, count: 20).write(to: first)
            try Data(repeating: 2, count: 20).write(to: v3.appendingPathComponent("second.json"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: bounded, convert: { _ in XCTFail(); return [:] },
                validate: { _ in XCTFail() }, currentStorePaths: { _ in ["first.json", "second.json"] })) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .limitExceeded)
            }
        }
    }

    func testCommittedCollectorRejectsLinksAndUncheckpointedSQLite() throws {
        try fixture { _, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            let actual = v3.appendingPathComponent("actual.json")
            try validStore.write(to: actual)
            let link = v3.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
            let parentLink = v3.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: v3)
            let hardLink = v3.appendingPathComponent("hard.json")
            try FileManager.default.linkItem(at: actual, to: hardLink)
            for path in ["link.json", "linked/actual.json", "hard.json"] {
                XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] },
                    validate: { _ in XCTFail() }, currentStorePaths: { _ in [path] }))
            }
            let database = v3.appendingPathComponent("extra.sqlite3")
            try Data("fixture".utf8).write(to: database)
            try Data().write(to: URL(fileURLWithPath: database.path + "-wal"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] },
                validate: { _ in XCTFail() }, currentStorePaths: { _ in ["extra.sqlite3"] })) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .sqliteNotQuiescent("v3/extra.sqlite3"))
            }
        }
    }

    func testPreparedInstallationNeverUsesCurrentCollectorOrRelaxesInitialHashes() throws {
        try fixture { root, storage in
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate,
                currentStorePaths: { _ in XCTFail("Prepared must not collect runtime stores"); return [] }, checkpoint: {
                    if case .installed = $0 { throw Injected.interruption }
                }))
            let jobs = root.appendingPathComponent("v3/jobs.json")
            let changed = Data("{\"version\":3,\"changed\":true}".utf8)
            try changed.write(to: jobs)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate,
                currentStorePaths: { _ in XCTFail("Cannot replace prepared manifest with dynamic paths"); return [] })) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
            try validStore.write(to: jobs)
            _ = try storage.recoverPreparedInstallation(validate: validate,
                currentStorePaths: { _ in XCTFail("Prepared recovery must not collect dynamic paths"); return [] })
        }
    }

    func testCommittedCollectorDetectsRegistryMutationDuringCollection() throws {
        try fixture { _, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore, "registry.json": Data("[]".utf8)] }, validate: validate)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] },
                validate: { _ in XCTFail("Changed base stores must fail before validation") }, currentStorePaths: { _ in
                    try Data("[\"new\"]".utf8).write(to: v3.appendingPathComponent("registry.json"), options: .atomic)
                    return []
                })) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .inputChanged("registry.json"))
            }
        }
    }

    func testDefaultCommittedInventoryBudgetSupports4096RuntimeMaps() throws {
        try fixture { _, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            let maps = v3.appendingPathComponent("maps", isDirectory: true)
            try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: false)
            let paths = (0..<4096).map { "maps/\($0).json" }
            for path in paths { try Data("{}".utf8).write(to: v3.appendingPathComponent(path)) }
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: { files in
                try validate(files)
                XCTAssertEqual(files.count, 4097)
                XCTAssertTrue(paths.allSatisfy { files[$0] == Data("{}".utf8) })
            }, currentStorePaths: { _ in paths })
        }
    }

    /// Materialize a closed crash-style main/WAL/SHM set while leaving no writer
    /// connected to the files that migration will inspect.
    private func sqliteFixture(_ root: URL, name: String = "signatures.sqlite3") throws -> [String: Data] {
        let live = root.appendingPathComponent("fixture-\(UUID().uuidString).sqlite3")
        var pointer: OpaquePointer?
        guard sqlite3_open(live.path, &pointer) == SQLITE_OK, let pointer else { throw Injected.invalidSchema }
        defer {
            sqlite3_close(pointer)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: live.path + suffix) }
        }
        let sql = SourceSignatureRepository.version3TableSQL + ";" + SourceSignatureRepository.version3IndexSQL + ";PRAGMA user_version = 2;"
            + "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;"
            + "INSERT INTO source_signatures VALUES ('AE5B40F5-6C9C-4FDC-89C8-B9D802DB20C1','5:local8:/fixture0:1:00:0:','photo.jpg',42,-123456.125,1700000000.875)"
        guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw Injected.invalidSchema }
        var bytes: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: live.path + suffix))
            let relative = name + suffix
            try data.write(to: root.appendingPathComponent(relative))
            bytes[relative] = data
        }
        return bytes
    }
    private var sqlitePaths: [String] {
        ["signatures.sqlite3", "signatures.sqlite3-wal", "signatures.sqlite3-shm", "signatures.sqlite3-journal"]
    }
    private var sqlitePlan: VersionedAppStorage.Plan { .init(legacyFiles: plan.legacyFiles + sqlitePaths) }

    func testAcquiredWALMigrationRetainsRawCompanionsAndConvertsCommittedRow() throws {
        try fixture { root, storage in
            let raw = try sqliteFixture(root)
            let receipt = try storage.acquireLegacySQLite(relativePath: "signatures.sqlite3", temporaryDirectory: root)
            XCTAssertEqual(receipt.output.recordCount, 1)
            let v3Bytes = try Version3SignatureConversion.convert(.standaloneSnapshot(receipt.output.data), temporaryDirectory: root)
            XCTAssertEqual(v3Bytes.recordCount, 1)
            let v3 = try storage.openOrMigrate(plan: sqlitePlan, convert: { files in
                for (path, data) in raw { XCTAssertEqual(files[path], data) }
                XCTAssertEqual(files["signatures.sqlite3"]?[18], 2)
                XCTAssertNil(files["signatures.sqlite3-journal"])
                return ["jobs.json": validStore, "signatures.sqlite3": v3Bytes.data]
            }, validate: { files in
                try validate(files)
                XCTAssertEqual(files["signatures.sqlite3"], v3Bytes.data)
            }, sqliteAcquisitions: ["signatures.sqlite3": receipt])
            XCTAssertEqual(try Data(contentsOf: v3.appendingPathComponent("signatures.sqlite3")), v3Bytes.data)
            let archive = try XCTUnwrap(archives(root).first)
            for (path, data) in raw {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), data)
                XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("legacy/" + path)), data)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("legacy/signatures.sqlite3-journal").path))
            _ = try storage.openOrMigrate(plan: sqlitePlan, convert: { _ in XCTFail("Committed open must not acquire or convert"); return [:] }, validate: validate)
        }
    }

    func testSQLiteReceiptRequiresCompleteInventoryAndExactRootAndKey() throws {
        try fixture { root, storage in
            _ = try sqliteFixture(root)
            let receipt = try storage.acquireLegacySQLite(relativePath: "signatures.sqlite3", temporaryDirectory: root)
            for omitted in sqlitePaths {
                let incomplete = VersionedAppStorage.Plan(legacyFiles: sqlitePlan.legacyFiles.filter { $0 != omitted })
                XCTAssertThrowsError(try storage.openOrMigrate(plan: incomplete, convert: { _ in XCTFail(); return [:] }, validate: validate,
                    sqliteAcquisitions: ["signatures.sqlite3": receipt])) {
                    XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidSQLiteAcquisition("signatures.sqlite3"))
                }
            }
            XCTAssertThrowsError(try storage.openOrMigrate(plan: sqlitePlan, convert: { _ in XCTFail(); return [:] }, validate: validate,
                sqliteAcquisitions: ["other.sqlite3": receipt]))
            let otherRoot = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
            let other = VersionedAppStorage(root: otherRoot)
            XCTAssertThrowsError(try other.openOrMigrate(plan: sqlitePlan, convert: { _ in XCTFail(); return [:] }, validate: validate,
                sqliteAcquisitions: ["signatures.sqlite3": receipt])) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidSQLiteAcquisition("signatures.sqlite3"))
            }
            // No receipt still means the existing blanket WAL refusal.
            XCTAssertThrowsError(try storage.openOrMigrate(plan: sqlitePlan, convert: { _ in XCTFail(); return [:] }, validate: validate)) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .sqliteNotQuiescent("signatures.sqlite3"))
            }
            XCTAssertTrue(try archives(root).isEmpty)
        }
    }

    func testSQLiteReceiptRejectsChangedBytesRemovedCompanionAndSameBytesReplacementBeforeConversion() throws {
        for change in 0..<3 {
            try fixture { root, storage in
                let raw = try sqliteFixture(root)
                let receipt = try storage.acquireLegacySQLite(relativePath: "signatures.sqlite3", temporaryDirectory: root)
                let wal = root.appendingPathComponent("signatures.sqlite3-wal")
                if change == 0 {
                    var data = try XCTUnwrap(raw["signatures.sqlite3-wal"]); data.append(0)
                    try data.write(to: wal)
                } else if change == 1 {
                    try FileManager.default.removeItem(at: wal)
                } else {
                    try XCTUnwrap(raw["signatures.sqlite3-wal"]).write(to: wal, options: .atomic)
                }
                XCTAssertThrowsError(try storage.openOrMigrate(plan: sqlitePlan, convert: { _ in XCTFail("Stale receipt must fail before converter"); return [:] },
                    validate: validate, sqliteAcquisitions: ["signatures.sqlite3": receipt])) {
                    XCTAssertEqual($0 as? VersionedAppStorage.Failure, .inputChanged("signatures.sqlite3-wal"))
                }
                XCTAssertTrue(try archives(root).isEmpty)
            }
        }
    }

    func testSQLiteReceiptBindsAbsentCompanionsAndRechecksTailBeforeBoundary() throws {
        for phase in 0..<3 {
            try fixture { root, storage in
                _ = try sqliteFixture(root)
                if phase == 0 { try FileManager.default.removeItem(at: root.appendingPathComponent("signatures.sqlite3-shm")) }
                let receipt = try storage.acquireLegacySQLite(relativePath: "signatures.sqlite3", temporaryDirectory: root)
                if phase == 0 { try Data(repeating: 0, count: 32768).write(to: root.appendingPathComponent("signatures.sqlite3-shm")) }
                if phase == 1 { try Data([1]).write(to: root.appendingPathComponent("signatures.sqlite3-journal")) }
                var converted = false
                XCTAssertThrowsError(try storage.openOrMigrate(plan: sqlitePlan, convert: { _ in
                    converted = true; return ["jobs.json": validStore]
                }, validate: validate, sqliteAcquisitions: ["signatures.sqlite3": receipt], checkpoint: { point in
                    if phase == 2, case .stageValidated = point {
                        let wal = root.appendingPathComponent("signatures.sqlite3-wal")
                        var data = try Data(contentsOf: wal); data.append(0)
                        try data.write(to: wal)
                    }
                }))
                XCTAssertEqual(converted, phase == 2)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".v3-storage-boundary.json").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
            }
        }
    }

    func testPreparedSQLiteMigrationRecoversFrozenWALConversionWithoutReacquisition() throws {
        try fixture { root, storage in
            let raw = try sqliteFixture(root)
            let receipt = try storage.acquireLegacySQLite(relativePath: "signatures.sqlite3", temporaryDirectory: root)
            let converted = try Version3SignatureConversion.convert(.standaloneSnapshot(receipt.output.data), temporaryDirectory: root)
            XCTAssertThrowsError(try storage.openOrMigrate(plan: sqlitePlan, convert: { _ in
                ["jobs.json": validStore, "signatures.sqlite3": converted.data]
            }, validate: validate, sqliteAcquisitions: ["signatures.sqlite3": receipt], checkpoint: {
                if case .boundaryPrepared = $0 { throw Injected.interruption }
            }))
            // Simulate later old-app writes/damage. Recovery must use archived
            // originals/install bytes and never read a new signature snapshot.
            try Data("changed WAL after prepared boundary".utf8).write(to: root.appendingPathComponent("signatures.sqlite3-wal"))
            let v3 = try storage.recoverPreparedInstallation(validate: validate)
            XCTAssertEqual(try Data(contentsOf: v3.appendingPathComponent("signatures.sqlite3")), converted.data)
            let archive = try XCTUnwrap(archives(root).first)
            for (path, data) in raw { XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("legacy/" + path)), data) }
            try Data("altered retained WAL".utf8).write(to: archive.appendingPathComponent("legacy/signatures.sqlite3-wal"))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: sqlitePlan, convert: { _ in XCTFail(); return [:] }, validate: validate)) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
        }
    }


    func testImmutableInitialProvenanceStaysFrozenWhileMutableStoresChange() throws {
        try fixture { root, storage in
            let path = "migration-source-selection-v3.json"
            let provenance = Data("{\"version\":3,\"source\":\"primary\"}".utf8)
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in
                ["jobs.json": validStore, path: provenance]
            }, validate: validate, immutableStorePaths: [path])
            let mutable = Data("{\"version\":3,\"headline\":\"later edit\"}".utf8)
            try mutable.write(to: v3.appendingPathComponent("jobs.json"))
            _ = try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate,
                immutableStorePaths: [path])
            try Data("{\"version\":3,\"source\":\"backup\"}".utf8).write(to: v3.appendingPathComponent(path))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate,
                currentStorePaths: { _ in [path] }, immutableStorePaths: [path])) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
            XCTAssertThrowsError(try storage.recoverPreparedInstallation(validate: validate, immutableStorePaths: [path])) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
            XCTAssertEqual(try Data(contentsOf: v3.appendingPathComponent("jobs.json")), mutable)
        }
    }

    func testImmutableProvenanceMustBelongToInitialManifestIncludingOnRecovery() throws {
        let path = "migration-source-selection-v3.json"
        try fixture { root, storage in
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] },
                validate: validate, immutableStorePaths: [path])) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".v3-storage-boundary.json").path))
        }
        try fixture { root, storage in
            let v3 = try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate)
            try Data("{}".utf8).write(to: v3.appendingPathComponent(path))
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: validate,
                currentStorePaths: { _ in [path] }, immutableStorePaths: [path])) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
        }
        try fixture { _, storage in
            XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in ["jobs.json": validStore] }, validate: validate,
                checkpoint: { if case .boundaryPrepared = $0 { throw Injected.interruption } }))
            XCTAssertThrowsError(try storage.recoverPreparedInstallation(validate: validate, immutableStorePaths: [path])) {
                XCTAssertEqual($0 as? VersionedAppStorage.Failure, .invalidManifest)
            }
        }
    }


    func testPreparedStagedAndInstalledSQLiteRejectUnlistedWALBeforeRecovery() throws {
        for installed in [false, true] {
            try fixture { root, storage in
                let sqlite = try Version3SignatureConversion.convert(.noLegacyStore, temporaryDirectory: root).data
                XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in
                    ["jobs.json": validStore, "signatures.sqlite3": sqlite]
                }, validate: validate, checkpoint: { point in
                    if installed, case .installed = point { throw Injected.interruption }
                    if !installed, case .boundaryPrepared = point { throw Injected.interruption }
                }))
                let directory: URL
                if installed { directory = root.appendingPathComponent("v3") }
                else { directory = try XCTUnwrap(archives(root).first).appendingPathComponent("install") }
                let boundaryURL = root.appendingPathComponent(".v3-storage-boundary.json")
                let preparedBoundary = try Data(contentsOf: boundaryURL)
                let walURL = directory.appendingPathComponent("signatures.sqlite3-wal")
                try Data([1, 2, 3]).write(to: walURL)
                XCTAssertThrowsError(try storage.recoverPreparedInstallation(validate: { _ in
                    XCTFail("Companions must be rejected before semantic Data validation")
                })) {
                    guard let failure = $0 as? VersionedAppStorage.Failure, case .sqliteNotQuiescent(let path) = failure else {
                        return XCTFail("Expected standalone SQLite refusal, got \($0)")
                    }
                    XCTAssertTrue(path.hasSuffix("/signatures.sqlite3"))
                }
                if installed {
                    XCTAssertThrowsError(try storage.openOrMigrate(plan: plan, convert: { _ in XCTFail(); return [:] }, validate: { _ in XCTFail() }))
                }
                XCTAssertEqual(try Data(contentsOf: boundaryURL), preparedBoundary)
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("signatures.sqlite3")), sqlite)
                XCTAssertEqual(try Data(contentsOf: walURL), Data([1, 2, 3]))
                try FileManager.default.removeItem(at: walURL)
                _ = try storage.recoverPreparedInstallation(validate: validate)
            }
        }
    }

}
