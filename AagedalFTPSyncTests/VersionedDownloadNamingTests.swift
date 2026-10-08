import Foundation
import XCTest
@testable import AagedalFTPSync

private actor VersionedNamingEndpoint: EndpointSession {
    var files: [String: SyncFile]
    var exports: [String] = []
    var removals: [String] = []
    init(_ files: [SyncFile] = []) { self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) }) }
    func setFiles(_ files: [SyncFile]) { self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) }) }
    func listFiles() -> [String: SyncFile] { files }
    func exportFile(_ file: SyncFile, to temporaryURL: URL) throws {
        exports.append(file.relativePath)
        try Data().write(to: temporaryURL)
    }
    func removeFile(_ file: SyncFile) { removals.append(file.relativePath) }
    func removeFilesTransactionally(_ files: [SyncFile]) { removals.append(contentsOf: files.map(\.relativePath)) }
    func removeFilesTransactionally(_ files: [SyncFile], matching contents: [URL]) { removals.append(contentsOf: files.map(\.relativePath)) }
    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool, verifySize: Bool) { XCTFail("Unexpected import") }
    func close() {}
}

final class VersionedDownloadNamingTests: XCTestCase {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("v3-naming-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func file(_ path: String, date: TimeInterval = 1_700_000_000) -> SyncFile {
        SyncFile(relativePath: path, size: 0, modifiedAt: Date(timeIntervalSince1970: date))
    }

    private func codec(_ replacing: Bool) -> VersionedStoreCodec {
        VersionedStoreCodec(format: .version3, store: replacing ? .downloadReplacementNames : .downloadNames)
    }

    private func save(_ state: DownloadNameMappingStorage.Version3State, to url: URL, replacing: Bool) throws {
        try codec(replacing).encode(state, encoder: JSONEncoder()).write(to: url, options: .atomic)
    }

