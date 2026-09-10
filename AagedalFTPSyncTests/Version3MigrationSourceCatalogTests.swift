import Darwin
import Foundation
import XCTest
@testable import AagedalFTPSync

final class Version3MigrationSourceCatalogTests: XCTestCase {
    private typealias Catalog = Version3MigrationSourceCatalog
    private typealias Driver = Version3MigrationDriver
    private let main = "original-source-signatures-v2.sqlite3"
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("source-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func calendar() -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return value
    }
    private func selections(_ catalog: Catalog) -> [String: Driver.Source] {
        Dictionary(uniqueKeysWithValues: catalog.primaries.map { ($0.filename, $0.choices[0]) })
    }
    private func plan(_ catalog: Catalog, sources: [String: Driver.Source]? = nil,
                      signature: Driver.Signatures = .absent) throws -> Driver.Plan {
        try catalog.makePlan(primarySources: sources ?? selections(catalog), signatures: signature,
                             calendar: calendar(), migrationDate: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testEmptyInventoryOffersOnlyExplicitAbsenceAndBuildsCompleteFrozenPlanWithoutWrites() throws {
        let root = try root()
        let catalog = try Catalog.inspect(root: root)
        XCTAssertEqual(catalog.primaries.count, 9)
        XCTAssertEqual(catalog.primaries.map(\.filename), Version3JSONStoreConversion.primaryFilenames.sorted())
        XCTAssertTrue(catalog.primaries.allSatisfy { $0.choices == [.absent] })
        XCTAssertEqual(catalog.signatureChoices, [.absent])
        XCTAssertEqual(catalog.legacyFiles, Driver.fixedLegacyPaths.sorted())
        let plan = try plan(catalog)
        XCTAssertEqual(plan.primarySources, selections(catalog))
        XCTAssertEqual(plan.signatures, .absent)
        XCTAssertEqual(plan.calendar.timeZone.identifier, "Europe/Oslo")
        XCTAssertEqual(plan.migrationDate.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testDamagedPrimaryAndExistingBackupRemainDistinctChoicesWithNoImplicitFallback() throws {
        let root = try root()
        let names = Version3JSONStoreConversion.primaryFilenames.sorted()
        let damaged = Data([0xff, 0x00, 0x01])
        try damaged.write(to: root.appendingPathComponent(names[0]))
        try Data("[]".utf8).write(to: root.appendingPathComponent(names[0] + ".backup"))
        try Data("[]".utf8).write(to: root.appendingPathComponent(names[1] + ".backup"))
        let catalog = try Catalog.inspect(root: root)
        XCTAssertEqual(catalog.primaries[0].choices, [.file(names[0]), .file(names[0] + ".backup")])
        XCTAssertEqual(catalog.primaries[1].choices, [.file(names[1] + ".backup")])
        XCTAssertEqual(catalog.primaries[2].choices, [.absent])
        var selected = selections(catalog)
        selected[names[0]] = .file(names[0] + ".backup")
        XCTAssertEqual(try plan(catalog, sources: selected).primarySources[names[0]], .file(names[0] + ".backup"))
        selected[names[0]] = .absent
        XCTAssertThrowsError(try plan(catalog, sources: selected)) { XCTAssertEqual($0 as? Catalog.Failure, .invalidSelection) }
        selected = selections(catalog); selected.removeValue(forKey: names[0])
        XCTAssertThrowsError(try plan(catalog, sources: selected))
        selected = selections(catalog); selected[names[0]] = .file("unoffered.json")
        XCTAssertThrowsError(try plan(catalog, sources: selected))
        XCTAssertThrowsError(try catalog.makePlan(primarySources: selections(catalog), signatures: .absent,
            calendar: calendar(), migrationDate: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(names[0])), damaged)
    }

    func testAllKnownSignatureVariantsRemainExplicitFormatsAndNeverOfferAbsent() throws {
        let root = try root()
        let variants = Driver.fixedLegacyPaths.filter {
            $0.hasPrefix("original-source-signatures-") && !$0.contains("migration-in-progress")
                && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.hasSuffix("-journal")
        }
        for path in variants { try Data([0xff, 0x00]).write(to: root.appendingPathComponent(path)) }
        let catalog = try Catalog.inspect(root: root)
        XCTAssertEqual(Array(catalog.signatureChoices.prefix(2)), [.sqlite(main), .json(main)])
        XCTAssertEqual(Set(catalog.signatureChoices), Set([Driver.Signatures.sqlite(main)] + variants.map { .json($0) }))
        XCTAssertFalse(catalog.signatureChoices.contains(.absent))
        for choice in catalog.signatureChoices { XCTAssertEqual(try plan(catalog, signature: choice).signatures, choice) }
        XCTAssertThrowsError(try plan(catalog))
        XCTAssertThrowsError(try plan(catalog, signature: .sqlite(main + ".backup")))
        // Binary-looking damaged contents were neither decoded nor reclassified.
        for path in variants { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data([0xff, 0x00])) }
    }

    func testCompanionOnlyAndInterruptedMigrationResidueFailClosed() throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let root = try root()
            try Data().write(to: root.appendingPathComponent(main + suffix))
            XCTAssertThrowsError(try Catalog.inspect(root: root)) { XCTAssertEqual($0 as? Catalog.Failure, .noSignatureSource) }
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let root = try root()
            let path = main + ".migration-in-progress" + suffix
            try Data().write(to: root.appendingPathComponent(path))
            XCTAssertThrowsError(try Catalog.inspect(root: root)) { XCTAssertEqual($0 as? Driver.Failure, .interruptedLegacyMigration) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
    }

    func testValidatedMapsJoinFixedAbsentPathsAndDriverRechecksChangedInventory() throws {
        let root = try root()
        let mapDirectory = root.appendingPathComponent("download-names-v1")
        try FileManager.default.createDirectory(at: mapDirectory, withIntermediateDirectories: false)
        let mapName = String(repeating: "a", count: 64) + ".json"
        let map = "download-names-v1/" + mapName
        try Data("{}".utf8).write(to: root.appendingPathComponent(map))
        let catalog = try Catalog.inspect(root: root)
        XCTAssertEqual(catalog.legacyFiles, Driver.fixedLegacyPaths.union([map]).sorted())
        let selected = try plan(catalog)
        let added = "download-names-v1/" + String(repeating: "b", count: 64) + ".json"
        try Data("{}".utf8).write(to: root.appendingPathComponent(added))
        let temporary = try self.root()
        XCTAssertThrowsError(try Driver(root: root, temporaryDirectory: temporary).migrateSelectedSources(selected)) {
            XCTAssertEqual($0 as? Driver.Failure, .incompleteInventory(added))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
        try Data("{}".utf8).write(to: mapDirectory.appendingPathComponent("not-a-map.json"))
        XCTAssertThrowsError(try Catalog.inspect(root: root))
    }

    func testUnknownSpecialLinkedAndUnsafeRootsFailWithoutCreatingOrChangingSources() throws {
        for kind in 0..<5 {
            let root = try root()
            let primary = Version3JSONStoreConversion.primaryFilenames.sorted()[0]
            let path = root.appendingPathComponent(primary)
            if kind == 0 { try Data("unknown".utf8).write(to: root.appendingPathComponent("future-store-v4.json")) }
            if kind == 1 { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("absent")) }
            if kind == 2 { XCTAssertEqual(mkfifo(path.path, 0o600), 0) }
            if kind == 3 { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            if kind == 4 {
                try Data("retained".utf8).write(to: path)
                XCTAssertEqual(Darwin.link(path.path, root.appendingPathComponent(primary + ".backup").path), 0)
            }
            XCTAssertThrowsError(try Catalog.inspect(root: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
        }
        let root = try root(), missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try Catalog.inspect(root: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try Catalog.inspect(root: alias))
    }

    func testReservedFilesAndOpaqueArchivesArePreservedButExistingMigrationIsNotReplanned() throws {
        let root = try root()
        for name in [".v3-runtime.lock", ".v3-migration.lock", ".DS_Store"] { try Data("reserved".utf8).write(to: root.appendingPathComponent(name)) }
        let retained = root.appendingPathComponent(".v3-migration-retained")
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: false)
        try Data("opaque historical recovery".utf8).write(to: retained.appendingPathComponent("previous.data"))
        let catalog = try Catalog.inspect(root: root)
        XCTAssertEqual(catalog.legacyFiles, Driver.fixedLegacyPaths.sorted())
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("previous.data")), Data("opaque historical recovery".utf8))
        try Data("malformed boundary".utf8).write(to: root.appendingPathComponent(".v3-storage-boundary.json"))
        XCTAssertThrowsError(try Catalog.inspect(root: root)) { XCTAssertEqual($0 as? Catalog.Failure, .migrationAlreadyExists) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".v3-storage-boundary.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v3"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try Catalog.inspect(root: root)) { XCTAssertEqual($0 as? Catalog.Failure, .migrationAlreadyExists) }
    }

    func testCountBytesDeadlineAndCancellationAreBounded() async throws {
        let root = try root()
        var limits = Catalog.Limits(); limits.maximumFiles = 1
        XCTAssertThrowsError(try Catalog.inspect(root: root, limits: limits)) { XCTAssertEqual($0 as? Driver.Failure, .limitExceeded) }
        limits = Catalog.Limits(); limits.timeout = .leastNonzeroMagnitude
        XCTAssertThrowsError(try Catalog.inspect(root: root, limits: limits)) { XCTAssertEqual($0 as? Driver.Failure, .inventoryDeadlineExceeded) }
        limits.timeout = .infinity
        XCTAssertThrowsError(try Catalog.inspect(root: root, limits: limits))
        let name = Version3JSONStoreConversion.primaryFilenames.sorted()[0]
        try Data(repeating: 0, count: 4097).write(to: root.appendingPathComponent(name))
        limits = Catalog.Limits(); limits.maximumBytes = 4096
        XCTAssertThrowsError(try Catalog.inspect(root: root, limits: limits)) { XCTAssertEqual($0 as? Driver.Failure, .limitExceeded) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Catalog.inspect(root: root)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)).count, 4097)
    }
}
