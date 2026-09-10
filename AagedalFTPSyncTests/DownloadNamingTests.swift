import Foundation
import XCTest
@testable import AagedalFTPSync

private actor NamedDownloadSource: DownloadListingSession {
    var contents: [String: Data]
    var dates: [String: Date] = [:]
    var downloads: [String] = []
    var removals: [String] = []
    var changesOnRead: [String: Data] = [:]
    func changeOnNextRead(_ path: String, data: Data) { changesOnRead[path] = data }
    nonisolated var supportsCompletedDirectoryListings: Bool { true }
    init(_ contents: [String: Data]) { self.contents = contents }
    func set(_ path: String, data: Data?, date: Date = Date(timeIntervalSince1970: 1_900_000_000)) {
        contents[path] = data; dates[path] = date
    }
    func listFiles() async throws -> [String: SyncFile] { try await listing(allow: false, callback: nil) }
    func listDownloadFiles(onCompletedDirectory: (@Sendable (CompletedDirectoryListing) async throws -> Void)?) async throws -> [String: SyncFile] {
        try await listing(allow: true, callback: onCompletedDirectory)
    }
    private func listing(allow: Bool, callback: (@Sendable (CompletedDirectoryListing) async throws -> Void)?) async throws -> [String: SyncFile] {
        let entries = contents.map { name, data in RemoteDirectoryEntry(name: name, isDirectory: false, size: Int64(data.count),
            modifiedAt: dates[name] ?? Date(timeIntervalSince1970: 1_800_000_000), hasAuthoritativeTimestamp: true) }
        return try await RemoteTreeWalker.listFiles(root: "/", allowFileCaseCollisions: allow,
            join: { $0 + $1 }, listDirectory: { _ in entries }, onCompletedDirectory: callback)
    }
    func exportFile(_ file: SyncFile, to temporaryURL: URL) throws {
        try exportFile(file, to: temporaryURL, maximumSize: nil)
    }
    func exportFile(_ file: SyncFile, to temporaryURL: URL, maximumSize: Int64?) throws {
        if let changed = changesOnRead.removeValue(forKey: file.relativePath) { contents[file.relativePath] = changed }
        guard let data = contents[file.relativePath] else { throw AppError.transferFailed("Missing exact server name") }
        downloads.append(file.relativePath)
        if let maximumSize {
            var limit = try TransferSizeLimit(maximumBytes: maximumSize)
            // Leave staged partial bytes, just as a streaming read can before growth is detected.
            let initial = min(data.count, Int(maximumSize))
            try data.prefix(initial).write(to: temporaryURL)
            try limit.record(initial)
            try limit.record(data.count - initial)
        }
        try data.write(to: temporaryURL)
    }
    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool, verifySize: Bool) throws {
        XCTFail("A download must not upload or rename the server file")
    }
    func removeFilesTransactionally(_ files: [SyncFile], matching expected: [URL]) throws {
        for (file, url) in zip(files, expected) {
            guard contents[file.relativePath] == (try Data(contentsOf: url)) else { throw AppError.transferFailed("Source changed") }
        }
        for file in files { removals.append(file.relativePath); contents.removeValue(forKey: file.relativePath) }
    }
    func close() {}
}

private enum NamingCheckpointTestError: Error { case stopListing }

/// Emits many completed directories without networking. The operation hook checks
/// the persistence boundary from inside the delegated source, before any effects.
private actor CheckpointDownloadSource: DownloadListingSession {
    let batches: [[String]]
    let beforeOperation: @Sendable (SyncFile) throws -> Void
    var exports: [String] = []
    var removals: [String] = []
    nonisolated let supportsCompletedDirectoryListings = true

    init(_ batches: [[String]], beforeOperation: @escaping @Sendable (SyncFile) throws -> Void = { _ in }) {
        self.batches = batches
        self.beforeOperation = beforeOperation
    }

    func listFiles() async throws -> [String: SyncFile] {
        try await listDownloadFiles(onCompletedDirectory: nil)
    }

    func listDownloadFiles(onCompletedDirectory: (@Sendable (CompletedDirectoryListing) async throws -> Void)?) async throws -> [String: SyncFile] {
        var result: [String: SyncFile] = [:]
        for paths in batches {
            try Task.checkCancellation()
            let files = paths.map { SyncFile(relativePath: $0, size: 0, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)) }
            let directory = (paths[0] as NSString).deletingLastPathComponent
            try await onCompletedDirectory?(CompletedDirectoryListing(relativeDirectory: directory,
                entries: files.map { RemoteTreeEntry(relativePath: $0.relativePath, file: $0, hasAuthoritativeTimestamp: true) },
                validatedAncestors: []))
            for file in files { result[file.relativePath] = file }
        }
        return result
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) throws {
        try beforeOperation(file)
        exports.append(file.relativePath)
        try Data().write(to: temporaryURL)
    }
    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool, verifySize: Bool) throws {
        XCTFail("A download must not upload to its source")
    }
    func removeFile(_ file: SyncFile) throws {
        try beforeOperation(file)
        removals.append(file.relativePath)
    }
    func removeFilesTransactionally(_ files: [SyncFile]) throws {
        for file in files { try beforeOperation(file) }
        removals.append(contentsOf: files.map(\.relativePath))
    }
    func removeFilesTransactionally(_ files: [SyncFile], matching contents: [URL]) throws {
        try removeFilesTransactionally(files)
    }
    func close() {}
}

