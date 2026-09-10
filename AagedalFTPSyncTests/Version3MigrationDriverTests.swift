import Foundation
import SQLite3
import XCTest
@testable import AagedalFTPSync

final class Version3MigrationDriverTests: XCTestCase {
    private typealias Driver = Version3MigrationDriver
    private enum Injected: Error { case interrupted }
    private func fixture() throws -> (URL, Driver) {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("selected-migration-\(UUID())")
        let root = base.appendingPathComponent("profile")
        let temporary = base.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, Driver(root: root, temporaryDirectory: temporary))
    }
    private func plan(primaryOverrides: [String: Driver.Source] = [:], signatures: Driver.Signatures = .absent,
                      mappings: [String] = []) -> Driver.Plan {
        var sources = Dictionary(uniqueKeysWithValues: Version3JSONStoreConversion.primaryFilenames.map { ($0, Driver.Source.absent) })
        sources.merge(primaryOverrides) { _, chosen in chosen }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Etc/UTC")!
        return Driver.Plan(legacyFiles: Array(Driver.fixedLegacyPaths).sorted() + mappings,
            primarySources: sources, signatures: signatures, calendar: calendar,
            migrationDate: Date(timeIntervalSince1970: 1_800_000_000))
    }
    private func archive(_ root: URL) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".v3-migration-") })
    }
    private func encode(_ jobs: [SyncJob]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(jobs)
    }

    func testEmptyExplicitSelectionCreatesCompleteStoresAndReopensWithoutReimport() async throws {
        let (root, driver) = try fixture()
        let result = try driver.migrateSelectedSources(plan())
        XCTAssertEqual(result.storage.root, root.appendingPathComponent("v3", isDirectory: true))
        XCTAssertFalse(result.allowsCredentialGarbageCollection)
        XCTAssertTrue(result.currentCredentialIDs.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.storage.root.path).count, 13) // 12 stores + immutable manifest
        let reopened = try await driver.openCommitted()
        XCTAssertEqual(reopened.storage, result.storage)
        XCTAssertEqual(reopened.selection.primarySources, result.selection.primarySources)
        XCTAssertEqual(reopened.selection.migrationTimestamp, 1_800_000_000)
        XCTAssertThrowsError(try driver.migrateSelectedSources(plan()))
    }

    func testExplicitBackupSelectionRetainsDamagedPrimaryAndLiteralPayloadAndProvenance() async throws {
        let (root, driver) = try fixture()
        let job = SyncJob(name: "{gps:city} stays literal")
        let backup = try encode([job])
        let damaged = Data("damaged primary".utf8)
        try damaged.write(to: root.appendingPathComponent("jobs-v2.json"))
        try backup.write(to: root.appendingPathComponent("jobs-v2.json.backup"))
        let result = try driver.migrateSelectedSources(plan(primaryOverrides: ["jobs-v2.json": .file("jobs-v2.json.backup")]))
        XCTAssertEqual(try JobRepository(storage: result.storage).load().first?.name, job.name)
        let retained = try archive(root).appendingPathComponent("legacy")
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("jobs-v2.json")), damaged)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("jobs-v2.json.backup")), backup)
        XCTAssertEqual(result.selection.primarySources["jobs-v2.json"], .file("jobs-v2.json.backup"))
        XCTAssertFalse(result.allowsCredentialGarbageCollection)
        // A changed legacy file cannot be re-imported on a current open.
        try encode([SyncJob(name: "Later legacy edit")]).write(to: root.appendingPathComponent("jobs-v2.json"))
        let reopened = try await driver.openCommitted()
        XCTAssertEqual(try JobRepository(storage: reopened.storage).load().first?.name, job.name)
    }

    func testAbsentSelectionCannotDiscardExistingPrimaryOrBackupAndUnknownInventoryFails() throws {
        for name in ["jobs-v2.json", "jobs-v2.json.backup", "original-source-signatures-v1.json", "future-store-v4.json"] {
            let (root, driver) = try fixture()
            let bytes = Data("[]".utf8)
            try bytes.write(to: root.appendingPathComponent(name))
            XCTAssertThrowsError(try driver.migrateSelectedSources(plan()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".v3-storage-boundary.json").path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes)
        }
    }

    func testCompleteMappingInventoryPersistsAndRuntimeMappingsPassCurrentValidation() async throws {
        let (root, driver) = try fixture()
        let name = String(repeating: "a", count: 64) + ".json"
        let path = "download-names-v1/" + name
        try FileManager.default.createDirectory(at: root.appendingPathComponent("download-names-v1"), withIntermediateDirectories: false)
        try JSONEncoder().encode(["photo.jpg": "photo (2).jpg"]).write(to: root.appendingPathComponent(path))
        XCTAssertThrowsError(try driver.migrateSelectedSources(plan()))
        let result = try driver.migrateSelectedSources(plan(mappings: [path]))
        let registry = try DownloadNameMappingRegistry(storage: result.storage)
        let runtimeName = String(repeating: "b", count: 64) + ".json.replace"
        _ = try await registry.admitOrProvision(fileName: runtimeName)
        let reopened = try await driver.openCommitted()
        XCTAssertEqual(reopened.storage, result.storage)
        try FileManager.default.removeItem(at: result.storage.downloadNamesDirectory.appendingPathComponent(runtimeName))
        do { _ = try await driver.openCommitted(); XCTFail("A lost runtime receipt must block current startup") } catch {}
    }

    func testPreparedRecoveryUsesFrozenSelectionAfterOriginalFilesChange() async throws {
        for stop in [VersionedAppStorage.Checkpoint.boundaryPrepared, .installed] {
            let (root, driver) = try fixture()
            let bytes = try encode([SyncJob(name: "Frozen selection")])
            try bytes.write(to: root.appendingPathComponent("jobs-v2.json"))
            XCTAssertThrowsError(try driver.migrateSelectedSources(plan(primaryOverrides: ["jobs-v2.json": .file("jobs-v2.json")]), checkpoint: { stage in
                switch (stage, stop) {
                case (.boundaryPrepared, .boundaryPrepared), (.installed, .installed): throw Injected.interrupted
                default: break
                }
            }))
            try encode([SyncJob(name: "Changed after interruption")]).write(to: root.appendingPathComponent("jobs-v2.json"))
            let recovered = try await driver.recoverPreparedInstallation()
            XCTAssertEqual(try JobRepository(storage: recovered.storage).load().first?.name, "Frozen selection")
            XCTAssertEqual(try Data(contentsOf: try archive(root).appendingPathComponent("legacy/jobs-v2.json")), bytes)
        }
    }

    func testImmutableSelectionAndFutureCurrentStoreDamageBlockAdmission() async throws {
        let (_, driver) = try fixture()
        let result = try driver.migrateSelectedSources(plan())
        let provenance = result.storage.root.appendingPathComponent(Driver.selectionFilename)
        let bytes = try Data(contentsOf: provenance)
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        changed["migrationTimestamp"] = 42
        try JSONSerialization.data(withJSONObject: changed).write(to: provenance)
        do { _ = try await driver.openCommitted(); XCTFail("Immutable choice record changed") } catch {}
        try bytes.write(to: provenance)
        let jobs = try Data(contentsOf: result.storage.jobs)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: jobs) as? [String: Any])
        future["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: future).write(to: result.storage.jobs)
        do { _ = try await driver.openCommitted(); XCTFail("Future current data cannot fall back") } catch {}
    }

    func testWALAcquisitionAndMigrationRetainAllOriginalEvidence() async throws {
        let (root, driver) = try fixture()
        let url = root.appendingPathComponent("original-source-signatures-v2.sqlite3")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        let sql = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA user_version=2; "
            + SourceSignatureRepository.version3TableSQL + "; " + SourceSignatureRepository.version3IndexSQL + ";"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        let id = UUID().uuidString
        let key = ["local", "/source", "", "0", "", ""].map { "\($0.utf8.count):\($0)" }.joined()
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO source_signatures VALUES ('\(id)', '\(key)', 'photo.jpg', 10, 123.25, 124.5)", nil, nil, nil), SQLITE_OK)
        let originals = try Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm"].map {
            ($0, try Data(contentsOf: URL(fileURLWithPath: url.path + $0)))
        })
        let result = try driver.migrateSelectedSources(plan(signatures: .sqlite(url.lastPathComponent)))
        let validation = try Version3SignatureConversion.validateVersion3Snapshot(Data(contentsOf: result.storage.sourceSignatures),
                                                                                 temporaryDirectory: driver.temporaryDirectory)
        XCTAssertEqual(validation.recordCount, 1)
        XCTAssertEqual(validation.referencedJobIDs, [try XCTUnwrap(UUID(uuidString: id))])
        let retained = try archive(root).appendingPathComponent("legacy")
        for (suffix, bytes) in originals {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + suffix)), bytes)
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(url.lastPathComponent + suffix)), bytes)
        }
        _ = try await driver.openCommitted()
    }
}
