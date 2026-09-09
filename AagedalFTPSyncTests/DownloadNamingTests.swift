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

final class DownloadNamingTests: XCTestCase {
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
            XCTAssertEqual(first.transferred, 1)
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
            XCTAssertEqual(downloads, ["PHOTO.jpg", "PHOTO.JPG"])
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