final class DownloadNamingTests: XCTestCase {
    func testDirectoryDiscoveryCheckpointsOnceAndUnchangedPollDoesNotRewrite() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mappingURL = root.appendingPathComponent("names.json")
        let batches = (0..<80).map { ["D\($0)/PHOTO.JPG", "D\($0)/PHOTO.jpg"] }
        let source = CheckpointDownloadSource(batches)
        let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: mappingURL)
        let files = try await adapter.listFilesIncrementally { _ in
            XCTAssertFalse(FileManager.default.fileExists(atPath: mappingURL.path),
                "Directory discovery alone must not repeatedly serialize cumulative mappings")
        }
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
        XCTAssertEqual(saved.count, 160)
        XCTAssertEqual(Set(saved.values), Set(files.keys))
        let oldDate = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: mappingURL.path)
        let restarted = DownloadNamingSession(source: source, destination: destination, mappingURL: mappingURL)
        let again = try await restarted.listFiles()
        XCTAssertEqual(Set(again.keys), Set(files.keys))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: mappingURL.path)[.modificationDate] as? Date, oldDate)
    }

    func testEarlyExportCheckpointsBeforeReadingAndSurvivesInterruptedListing() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mappingURL = root.appendingPathComponent("names.json")
        let source = CheckpointDownloadSource([["A/PHOTO.JPG", "A/PHOTO.jpg"], ["B/LATER.JPG"]]) { file in
            let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
            XCTAssertNotNil(saved[file.relativePath], "The delegated source cannot read before its association is durable")
        }
        let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: mappingURL)
        do {
            _ = try await adapter.listFilesIncrementally { listing in
                if listing.relativeDirectory == "B" { throw NamingCheckpointTestError.stopListing }
                let alias = try XCTUnwrap(listing.entries.compactMap(\.file).first { $0.originalRelativePath == "A/PHOTO.jpg" })
                try await adapter.exportFile(alias, to: root.appendingPathComponent("staged"), maximumSize: 0)
            }
            XCTFail("The fake scanner must interrupt after the first directory")
        } catch NamingCheckpointTestError.stopListing {}
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
        XCTAssertEqual(saved.count, 2, "Unpublished discoveries after the last checkpoint may remain unsaved")
        let alias = try XCTUnwrap(saved["A/PHOTO.jpg"])
        let nextSource = CheckpointDownloadSource([["A/PHOTO.jpg"]])
        let restarted = DownloadNamingSession(source: nextSource, destination: destination, mappingURL: mappingURL)
        let restored = try await restarted.listFiles()
        XCTAssertEqual(restored[alias]?.originalRelativePath, "A/PHOTO.jpg")
        let exports = await source.exports
        XCTAssertEqual(exports, ["A/PHOTO.jpg"])
    }

    func testEveryRemovalEntryPointCheckpointsBeforeSourceMutation() async throws {
        for operation in 0..<3 {
            let (root, _, destination) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let mappingURL = root.appendingPathComponent("names.json")
            let source = CheckpointDownloadSource([["A/PHOTO.JPG", "A/PHOTO.jpg"]]) { file in
                let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
                XCTAssertNotNil(saved[file.relativePath])
            }
            let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: mappingURL)
            _ = try await adapter.listFilesIncrementally { listing in
                let file = try XCTUnwrap(listing.entries.compactMap(\.file).first { $0.originalRelativePath != nil })
                switch operation {
                case 0: try await adapter.removeFile(file)
                case 1: try await adapter.removeFilesTransactionally([file])
                default: try await adapter.removeFilesTransactionally([file], matching: [root.appendingPathComponent("fixture")])
                }
            }
            let removals = await source.removals
            XCTAssertEqual(removals, ["A/PHOTO.jpg"])
        }
    }

    func testFailedEarlyCheckpointPreventsExportAndRemovalAndCanRetry() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("blocked")
        try Data().write(to: parent)
        let mappingURL = parent.appendingPathComponent("names.json")
        let source = CheckpointDownloadSource([["PHOTO.JPG", "PHOTO.jpg"]])
        let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: mappingURL)
        do {
            _ = try await adapter.listFilesIncrementally { listing in
                let file = try XCTUnwrap(listing.entries.compactMap(\.file).first { $0.originalRelativePath != nil })
                do { try await adapter.exportFile(file, to: root.appendingPathComponent("staged")); XCTFail("Checkpoint must fail") }
                catch {}
                do { try await adapter.removeFilesTransactionally([file]); XCTFail("Checkpoint must fail") }
                catch {}
                throw NamingCheckpointTestError.stopListing
            }
            XCTFail("Expected interrupted listing")
        } catch NamingCheckpointTestError.stopListing {}
        let exports = await source.exports, removals = await source.removals
        XCTAssertTrue(exports.isEmpty)
        XCTAssertTrue(removals.isEmpty)
        try FileManager.default.removeItem(at: parent)
        let files = try await adapter.listFiles()
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
        XCTAssertEqual(Set(saved.values), Set(files.keys), "A failed checkpoint must retain dirty state for a safe retry")
    }

    func testCancelledEarlyOperationCannotCheckpointOrReadSource() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mappingURL = root.appendingPathComponent("names.json")
        let source = CheckpointDownloadSource([["PHOTO.JPG"]])
        let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: mappingURL)
        let task = Task {
            try await adapter.listFilesIncrementally { listing in
                let file = try XCTUnwrap(listing.entries.compactMap(\.file).first)
                withUnsafeCurrentTask { $0?.cancel() }
                try await adapter.exportFile(file, to: root.appendingPathComponent("staged"))
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled operation must fail") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: mappingURL.path))
        let exports = await source.exports
        XCTAssertTrue(exports.isEmpty)
    }

    func testDownloadTimePersistsEarlyDownloadReceiptAcrossRestartAndDetectsResend() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource([:])
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        await source.set("PHOTO.JPG", data: Data("old".utf8), date: sourceDate)
        var job = SyncJob()
        job.left = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
        job.right = endpoint
        job.preserveModificationDates = false
        func engine() -> SyncEngine {
            SyncEngine(
                sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
                sessionFactory: { entry, _, _ -> any EndpointSession in entry.kind.isRemote ? source : destination }
            )
        }
        let first = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(first.transferred, 1)
        let restarted = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(restarted.transferred, 0)

        // A same-size resend is still older than the local arrival timestamp.
        await source.set("PHOTO.JPG", data: Data("new".utf8), date: sourceDate.addingTimeInterval(1))
        let updated = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(updated.transferred, 1)
        let unchanged = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(unchanged.transferred, 0)
        let downloads = await source.downloads
        XCTAssertEqual(downloads, ["PHOTO.JPG", "PHOTO.JPG"])
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("PHOTO.JPG")),
            Data("new".utf8)
        )
    }

    func testSidecarOnlyChangesDownloadWithPhotosFilter() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["TA_001.NEF": Data("camera raw".utf8), "TA_001.xmp": Data("metadata".utf8)])
        var job = SyncJob()
        job.left = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
        job.right = endpoint
        job.filter.photographerInitials = "TA"
        let engine = SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
            sessionFactory: { entry, _, _ -> any EndpointSession in entry.kind.isRemote ? source : destination })
        let first = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(first.transferred, 1)
        await source.set("TA_001.xmp", data: Data("updated metadata".utf8))
        let updated = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(updated.transferred, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("TA_001.xmp")), Data("updated metadata".utf8))
        let unchanged = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(unchanged.transferred, 0)
    }

    func testExcludedReturnUploadsDoNotBlockDownloadsOrPublishEarly() async throws {
        for overwrite in [false, true] {
            let (root, endpoint, destination) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = NamedDownloadSource([
                "TA_001.JPG": Data("camera original".utf8),
                "TA_001_EDITED.JPG": Data("uploaded edit".utf8),
                "TA_003_aftpsync.JPG": Data("another user's upload".utf8),
                "TA_004_aftpsync.NEF": Data(), "TA_004_aftpsync.nef": Data(),
                "TA_002_EDITED.NEF": Data(), "TA_002_EDITED.nef": Data(),
                "OTHER.NEF": Data(), "other.nef": Data()
            ])
            var job = SyncJob(name: "Filtered downloads")
            job.left = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
            job.right = endpoint
            job.overwritesCaseVariantDownloads = overwrite
            job.filter = FileFilter(photographerInitials: "TA", excludedFilenameSuffixes: "_EDITED")
            job.filter.ignoresAFTPSyncUploads = true
            let engine = SyncEngine(
                sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
                sessionFactory: { entry, _, _ -> any EndpointSession in
                    entry.kind.isRemote ? source : destination
                })
            let result = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(result.transferred, 1)
            let paths = try await destination.listFiles().keys.sorted()
            XCTAssertEqual(paths, ["TA_001.JPG"])
            let reads = await source.downloads
            XCTAssertEqual(reads, ["TA_001.JPG"])
        }
    }

    private func fixture() throws -> (URL, Endpoint, LocalEndpointSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        var endpoint = Endpoint(kind: .local)
        endpoint.localPath = local.path
        endpoint.bookmark = try local.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        return (root, endpoint, try LocalEndpointSession(endpoint: endpoint))
    }

    func testDownloadKeepsBothContentsAndStableNamesAcrossRestartAndSourceRemoval() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["PHOTO.JPG": Data("upper".utf8), "PHOTO.jpg": Data("lower".utf8)])
        var job = SyncJob(name: "Case-sensitive downloads")
        job.left = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
        job.right = endpoint
        let manifest = DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json"))
        func engine() -> SyncEngine {
            SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                downloadManifestRepository: manifest, sessionFactory: { entry, _, _ -> any EndpointSession in
                    if entry.kind.isRemote { return source }; return destination
                })
        }
        let first = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(first.transferred, 2)
        let files = try await destination.listFiles()
        XCTAssertEqual(files.count, 2)
        let alias = try XCTUnwrap(files.keys.first { $0.contains("~") })
        XCTAssertTrue(alias.hasPrefix("PHOTO~"))
        XCTAssertTrue(alias.hasSuffix(".jpg"))
        let local = URL(fileURLWithPath: endpoint.localPath)
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("PHOTO.JPG")), Data("upper".utf8))
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent(alias)), Data("lower".utf8))
        let second = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(second.transferred, 0)
        await source.set("PHOTO.JPG", data: nil)
        await source.set("PHOTO.jpg", data: Data("new lower".utf8))
        let third = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(third.transferred, 1)
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent(alias)), Data("new lower".utf8))
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("PHOTO.JPG")), Data("upper".utf8))
        let recorded = try await manifest.relativePaths(jobID: job.id, destinationEndpoint: endpoint)
        XCTAssertEqual(recorded, Set(files.keys))
        let originals = await source.downloads
        XCTAssertFalse(originals.contains { $0.contains("~") })
    }

    private func version3Storage() throws -> AppStorageLayout {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("naming-storage-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("profile")
        let temporary = root.appendingPathComponent("migration-temp")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let driver = Version3MigrationDriver(root: legacy, temporaryDirectory: temporary)
        let choices = Dictionary(uniqueKeysWithValues: Version3JSONStoreConversion.primaryFilenames.map {
            ($0, Version3MigrationDriver.Source.absent)
        })
        return try driver.migrateSelectedSources(.init(legacyFiles: Array(Version3MigrationDriver.fixedLegacyPaths),
            primarySources: choices, signatures: .absent, calendar: Calendar(identifier: .gregorian),
            migrationDate: Date(timeIntervalSince1970: 1_800_000_000))).storage
    }

    func testVersion3EngineProvisionsBothDirectionsAndModesAndRefusesLostReceipts() async throws {
        for reverse in [false, true] {
            for overwrite in [false, true] {
                let (root, endpoint, destination) = try fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                let storage = try version3Storage()
                let remote = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
                var job = SyncJob(name: "V3 downloads")
                job.left = reverse ? endpoint : remote
                job.right = reverse ? remote : endpoint
                job.direction = reverse ? .rightToLeft : .leftToRight
                job.overwritesCaseVariantDownloads = overwrite
                let source = NamedDownloadSource(["photo.jpg": Data("picture".utf8)])
                let engine = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(storage: storage),
                    downloadManifestRepository: DownloadManifestRepository(storage: storage),
                    sessionFactory: { entry, _, _ -> any EndpointSession in
                        if entry.kind.isRemote { return source }; return destination
                    })
                let result = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(result.transferred, 1)
                let second = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(second.transferred, 0)
                let base = DownloadNamingSession.mappingURL(directory: storage.downloadNamesDirectory,
                    job: job, source: remote, destination: endpoint)
                let mapping = overwrite ? base.appendingPathExtension("replace") : base
                XCTAssertTrue(FileManager.default.fileExists(atPath: mapping.path))
                let registryBytes = try Data(contentsOf: storage.downloadNameRegistry)
                let registry = try VersionedStoreCodec(format: .version3, store: .downloadNameRegistry)
                    .decode(DownloadNameMappingRegistry.State.self, from: registryBytes, decoder: JSONDecoder())
                XCTAssertEqual(registry.entries[mapping.lastPathComponent], .committed)
                try FileManager.default.removeItem(at: mapping)
                let blocked = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(storage: storage),
                    downloadManifestRepository: DownloadManifestRepository(storage: storage), sessionFactory: { _, _, _ in
                        XCTFail("Admission failure must precede opening either endpoint")
                        throw NamingCheckpointTestError.stopListing
                    })
                do { _ = try await blocked.run(job: job, leftPassword: nil, rightPassword: nil); XCTFail("Lost receipt admitted") }
                catch { }
                XCTAssertFalse(FileManager.default.fileExists(atPath: mapping.path))
                XCTAssertEqual(try Data(contentsOf: storage.downloadNameRegistry), registryBytes)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("photo.jpg")), Data("picture".utf8))
            }
        }
    }

    func testVersion3EngineRefusesMissingAndPreparedRegistryBeforeOpeningEndpoints() async throws {
        for prepared in [false, true] {
            let (root, endpoint, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let storage = try version3Storage()
            if prepared {
                let codec = VersionedStoreCodec(format: .version3, store: .downloadNameRegistry)
                try codec.encode(DownloadNameMappingRegistry.State(entries: [String(repeating: "a", count: 64) + ".json": .prepared]),
                    encoder: JSONEncoder()).write(to: storage.downloadNameRegistry)
            } else { try FileManager.default.removeItem(at: storage.downloadNameRegistry) }
            let before = try? Data(contentsOf: storage.downloadNameRegistry)
            var job = SyncJob(name: "Blocked v3 downloads")
            job.left = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
            job.right = endpoint
            let engine = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(storage: storage),
                downloadManifestRepository: DownloadManifestRepository(storage: storage), sessionFactory: { _, _, _ in
                    XCTFail("Registry recovery must precede opening endpoints")
                    throw NamingCheckpointTestError.stopListing
                })
            do { _ = try await engine.run(job: job, leftPassword: nil, rightPassword: nil); XCTFail("Invalid registry admitted") }
            catch { }
            let photographer = PhotographerProfile(name: "Test", filenamePrefix: "TEST", creator: "Test", copyrightNotice: "")
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
            job.metadataAutomation = MetadataAutomation(isEnabled: true, timestampPolicy: .sourceModification,
                photographers: [photographer], clips: [MetadataScheduleClip(photographerID: photographer.id,
                    name: "Test", startsAt: timestamp, endsAt: timestamp.addingTimeInterval(60),
                    fields: ScheduledMetadataFields(headline: "Preserve until admitted"))])
            do { _ = try await engine.reprocessExistingLocalFiles(job: job); XCTFail("Reprocessing admitted invalid registry") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Source modification times could not be loaded")) }
            XCTAssertEqual(try? Data(contentsOf: storage.downloadNameRegistry), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.downloadNamesDirectory.path))
        }
    }

    func testExistingLowercaseFileKeepsItsNameAndNewUppercaseFileGetsAlias() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("photo.jpg"))
        let source = NamedDownloadSource(["PHOTO.JPG": Data("incoming".utf8), "photo.jpg": Data("existing".utf8)])
        let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: root.appendingPathComponent("names.json"))
        let files = try await adapter.listFiles()
        XCTAssertNotNil(files["photo.jpg"])
        XCTAssertNil(files["PHOTO.JPG"])
        XCTAssertEqual(files.values.first { $0.originalRelativePath == "PHOTO.JPG" }?.filterPath, "PHOTO.JPG")
    }

    func testAliasDoesNotClaimAnExistingLocalOrServerFilename() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["PHOTO.JPG": Data(), "PHOTO.jpg": Data()])
        let first = DownloadNamingSession(source: source, destination: destination, mappingURL: root.appendingPathComponent("first.json"))
        let firstFiles = try await first.listFiles()
        let alias = try XCTUnwrap(firstFiles.keys.first { $0.contains("~") })
        try Data("unrelated".utf8).write(to: URL(fileURLWithPath: endpoint.localPath).appendingPathComponent(alias))
        await source.set(alias, data: Data("separate server file".utf8))
        let next = DownloadNamingSession(source: source, destination: destination, mappingURL: root.appendingPathComponent("next.json"))
        let files = try await next.listFiles()
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[alias]?.originalRelativePath, nil)
        XCTAssertNotEqual(files.values.first { $0.originalRelativePath == "PHOTO.jpg" }?.relativePath, alias)
        XCTAssertNil(PathSafety.localPathCollision(in: Array(files.keys)))
    }

    func testCorruptOrUnwritableMappingsPreventPublication() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["PHOTO.JPG": Data(), "PHOTO.jpg": Data()])
        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corrupt)
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedParent)
        for url in [corrupt, blockedParent.appendingPathComponent("names.json")] {
            let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: url)
            do { _ = try await adapter.listFiles(); XCTFail("Unsafe mapping must fail") } catch {}
        }
        let downloads = await source.downloads
        XCTAssertTrue(downloads.isEmpty)
    }

    func testVerifiedRemovalUsesExactOriginalName() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["PHOTO.JPG": Data("upper".utf8), "PHOTO.jpg": Data("lower".utf8)])
        let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: root.appendingPathComponent("names.json"))
        let files = try await adapter.listFiles()
        let alias = try XCTUnwrap(files.values.first { $0.originalRelativePath != nil })
        let temporary = root.appendingPathComponent("download")
        try await adapter.exportFile(alias, to: temporary)
        try await adapter.removeFilesTransactionally([alias], matching: [temporary])
        let remaining = await source.contents
        XCTAssertEqual(remaining, ["PHOTO.JPG": Data("upper".utf8)])
        let removed = await source.removals
        XCTAssertEqual(removed, ["PHOTO.jpg"])
    }

    func testRAWAndXMPCollisionsRemainExplicit() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for names in [["PHOTO.NEF", "PHOTO.nef"], ["PHOTO.xmp", "photo.xmp"]] {
            let source = NamedDownloadSource(Dictionary(uniqueKeysWithValues: names.map { ($0, Data()) }))
            let adapter = DownloadNamingSession(source: source, destination: destination, mappingURL: root.appendingPathComponent(UUID().uuidString))
            do { _ = try await adapter.listFiles(); XCTFail("Ambiguous companion must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("RAW/XMP")) }
        }
    }

    func testOptInListingStillRejectsCaseEquivalentDirectoriesAndDuplicateFiles() async throws {
        for (names, directory) in [(["Photos", "photos"], true), (["PHOTO.JPG", "PHOTO.JPG"], false), (["Café.jpg", "Cafe\u{301}.jpg"], false)] {
            do {
                _ = try await RemoteTreeWalker.listFiles(root: "/", allowFileCaseCollisions: true, join: { $0 + $1 }, listDirectory: { _ in
                    names.map { RemoteDirectoryEntry(name: $0, isDirectory: directory, size: 0, modifiedAt: .distantPast, hasAuthoritativeTimestamp: true) }
                }, onCompletedDirectory: nil)
                XCTFail("Unsafe listing must fail")
            } catch {}
        }
    }
}

