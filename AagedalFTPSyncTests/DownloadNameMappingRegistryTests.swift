import Darwin
import Foundation
import XCTest
@testable import AagedalFTPSync

final class DownloadNameMappingRegistryTests: XCTestCase {
    private let mappingName = String(repeating: "a", count: 64) + ".json"
    private struct InjectedFailure: Error {}

    private func layout() throws -> AppStorageLayout {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mapping-registry-\(UUID())")
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        try FileManager.default.createDirectory(at: layout.downloadNamesDirectory, withIntermediateDirectories: true)
        try DownloadNameMappingRegistry.initialData(committedMappingNames: []).write(to: layout.downloadNameRegistry)
        return layout
    }

    private func state(_ layout: AppStorageLayout) throws -> DownloadNameMappingRegistry.State {
        try VersionedStoreCodec(format: .version3, store: .downloadNameRegistry).decode(
            DownloadNameMappingRegistry.State.self, from: Data(contentsOf: layout.downloadNameRegistry), decoder: JSONDecoder())
    }

    private func saveMap(_ layout: AppStorageLayout, name: String, names: [String: String], mappingID: String? = nil) throws {
        let codec = VersionedStoreCodec(format: .version3, store: name.hasSuffix(".replace") ? .downloadReplacementNames : .downloadNames)
        try codec.encode(DownloadNameMappingStorage.Version3State(mappingID: mappingID ?? name, names: names, newestDates: [:]),
                         encoder: JSONEncoder()).write(to: layout.downloadNamesDirectory.appendingPathComponent(name), options: .atomic)
    }

    private func fails(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected admission failure", file: file, line: line) }
        catch {}
    }

    func testProvisionBothModesAndReopenCommittedMapWithoutReplacingContent() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        for filename in [mappingName, mappingName + ".replace"] {
            let registry = try DownloadNameMappingRegistry(storage: layout)
            let url = try await registry.admitOrProvision(fileName: filename)
            XCTAssertEqual(try state(layout).entries[filename], .committed)
            try saveMap(layout, name: filename, names: ["photo.jpg": "photo.jpg"])
            let bytes = try Data(contentsOf: url)
            let reopened = try DownloadNameMappingRegistry(storage: layout)
            let reopenedURL = try await reopened.admitOrProvision(fileName: filename)
            XCTAssertEqual(reopenedURL, url)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertEqual(try state(layout).entries.count, 2)
    }

    func testInterruptedProvisioningResumesExactPreparedMapAcrossInstances() async throws {
        for interruption in [DownloadNameMappingRegistry.Checkpoint.preparedRecorded, .mappingCreated, .committedRecorded] {
            let layout = try layout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let first = try DownloadNameMappingRegistry(storage: layout)
            await fails {
                _ = try await first.admitOrProvision(fileName: self.mappingName) { checkpoint in
                    if checkpoint == interruption { throw InjectedFailure() }
                }
            }
            XCTAssertNotNil(try state(layout).entries[mappingName])
            let second = try DownloadNameMappingRegistry(storage: layout)
            let url = try await second.admitOrProvision(fileName: mappingName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try state(layout).entries[mappingName], .committed)
        }
    }