    func testExplicitInitializerIsExclusiveAndSeparatesMappingModes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for replacing in [false, true] {
            let url = root.appendingPathComponent(replacing ? "identity.json.replace" : "identity.json")
            try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: url, overwriteCaseVariants: replacing)
            let bytes = try Data(contentsOf: url)
            let state = try codec(replacing).decode(DownloadNameMappingStorage.Version3State.self, from: bytes, decoder: JSONDecoder())
            XCTAssertEqual(state.mappingID, url.lastPathComponent)
            XCTAssertTrue(state.names.isEmpty)
            XCTAssertTrue(state.newestDates.isEmpty)
            XCTAssertThrowsError(try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: url, overwriteCaseVariants: replacing))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertThrowsError(try codec(!replacing).decode(DownloadNameMappingStorage.Version3State.self, from: bytes, decoder: JSONDecoder()))
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".download-name-initialization-") })
    }

    func testNormalMappingsPersistAliasesAcrossSessionsAndKeepExactSourceNames() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("identity.json")
        try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: url, overwriteCaseVariants: false)
        let source = VersionedNamingEndpoint([file("PHOTO.JPG"), file("PHOTO.jpg")])
        let destination = VersionedNamingEndpoint()
        let first = DownloadNamingSession(source: source, destination: destination, mappingURL: url, storageFormat: .version3)
        let files = try await first.listFiles()
        XCTAssertEqual(files.count, 2)
        let aliased = try XCTUnwrap(files.values.first { $0.originalRelativePath != nil })
        let bytes = try Data(contentsOf: url)
        let state = try codec(false).decode(DownloadNameMappingStorage.Version3State.self, from: bytes, decoder: JSONDecoder())
        XCTAssertEqual(state.names[try XCTUnwrap(aliased.originalRelativePath)], aliased.relativePath)
        let reopened = DownloadNamingSession(source: source, destination: destination, mappingURL: url, storageFormat: .version3)
        let reloaded = try await reopened.listFiles()
        XCTAssertEqual(Set(reloaded.keys), Set(files.keys))
        try await reopened.exportFile(aliased, to: root.appendingPathComponent("export"))
        try await reopened.removeFilesTransactionally([aliased], matching: [root.appendingPathComponent("export")])
        let exports = await source.exports
        let removals = await source.removals
        XCTAssertEqual(exports, [try XCTUnwrap(aliased.originalRelativePath)])
        XCTAssertEqual(removals, exports)
    }

    func testReplacementDatesSurviveReloadAndBlockStaleResend() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("identity.json")
        let url = base.appendingPathExtension("replace")
        try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: url, overwriteCaseVariants: true)
        let old = file("PHOTO.JPG", date: 1_700_000_000)
        let newest = file("PHOTO.jpg", date: 1_700_000_060)
        let source = VersionedNamingEndpoint([old, newest])
        let destination = VersionedNamingEndpoint([old])
        let first = DownloadNamingSession(source: source, destination: destination, overwriteCaseVariants: true,
                                          mappingURL: base, storageFormat: .version3)
        let files = try await first.listFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files["PHOTO.JPG"]?.modifiedAt, newest.modifiedAt)
        let state = try codec(true).decode(DownloadNameMappingStorage.Version3State.self, from: Data(contentsOf: url), decoder: JSONDecoder())
        XCTAssertEqual(state.newestDates[PathSafety.localComparisonKey(old.relativePath)], newest.modifiedAt)
        await source.setFiles([old])
        let reopened = DownloadNamingSession(source: source, destination: destination, overwriteCaseVariants: true,
                                             mappingURL: base, storageFormat: .version3)
        let stale = try await reopened.listFiles()
        XCTAssertTrue(stale.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    func testMissingOrIncompatibleMapsNeverAutoInitializeInEitherMode() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for replacing in [false, true] {
            let base = root.appendingPathComponent("missing-\(replacing).json")
            let url = replacing ? base.appendingPathExtension("replace") : base
            let source = VersionedNamingEndpoint([file("image.jpg")])
            let destination = VersionedNamingEndpoint()
            let create = { DownloadNamingSession(source: source, destination: destination,
                overwriteCaseVariants: replacing, mappingURL: base, storageFormat: .version3) }
            do { _ = try await create().listFiles(); XCTFail("Missing committed map must fail") } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let wrongStore = replacing ? "downloadNames" : "downloadReplacementNames"
            let payloads = [
                Data("{}".utf8),
                Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":4,\"store\":\"\(codec(replacing).store.rawValue)\",\"payload\":{}}".utf8),
                Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":3,\"store\":\"\(wrongStore)\",\"payload\":{}}".utf8)
            ]
            for bytes in payloads {
                try bytes.write(to: url)
                do { _ = try await create().listFiles(); XCTFail("Incompatible map must fail") } catch { }
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
            let exports = await source.exports
            let removals = await source.removals
            XCTAssertTrue(exports.isEmpty)
            XCTAssertTrue(removals.isEmpty)
        }
    }

    func testCleanCheckpointBlocksFutureOrDeletedMapBeforeEverySourceOperation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for replacing in [false, true] {
            for removeMap in [false, true] {
                let base = root.appendingPathComponent("map-\(replacing)-\(removeMap).json")
                let url = replacing ? base.appendingPathExtension("replace") : base
                try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: url, overwriteCaseVariants: replacing)
                let source = VersionedNamingEndpoint([file("image.jpg")])
                let session = DownloadNamingSession(source: source, destination: VersionedNamingEndpoint(),
                    overwriteCaseVariants: replacing, mappingURL: base, storageFormat: .version3)
                let files = try await session.listFiles()
                let mapped = try XCTUnwrap(files["image.jpg"])
                var future: Data?
                if removeMap { try FileManager.default.removeItem(at: url) }
                else {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                    object["schemaVersion"] = 4
                    future = try JSONSerialization.data(withJSONObject: object)
                    try future!.write(to: url, options: .atomic)
                }
                do { try await session.exportFile(mapped, to: root.appendingPathComponent("export")); XCTFail() } catch { }
                do { try await session.removeFile(mapped); XCTFail() } catch { }
                do { try await session.removeFilesTransactionally([mapped]); XCTFail() } catch { }
                do { try await session.removeFilesTransactionally([mapped], matching: []); XCTFail() } catch { }
                let exports = await source.exports
                let removals = await source.removals
                XCTAssertTrue(exports.isEmpty)
                XCTAssertTrue(removals.isEmpty)
                if let future { XCTAssertEqual(try Data(contentsOf: url), future) }
                else { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            }
        }
    }

    func testWrongMappingIdentityInvalidDatesAndUnsafeAssociationsFail() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("identity.json")
        let url = base.appendingPathExtension("replace")
        let cases = [
            DownloadNameMappingStorage.Version3State(mappingID: "another.json.replace", names: ["image.jpg": "image.jpg"], newestDates: [:]),
            DownloadNameMappingStorage.Version3State(mappingID: url.lastPathComponent, names: ["image.jpg": "image.jpg"], newestDates: ["unrelated": .now]),
            DownloadNameMappingStorage.Version3State(mappingID: url.lastPathComponent, names: ["../image.jpg": "image.jpg"], newestDates: [:])
        ]
        for state in cases {
            try save(state, to: url, replacing: true)
            let bytes = try Data(contentsOf: url)
            let session = DownloadNamingSession(source: VersionedNamingEndpoint([file("image.jpg")]), destination: VersionedNamingEndpoint(),
                overwriteCaseVariants: true, mappingURL: base, storageFormat: .version3)
            do { _ = try await session.listFiles(); XCTFail("Invalid mapping payload must fail") } catch { }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testInitializerRejectsSymlinkParentAndExistingSymlinkWithoutChangingTargets() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: link.appendingPathComponent("map.json"), overwriteCaseVariants: false))
        let target = root.appendingPathComponent("target.json")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: target)
        let linkedFile = root.appendingPathComponent("map.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: target)
        XCTAssertThrowsError(try DownloadNameMappingStorage.initializeNewVersion3Mapping(at: linkedFile, overwriteCaseVariants: false))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
    }

    func testLegacyDefaultStillCreatesOriginalFlatJSON() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.json")
        let session = DownloadNamingSession(source: VersionedNamingEndpoint([file("image.jpg")]),
                                            destination: VersionedNamingEndpoint(), mappingURL: url)
        _ = try await session.listFiles()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try Data(contentsOf: url), try encoder.encode(["image.jpg": "image.jpg"]))
    }

    func testEnginePropagatesVersionedFormatAndDoesNotCreateMissingMapping() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        try VersionedStoreCodec(format: .version3, store: .downloadManifest).encode([String](), encoder: JSONEncoder())
            .write(to: layout.downloadManifest)
        let source = VersionedNamingEndpoint([file("image.jpg")])
        let local = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        var endpoint = Endpoint(kind: .local, localPath: local.path)
        endpoint.bookmark = try local.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let destination = try LocalEndpointSession(endpoint: endpoint)
        var job = SyncJob(name: "Versioned naming fixture")
        job.left = Endpoint(kind: .ftp, host: "snapshot.invalid", username: "fixture")
        job.right = endpoint
        let manifest = DownloadManifestRepository(storage: layout)
        let engine = SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: manifest,
            sessionFactory: { entry, _, _ -> any EndpointSession in entry.kind.isRemote ? source : destination })
        do {
            _ = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTFail("Missing committed map must stop the engine")
        } catch { }
        let exports = await source.exports
        XCTAssertTrue(exports.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.downloadNamesDirectory.path))
        let localFiles = try FileManager.default.contentsOfDirectory(atPath: local.path)
        XCTAssertTrue(localFiles.isEmpty)
    }
}