extension DownloadNamingTests {
    func testOverwriteOptionDownloadsNewestVariantOnceAndUpdatesSameLocalName() async throws {
        for reverse in [false, true] {
            let (root, endpoint, destination) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = NamedDownloadSource(["PHOTO.JPG": Data("older".utf8)])
            let unrelated = URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("OTHER.JPG")
            try Data("unchanged".utf8).write(to: unrelated)
            await source.set("OTHER.JPG", data: Data("unchanged".utf8), date: Date(timeIntervalSince1970: 1_500_000_000))
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            await source.set("PHOTO.JPG", data: Data("older".utf8), date: date)
            await source.set("PHOTO.jpg", data: Data("newer".utf8), date: date.addingTimeInterval(60))
            var job = SyncJob(name: "Repeated photo delivery")
            let remote = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
            job.left = reverse ? endpoint : remote
            job.right = reverse ? remote : endpoint
            job.direction = reverse ? .rightToLeft : .leftToRight
            job.overwritesCaseVariantDownloads = true
            job.preserveModificationDates = !reverse
            let manifest = DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json"))
            func engine() -> SyncEngine {
                SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                    downloadManifestRepository: manifest, sessionFactory: { entry, _, _ -> any EndpointSession in
                        if entry.kind.isRemote { return source }; return destination
                    })
            }
            let first = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
            // Download-time jobs establish a source receipt once for the preexisting OTHER.JPG.
            XCTAssertEqual(first.transferred, reverse ? 2 : 1)
            let initial = try await destination.listFiles()
            XCTAssertEqual(Set(initial.keys), ["PHOTO.jpg", "OTHER.JPG"])
            let target = URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("PHOTO.jpg")
            XCTAssertEqual(try Data(contentsOf: target), Data("newer".utf8))
            let second = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(second.transferred, 0)
            await source.set("PHOTO.JPG", data: Data("newest".utf8), date: date.addingTimeInterval(120))
            let third = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(third.transferred, 1)
            XCTAssertEqual(try Data(contentsOf: target), Data("newest".utf8))
            let updated = try await destination.listFiles()
            XCTAssertEqual(Set(updated.keys), ["PHOTO.jpg", "OTHER.JPG"])
            // Removing the newest variant must not replay the older resend.
            await source.set("PHOTO.JPG", data: nil)
            let fourth = try await engine().run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(fourth.transferred, 0)
            XCTAssertEqual(try Data(contentsOf: target), Data("newest".utf8))
            let downloads = await source.downloads
            XCTAssertEqual(downloads, reverse ? ["PHOTO.jpg", "OTHER.JPG", "PHOTO.JPG"] : ["PHOTO.jpg", "PHOTO.JPG"])
        }
    }

    func testOverwriteOptionReusesExistingCaseVariantAndIgnoresPreviousRenamedCopies() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = URL(fileURLWithPath: endpoint.localPath)
        try Data("existing".utf8).write(to: folder.appendingPathComponent("Photo.jpg"))
        let oldCopy = folder.appendingPathComponent("PHOTO~1234567890.jpg")
        try Data("previous separate copy".utf8).write(to: oldCopy)
        let source = NamedDownloadSource(["PHOTO.JPG": Data("upper".utf8), "PHOTO.jpg": Data("lower".utf8)])
        let adapter = DownloadNamingSession(source: source, destination: destination, overwriteCaseVariants: true,
            mappingURL: root.appendingPathComponent("names.json"))
        let files = try await adapter.listFiles()
        XCTAssertEqual(Set(files.keys), ["Photo.jpg"])
        let selected = try XCTUnwrap(files["Photo.jpg"])
        XCTAssertEqual(selected.originalRelativePath, "PHOTO.JPG") // Stable tie-break.
        XCTAssertEqual(try Data(contentsOf: oldCopy), Data("previous separate copy".utf8))
        XCTAssertFalse(adapter.supportsCompletedDirectoryListings)
    }

    func testOverwriteCanRecoverMissingDestinationFromOlderRemainingVariant() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["PHOTO.JPG": Data("old".utf8)])
        await source.set("PHOTO.jpg", data: Data("new".utf8))
        let url = root.appendingPathComponent("names.json")
        let first = DownloadNamingSession(source: source, destination: destination, overwriteCaseVariants: true, mappingURL: url)
        _ = try await first.listFiles()
        await source.set("PHOTO.jpg", data: nil)
        let restarted = DownloadNamingSession(source: source, destination: destination, overwriteCaseVariants: true, mappingURL: url)
        let files = try await restarted.listFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.values.first?.filterPath, "PHOTO.JPG")
    }

    func testOverwriteModeStillRejectsAmbiguousRAWCompanions() async throws {
        let (root, _, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["PHOTO.NEF": Data(), "photo.nef": Data()])
        let adapter = DownloadNamingSession(source: source, destination: destination, overwriteCaseVariants: true,
            mappingURL: root.appendingPathComponent("names.json"))
        do { _ = try await adapter.listFiles(); XCTFail("RAW ambiguity must remain explicit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("RAW/XMP")) }
    }

    func testOverwriteOptionDefaultsOffForOldJobsAndRoundTrips() throws {
        var job = SyncJob()
        XCTAssertFalse(job.overwritesCaseVariantDownloads)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object.removeValue(forKey: "overwriteCaseVariantDownloads")
        let legacy = try JSONDecoder().decode(SyncJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.overwritesCaseVariantDownloads)
        job.overwritesCaseVariantDownloads = true
        let restored = try JSONDecoder().decode(SyncJob.self, from: JSONEncoder().encode(job))
        XCTAssertTrue(restored.overwritesCaseVariantDownloads)
        job.direction = .bidirectional
        XCTAssertFalse(job.supportsCaseVariantDownloads)
    }
}

extension DownloadNamingTests {
    func testGrowingDownloadDefersUntilFreshListingAndOtherFilesContinue() async throws {
        for kind in [EndpointKind.ftp, .sftp] {
            let (root, endpoint, destination) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = NamedDownloadSource(["GROWING.JPG": Data("part".utf8), "READY.JPG": Data("complete".utf8)])
            await source.changeOnNextRead("GROWING.JPG", data: Data("complete upload".utf8))
            var job = SyncJob(name: "Growing uploads")
            job.left = Endpoint(kind: kind, host: "sync.example.org", username: "example")
            job.left.hostKeyFingerprint = "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            job.right = endpoint
            let engine = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
                sessionFactory: { entry, _, _ -> any EndpointSession in if entry.kind.isRemote { return source }; return destination })
            let first = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(first.transferred, 1)
            XCTAssertEqual(first.pendingSourceFiles, ["GROWING.JPG"])
            XCTAssertTrue(first.summary?.contains("deferred") == true)
            let initialFiles = try await destination.listFiles()
            XCTAssertEqual(Set(initialFiles.keys), ["READY.JPG"])
            let initialDownloads = await source.downloads
            XCTAssertEqual(initialDownloads.filter { $0 == "GROWING.JPG" }.count, 1, "Do not retry against the same stale size")
            let second = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(second.transferred, 1)
            XCTAssertTrue(second.pendingSourceFiles.isEmpty)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("GROWING.JPG")), Data("complete upload".utf8))
        }
    }

    func testShortDownloadPreservesPreviousCompleteLocalCopy() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = URL(fileURLWithPath: endpoint.localPath).appendingPathComponent("PHOTO.JPG")
        try Data("previous complete local copy".utf8).write(to: target)
        let source = NamedDownloadSource(["PHOTO.JPG": Data("new upload advertised length".utf8)])
        await source.changeOnNextRead("PHOTO.JPG", data: Data("short".utf8))
        var job = SyncJob(name: "Changing upload")
        job.left = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
        job.right = endpoint
        let engine = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
            sessionFactory: { entry, _, _ -> any EndpointSession in if entry.kind.isRemote { return source }; return destination })
        let result = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(result.transferred, 0)
        XCTAssertEqual(result.pendingSourceFiles, ["PHOTO.JPG"])
        XCTAssertEqual(try Data(contentsOf: target), Data("previous complete local copy".utf8))
        let removed = await source.removals
        XCTAssertTrue(removed.isEmpty)
    }

    func testGrowingSidecarDefersEntireRAWGroup() async throws {
        let (root, endpoint, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NamedDownloadSource(["PHOTO.NEF": Data("raw".utf8), "PHOTO.xmp": Data("part".utf8)])
        await source.changeOnNextRead("PHOTO.xmp", data: Data("complete sidecar".utf8))
        var job = SyncJob(name: "RAW upload")
        job.left = Endpoint(kind: .ftp, host: "sync.example.org", username: "example")
        job.right = endpoint
        let engine = SyncEngine(sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
            sessionFactory: { entry, _, _ -> any EndpointSession in if entry.kind.isRemote { return source }; return destination })
        let first = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(first.transferred, 0)
        XCTAssertEqual(first.pendingSourceFiles, ["PHOTO.xmp"])
        let initial = try await destination.listFiles()
        XCTAssertTrue(initial.isEmpty, "Neither the RAW nor its companion should be published alone")
        let second = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
        XCTAssertEqual(second.transferred, 1)
        let complete = try await destination.listFiles()
        XCTAssertEqual(Set(complete.keys), ["PHOTO.NEF", "PHOTO.xmp"])
    }

    func testDeferredSourceStatusSurvivesCombiningResultsAndShowsAsWarning() {
        let pending = SyncResult(transferred: 0, deleted: 0, pendingSourceFiles: ["PHOTO.JPG"])
        let combined = pending.adding(SyncResult(transferred: 2, deleted: 1))
        XCTAssertEqual(combined.pendingSourceFiles, ["PHOTO.JPG"])
        let phase = JobPhase.succeeded(Date(), transferred: 2, deleted: 1, processed: 0, conflicts: [], metadataReport: .empty,
            nextRun: Date().addingTimeInterval(5), pendingSourceFiles: combined.pendingSourceFiles)
        XCTAssertTrue(phase.label.contains("deferred until next sync"))
    }
}