    func testCommittedMissingReceiptNeverRecreated() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        let url = try await registry.admitOrProvision(fileName: mappingName)
        let bytes = try Data(contentsOf: layout.downloadNameRegistry)
        try FileManager.default.removeItem(at: url)
        let reopened = try DownloadNameMappingRegistry(storage: layout)
        await fails { _ = try await reopened.admitOrProvision(fileName: self.mappingName) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: layout.downloadNameRegistry), bytes)
    }

    func testMissingFutureAndMalformedRegistryCannotAuthorizeProvisioning() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        try FileManager.default.removeItem(at: layout.downloadNameRegistry)
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.downloadNameRegistry.path))
        for source in ["broken", "{}", "{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":4,\"store\":\"downloadNameRegistry\",\"payload\":{\"entries\":{}}}"] {
            let bytes = Data(source.utf8)
            try bytes.write(to: layout.downloadNameRegistry)
            await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
            XCTAssertEqual(try Data(contentsOf: layout.downloadNameRegistry), bytes)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.downloadNamesDirectory.path).isEmpty)
        }
    }

    func testOrphanAndNonemptyPreparedMapsArePreservedForExplicitRecovery() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        let url = layout.downloadNamesDirectory.appendingPathComponent(mappingName)
        try saveMap(layout, name: mappingName, names: ["photo.jpg": "photo.jpg"])
        let orphan = try Data(contentsOf: url)
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        XCTAssertEqual(try state(layout).entries.count, 0)
        XCTAssertEqual(try Data(contentsOf: url), orphan)
        try FileManager.default.removeItem(at: url)
        await fails {
            _ = try await registry.admitOrProvision(fileName: self.mappingName) { checkpoint in
                if checkpoint == .preparedRecorded { throw InjectedFailure() }
            }
        }
        try saveMap(layout, name: mappingName, names: ["photo.jpg": "photo.jpg"])
        let preparedBefore = try Data(contentsOf: url)
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        XCTAssertEqual(try state(layout).entries[mappingName], .prepared)
        XCTAssertEqual(try Data(contentsOf: url), preparedBefore)
    }

    func testCommittedFutureSwappedAndUnsafeMappingPayloadsNeverAdmit() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        let url = try await registry.admitOrProvision(fileName: mappingName)
        for names in [["folder/photo.jpg": "elsewhere/photo.jpg"], ["photo.jpg": "photo.JPG"], ["photo.jpg": "../photo.jpg"]] {
            try saveMap(layout, name: mappingName, names: names)
            let bytes = try Data(contentsOf: url)
            await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        try saveMap(layout, name: mappingName, names: [:], mappingID: "wrong.json")
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        let future = Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":4,\"store\":\"downloadNames\",\"payload\":{}}".utf8)
        try future.write(to: url)
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testProvisioningRespectsCrossInstanceLockAndInvalidNames() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        for invalid in ["../outside.json", "identity.json", String(repeating: "A", count: 64) + ".json", mappingName + ".backup"] {
            await fails { _ = try await registry.admitOrProvision(fileName: invalid) }
        }
        let fd = Darwin.open(layout.root.appendingPathComponent(".download-name-registry.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        XCTAssertEqual(try state(layout).entries.count, 0)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        _ = try await registry.admitOrProvision(fileName: mappingName)
        XCTAssertEqual(try state(layout).entries[mappingName], .committed)
    }

    func testMigratedCommittedRegistryCannotAdmitSymlinkedMap() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try DownloadNameMappingRegistry.initialData(committedMappingNames: [mappingName]).write(to: layout.downloadNameRegistry)
        let other = layout.root.appendingPathComponent("unrelated")
        let original = Data("preserve".utf8)
        try original.write(to: other)
        try FileManager.default.createSymbolicLink(at: layout.downloadNamesDirectory.appendingPathComponent(mappingName), withDestinationURL: other)
        let registry = try DownloadNameMappingRegistry(storage: layout)
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        XCTAssertEqual(try Data(contentsOf: other), original)
    }

    func testPureLegacyConversionPreservesMappingsDatesAndRegistersCompleteSet() throws {
        let normal = try JSONEncoder().encode(["photo.jpg": "photo (2).jpg"])
        let replacement = Data("{\"names\":{\"PHOTO.JPG\":\"PHOTO.JPG\"},\"newestDates\":{\"photo.jpg\":123.125}}".utf8)
        let input = [mappingName: normal, mappingName + ".replace": replacement]
        let output = try DownloadNameMappingRegistry.convertLegacyMappings(input)
        XCTAssertEqual(output.count, 3)
        let registry = try VersionedStoreCodec(format: .version3, store: .downloadNameRegistry).decode(
            DownloadNameMappingRegistry.State.self, from: XCTUnwrap(output["download-name-registry-v3.json"]), decoder: JSONDecoder())
        XCTAssertEqual(Set(registry.entries.keys), Set(input.keys))
        XCTAssertTrue(registry.entries.values.allSatisfy { $0 == .committed })
        let converted = try VersionedStoreCodec(format: .version3, store: .downloadReplacementNames).decode(
            DownloadNameMappingStorage.Version3State.self, from: XCTUnwrap(output["download-names-v1/" + mappingName + ".replace"]), decoder: JSONDecoder())
        XCTAssertEqual(converted.names, ["PHOTO.JPG": "PHOTO.JPG"])
        XCTAssertEqual(converted.newestDates["photo.jpg"]?.timeIntervalSinceReferenceDate, 123.125)
        XCTAssertEqual(input[mappingName], normal)
        XCTAssertEqual(input[mappingName + ".replace"], replacement)
        XCTAssertThrowsError(try DownloadNameMappingRegistry.convertLegacyMappings([mappingName: Data("broken".utf8)]))
        XCTAssertThrowsError(try DownloadNameMappingRegistry.convertLegacyMappings([mappingName: try JSONEncoder().encode(["photo.jpg": "elsewhere/photo.jpg"])]))
        XCTAssertThrowsError(try DownloadNameMappingRegistry.convertLegacyMappings([mappingName + ".replace": Data("{\"names\":{},\"newestDates\":{},\"version\":4}".utf8)]))
    }
    func testCurrentCollectionValidatesRuntimeMapsBeyondInitialManifest() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        // The initial migration contains only an empty registry. Runtime maps
        // deliberately never become part of its immutable installation manifest.
        let legacyRoot = layout.root.appendingPathComponent("migration")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: false)
        let storage = VersionedAppStorage(root: legacyRoot)
        let initial = try DownloadNameMappingRegistry.convertLegacyMappings([:])
        let v3 = try storage.openOrMigrate(plan: .init(legacyFiles: []), convert: { _ in initial },
                                          validate: DownloadNameMappingRegistry.validateCurrentMappings)
        let current = AppStorageLayout(root: v3, storageFormat: .version3)
        try FileManager.default.createDirectory(at: current.downloadNamesDirectory, withIntermediateDirectories: false)
        let manifestURL = v3.appendingPathComponent("storage-manifest.json")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let registry = try DownloadNameMappingRegistry(storage: current)
        _ = try await registry.admitOrProvision(fileName: mappingName)
        try saveMap(current, name: mappingName, names: ["photo.jpg": "photo (2).jpg"])
        let root = legacyRoot
        let name = mappingName
        let opened = try await registry.withValidatedCurrentMappings { snapshot in
            try VersionedAppStorage(root: root).openOrMigrate(plan: .init(legacyFiles: []), convert: { _ in
                XCTFail("Committed storage must not reconvert")
                return [:]
            }, validate: { files in
                try DownloadNameMappingRegistry.validateCurrentMappings(in: files)
                for (path, bytes) in snapshot { XCTAssertEqual(files[path], bytes) }
                XCTAssertNotNil(files["download-names-v1/" + name])
            }, currentStorePaths: DownloadNameMappingRegistry.currentStorePaths)
        }
        XCTAssertEqual(opened, v3)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
    }

    func testCurrentCollectionRejectsMissingOrphanAndCorruptReceipts() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        let url = try await registry.admitOrProvision(fileName: mappingName)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        await fails { try await registry.withValidatedCurrentMappings { _ in XCTFail("Missing receipt admitted") } }
        try bytes.write(to: url)
        let orphan = layout.downloadNamesDirectory.appendingPathComponent(String(repeating: "b", count: 64) + ".json")
        try bytes.write(to: orphan)
        await fails { try await registry.withValidatedCurrentMappings { _ in XCTFail("Orphan admitted") } }
        try FileManager.default.removeItem(at: orphan)
        try Data("broken".utf8).write(to: url)
        await fails { try await registry.withValidatedCurrentMappings { _ in XCTFail("Corrupt receipt admitted") } }
        XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
    }

    func testCurrentCollectionRequiresExplicitPreparedRecoveryAndHoldsProvisioningLock() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        await fails {
            _ = try await registry.admitOrProvision(fileName: self.mappingName) { stage in
                if stage == .mappingCreated { throw InjectedFailure() }
            }
        }
        let before = try Data(contentsOf: layout.downloadNameRegistry)
        await fails { try await registry.withValidatedCurrentMappings { _ in XCTFail("Prepared must require recovery") } }
        XCTAssertEqual(try Data(contentsOf: layout.downloadNameRegistry), before)
        _ = try await registry.admitOrProvision(fileName: mappingName)
        let lockPath = layout.root.appendingPathComponent(".download-name-registry.lock").path
        try await registry.withValidatedCurrentMappings { _ in
            let fd = Darwin.open(lockPath, O_RDWR | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { Darwin.close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1)
            XCTAssertEqual(errno, EWOULDBLOCK)
        }
    }

    func testCurrentCollectionAllowsOnlyEmptyRegistryWhenDirectoryAbsentAndRejectsLinks() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let registry = try DownloadNameMappingRegistry(storage: layout)
        try FileManager.default.removeItem(at: layout.downloadNamesDirectory)
        let count = try await registry.withValidatedCurrentMappings { $0.count }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.downloadNamesDirectory.path))
        let unrelated = layout.root.appendingPathComponent("unrelated-directory")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: layout.downloadNamesDirectory, withDestinationURL: unrelated)
        await fails { try await registry.withValidatedCurrentMappings { _ in XCTFail("Directory link admitted") } }
        try FileManager.default.removeItem(at: layout.downloadNamesDirectory)
        try FileManager.default.createDirectory(at: layout.downloadNamesDirectory, withIntermediateDirectories: false)
        let url = try await registry.admitOrProvision(fileName: mappingName)
        let original = try Data(contentsOf: url)
        let other = layout.root.appendingPathComponent("other-map")
        try original.write(to: other)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        await fails { try await registry.withValidatedCurrentMappings { _ in XCTFail("Map link admitted") } }
        XCTAssertEqual(try Data(contentsOf: other), original)
    }

    func testPureCurrentResolverRejectsPreparedFutureMissingAndUnregisteredMaps() throws {
        let empty = try DownloadNameMappingRegistry.convertLegacyMappings([:])
        XCTAssertEqual(try DownloadNameMappingRegistry.currentStorePaths(in: empty), [])
        XCTAssertThrowsError(try DownloadNameMappingRegistry.currentStorePaths(in: [:]))
        let codec = VersionedStoreCodec(format: .version3, store: .downloadNameRegistry)
        let prepared = try codec.encode(DownloadNameMappingRegistry.State(entries: [mappingName: .prepared]), encoder: JSONEncoder())
        XCTAssertThrowsError(try DownloadNameMappingRegistry.currentStorePaths(in: ["download-name-registry-v3.json": prepared]))
        var future = try XCTUnwrap(String(data: XCTUnwrap(empty["download-name-registry-v3.json"]), encoding: .utf8))
        future = future.replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":4")
        XCTAssertThrowsError(try DownloadNameMappingRegistry.currentStorePaths(in: ["download-name-registry-v3.json": Data(future.utf8)]))
        var orphan = empty
        orphan["download-names-v1/" + mappingName] = Data()
        XCTAssertThrowsError(try DownloadNameMappingRegistry.validateCurrentMappings(in: orphan))
        let required = ["download-name-registry-v3.json": try DownloadNameMappingRegistry.initialData(committedMappingNames: [mappingName])]
        XCTAssertThrowsError(try DownloadNameMappingRegistry.validateCurrentMappings(in: required))
    }

    func testFirstProvisionCreatesAbsentDirectoryButNeverRebuildsCommittedDirectory() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try FileManager.default.removeItem(at: layout.downloadNamesDirectory)
        let registry = try DownloadNameMappingRegistry(storage: layout)
        let url = try await registry.admitOrProvision(fileName: mappingName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try state(layout).entries[mappingName], .committed)
        try FileManager.default.removeItem(at: layout.downloadNamesDirectory)
        let before = try Data(contentsOf: layout.downloadNameRegistry)
        await fails { _ = try await registry.admitOrProvision(fileName: self.mappingName) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.downloadNamesDirectory.path))
        XCTAssertEqual(try Data(contentsOf: layout.downloadNameRegistry), before)
    }

}
