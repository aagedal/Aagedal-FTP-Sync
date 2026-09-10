import XCTest
@testable import AagedalFTPSync

final class AppStorageLayoutTests: XCTestCase {
    func testLegacyLayoutKeepsFoundationSupportLocationAndHistoricalNames() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("AagedalFTPSync", isDirectory: true)
        let layout = AppStorageLayout.legacy
        XCTAssertEqual(layout.root, root)
        let stores: [(URL, String)] = [
            (layout.jobs, "jobs-v2.json"),
            (layout.metadataPresets, "metadata-presets-v1.json"),
            (layout.photographers, "photographers-v1.json"),
            (layout.serverProfiles, "server-profiles-v1.json"),
            (layout.metadataCalendar, "metadata-sync-v1.json"),
            (layout.metadataSyncEvents, "metadata-sync-events-v1.json"),
            (layout.metadataAudit, "metadata-audit-v1.json"),
            (layout.syncFailures, "sync-errors-v1.json"),
            (layout.sourceSignatures, "original-source-signatures-v2.sqlite3"),
            (layout.legacySourceSignatures, "original-source-signatures-v1.json"),
            (layout.downloadManifest, "download-manifest-v1.json")
        ]
        for (url, name) in stores {
            XCTAssertEqual(url, root.appendingPathComponent(name))
        }
        XCTAssertEqual(layout.downloadNamesDirectory,
                       root.appendingPathComponent("download-names-v1", isDirectory: true))
    }

    func testConstructionAndMissingStoreReadsDoNotCreateOrMigrateDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root.appendingPathComponent("v3", isDirectory: true))
        XCTAssertTrue(try JobRepository(storage: layout).load().isEmpty)
        XCTAssertTrue(try MetadataPresetRepository(storage: layout).load().isEmpty)
        XCTAssertTrue(try PhotographerProfileRepository(storage: layout).load().isEmpty)
        XCTAssertTrue(try ServerProfileRepository(storage: layout).load().isEmpty)
        XCTAssertTrue(try MetadataAuditRepository(storage: layout).load().isEmpty)
        XCTAssertTrue(try SyncFailureRepository(storage: layout).loadResult().entries.isEmpty)
        XCTAssertTrue(try MetadataCalendarRepository(storage: layout).load().accounts.isEmpty)
        _ = DownloadManifestRepository(storage: layout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExplicitRootRoutesJSONStoresAndExistingBackupsWithoutTouchingLegacySibling() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacySentinel = root.appendingPathComponent("jobs-v2.json")
        let original = Data("retained legacy bytes".utf8)
        try original.write(to: legacySentinel)
        let layout = AppStorageLayout(root: root.appendingPathComponent("selected", isDirectory: true))

        for _ in 0..<2 {
            try JobRepository(storage: layout).save([])
            try MetadataPresetRepository(storage: layout).save([])
            try PhotographerProfileRepository(storage: layout).save([])
            try ServerProfileRepository(storage: layout).save([])
            try MetadataAuditRepository(storage: layout).save([])
            try SyncFailureRepository(storage: layout).save([])
            try MetadataCalendarRepository(storage: layout).save(MetadataCalendarState())
        }
        let withBackups = [layout.jobs, layout.metadataPresets, layout.photographers,
                           layout.serverProfiles, layout.metadataAudit, layout.syncFailures]
        for url in withBackups {
            XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: url.appendingPathExtension("backup")))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.metadataCalendar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.metadataCalendar.appendingPathExtension("backup").path))
        XCTAssertEqual(try Data(contentsOf: legacySentinel), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["jobs-v2.json", "selected"])
    }

    func testExplicitFileOverridesRetainBackupAndCalendarEventSiblingLocations() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unused = AppStorageLayout(root: root.appendingPathComponent("unused", isDirectory: true))
        let selected = root.appendingPathComponent("custom", isDirectory: true)
        let jobs = selected.appendingPathComponent("custom-jobs.json")
        let presets = selected.appendingPathComponent("custom-presets.json")
        let photographers = selected.appendingPathComponent("custom-photographers.json")
        let servers = selected.appendingPathComponent("custom-servers.json")
        let audit = selected.appendingPathComponent("custom-audit.json")
        let failures = selected.appendingPathComponent("custom-failures.json")
        for _ in 0..<2 {
            try JobRepository(fileURL: jobs, storage: unused).save([])
            try MetadataPresetRepository(fileURL: presets, storage: unused).save([])
            try PhotographerProfileRepository(fileURL: photographers, storage: unused).save([])
            try ServerProfileRepository(fileURL: servers, storage: unused).save([])
            try MetadataAuditRepository(fileURL: audit, storage: unused).save([])
            try SyncFailureRepository(fileURL: failures, storage: unused).save([])
        }
        for file in [jobs, presets, photographers, servers, audit, failures] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("backup").path))
        }
        let calendarURL = selected.appendingPathComponent("custom-calendar.json")
        let calendar = MetadataCalendarRepository(url: calendarURL, storage: unused)
        try calendar.save(MetadataCalendarState())
        XCTAssertEqual(calendar.eventsURL, selected.appendingPathComponent("metadata-sync-events-v1.json"))
        let events = MetadataSyncEventRepository(url: calendar.eventsURL)
        try events.save([MetadataSyncEvent(operation: "Fixture", detail: "Completed")])
        XCTAssertEqual(events.load().map(\.operation), ["Fixture"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: calendarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.root.path))
    }

    func testDownloadManifestInjectionKeepsMappingsBesideSelectedManifest() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root.appendingPathComponent("selected", isDirectory: true))
        let destination = Endpoint(kind: .local, localPath: root.appendingPathComponent("photos").path)
        let jobID = UUID()
        let manifest = DownloadManifestRepository(storage: layout)
        try await manifest.record(relativePaths: ["photo.jpg"], jobID: jobID, destinationEndpoint: destination)
        try await manifest.record(relativePaths: ["photo2.jpg"], jobID: jobID, destinationEndpoint: destination)
        let mappings = await manifest.nameMappingsDirectory
        XCTAssertEqual(mappings, layout.downloadNamesDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.downloadManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.downloadManifest.appendingPathExtension("backup").path))
        let reopened = DownloadManifestRepository(storage: layout)
        let paths = try await reopened.relativePaths(jobID: jobID, destinationEndpoint: destination)
        XCTAssertEqual(paths, ["photo.jpg", "photo2.jpg"])

        let customURL = root.appendingPathComponent("overridden/custom-manifest.json")
        let overridden = DownloadManifestRepository(fileURL: customURL, storage: layout)
        try await overridden.record(relativePaths: ["other.jpg"], jobID: jobID, destinationEndpoint: destination)
        let overriddenMappings = await overridden.nameMappingsDirectory
        XCTAssertEqual(overriddenMappings, root.appendingPathComponent("overridden/download-names-v1", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: customURL.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("storage-layout-\(UUID().uuidString)", isDirectory: true)
    }
}
