import Foundation
import XCTest
@testable import AagedalFTPSync

final class VersionedRepositoryTests: XCTestCase {
    private struct RepositoryCase {
        let store: VersionedStoreCodec.Store
        let url: URL
        let save: () throws -> Void
        let loadRecovered: () throws -> Bool
    }

    private func cases(_ layout: AppStorageLayout) -> [RepositoryCase] {
        [
            RepositoryCase(store: .jobs, url: layout.jobs,
                           save: { try JobRepository(storage: layout).save([]) },
                           loadRecovered: { try JobRepository(storage: layout).loadResult().recoveredFromBackup }),
            RepositoryCase(store: .metadataPresets, url: layout.metadataPresets,
                           save: { try MetadataPresetRepository(storage: layout).save([]) },
                           loadRecovered: { try MetadataPresetRepository(storage: layout).loadResult().recoveredFromBackup }),
            RepositoryCase(store: .photographers, url: layout.photographers,
                           save: { try PhotographerProfileRepository(storage: layout).save([]) },
                           loadRecovered: { try PhotographerProfileRepository(storage: layout).loadResult().recoveredFromBackup }),
            RepositoryCase(store: .serverProfiles, url: layout.serverProfiles,
                           save: { try ServerProfileRepository(storage: layout).save([]) },
                           loadRecovered: { try ServerProfileRepository(storage: layout).loadResult().recoveredFromBackup }),
            RepositoryCase(store: .metadataAudit, url: layout.metadataAudit,
                           save: { _ = try MetadataAuditRepository(storage: layout).save([]) },
                           loadRecovered: { try MetadataAuditRepository(storage: layout).loadResult().recoveredFromBackup }),
            RepositoryCase(store: .syncFailures, url: layout.syncFailures,
                           save: { _ = try SyncFailureRepository(storage: layout).save([]) },
                           loadRecovered: { try SyncFailureRepository(storage: layout).loadResult().recoveredFromBackup })
        ]
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("versioned-repositories-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seed(_ store: VersionedStoreCodec.Store, at url: URL) throws {
        try VersionedStoreCodec(format: .version3, store: store)
            .encode([String](), encoder: JSONEncoder()).write(to: url)
    }

    private func envelope(_ store: VersionedStoreCodec.Store, version: Int = 3, payload: String = "[]") -> Data {
        Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":\(version),\"store\":\"\(store.rawValue)\",\"payload\":\(payload)}".utf8)
    }

    func testSixRepositoriesRequireExplicitInitialStoresAndRetainLegacyEmptyBehavior() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let versioned = AppStorageLayout(root: root, storageFormat: .version3)
        for entry in cases(versioned) {
            XCTAssertThrowsError(try entry.loadRecovered()) { XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .missingStore) }
            XCTAssertThrowsError(try entry.save()) { XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .missingStore) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
            try seed(entry.store, at: entry.url)
            try entry.save()
            XCTAssertFalse(try entry.loadRecovered())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entry.url)) as? [String: Any])
            XCTAssertEqual(object["store"] as? String, entry.store.rawValue)
            XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        }
        let legacy = AppStorageLayout(root: root.appendingPathComponent("legacy", isDirectory: true))
        for entry in cases(legacy) {
            XCTAssertFalse(try entry.loadRecovered())
            try entry.save()
            XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(contentsOf: entry.url)) is [Any])
        }
    }

    func testSixRepositoriesRecoverOnlySupportedPayloadDamageAndProtectFutureStores() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for entry in cases(AppStorageLayout(root: root, storageFormat: .version3)) {
            try seed(entry.store, at: entry.url)
            try entry.save()
            let backup = entry.url.appendingPathExtension("backup")
            let originalBackup = try Data(contentsOf: backup)
            try envelope(entry.store, payload: "42").write(to: entry.url)
            XCTAssertTrue(try entry.loadRecovered())
            try entry.save()
            XCTAssertFalse(try entry.loadRecovered())
            XCTAssertEqual(try Data(contentsOf: backup), originalBackup)

            let future = envelope(entry.store, version: 4)
            try future.write(to: entry.url)
            XCTAssertThrowsError(try entry.loadRecovered()) { XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .unsupportedVersion(4)) }
            XCTAssertThrowsError(try entry.save()) { XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .unsupportedVersion(4)) }
            XCTAssertEqual(try Data(contentsOf: entry.url), future)
            XCTAssertEqual(try Data(contentsOf: backup), originalBackup)

            try envelope(entry.store).write(to: entry.url)
            try future.write(to: backup)
            XCTAssertThrowsError(try entry.save()) { XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .unsupportedVersion(4)) }
            XCTAssertEqual(try Data(contentsOf: backup), future)
            try envelope(entry.store, payload: "42").write(to: entry.url)
            XCTAssertThrowsError(try entry.loadRecovered()) { XCTAssertEqual($0 as? VersionedStoreCodec.HeaderError, .unsupportedVersion(4)) }
            XCTAssertEqual(try Data(contentsOf: backup), future)
        }
    }

    func testVersionedRepositoriesNeverInterpretLegacyOrWrongStoreAsPayload() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for entry in cases(AppStorageLayout(root: root, storageFormat: .version3)) {
            try seed(entry.store, at: entry.url.appendingPathExtension("backup"))
            for bytes in [Data("[]".utf8), envelope(.metadataCalendar)] {
                try bytes.write(to: entry.url)
                XCTAssertThrowsError(try entry.loadRecovered()) { XCTAssertTrue($0 is VersionedStoreCodec.HeaderError) }
                XCTAssertThrowsError(try entry.save()) { XCTAssertTrue($0 is VersionedStoreCodec.HeaderError) }
                XCTAssertEqual(try Data(contentsOf: entry.url), bytes)
            }
        }
    }

    func testPresetAndFailureRoundTripsPreserveLiteralFieldsAndISODates() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        try seed(.metadataPresets, at: layout.metadataPresets)
        try seed(.syncFailures, at: layout.syncFailures)
        let preset = MetadataPreset(name: "Literal {unknown}", fields: ScheduledMetadataFields(
            headline: "{gps:city}", description: "unbalanced {photographer", keywords: ["Doe, Jane", "{persons}"]))
        try MetadataPresetRepository(storage: layout).save([preset])
        XCTAssertEqual(try MetadataPresetRepository(storage: layout).load(), [preset])
        let failure = SyncFailureRecord(jobID: UUID(), occurredAt: Date(timeIntervalSince1970: 1_700_000_000), message: "fixture")
        try SyncFailureRepository(storage: layout).save([failure])
        XCTAssertEqual(try SyncFailureRepository(storage: layout).loadResult().entries, [failure])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: layout.syncFailures)) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [[String: Any]])
        XCTAssertEqual(payload.first?["occurredAt"] as? String, "2023-11-14T22:13:20Z")
    }

    func testManifestRoundTripRecoveryAndCachedWriterProtectFuturePrimary() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let repository = DownloadManifestRepository(storage: layout)
        let destination = Endpoint(kind: .local, localPath: root.appendingPathComponent("photos").path)
        let jobID = UUID()
        do { _ = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination); XCTFail() }
        catch { XCTAssertEqual(error as? VersionedStoreCodec.HeaderError, .missingStore) }
        do { try await repository.record(relativePaths: ["one.jpg"], jobID: jobID, destinationEndpoint: destination); XCTFail() }
        catch { XCTAssertEqual(error as? VersionedStoreCodec.HeaderError, .missingStore) }
        try seed(.downloadManifest, at: layout.downloadManifest)
        try await repository.record(relativePaths: ["one.jpg"], jobID: jobID, destinationEndpoint: destination)
        try await repository.record(relativePaths: ["two.jpg"], jobID: jobID, destinationEndpoint: destination)
        let reopened = DownloadManifestRepository(storage: layout)
        let paths = try await reopened.relativePaths(jobID: jobID, destinationEndpoint: destination)
        XCTAssertEqual(paths, ["one.jpg", "two.jpg"])
        let backup = layout.downloadManifest.appendingPathExtension("backup")
        let originalBackup = try Data(contentsOf: backup)
        try envelope(.downloadManifest, payload: "42").write(to: layout.downloadManifest)
        let recovered = try await DownloadManifestRepository(storage: layout).relativePaths(jobID: jobID, destinationEndpoint: destination)
        XCTAssertEqual(recovered, ["one.jpg"])
        let future = envelope(.downloadManifest, version: 4)
        try future.write(to: layout.downloadManifest)
        do { try await repository.record(relativePaths: ["three.jpg"], jobID: jobID, destinationEndpoint: destination); XCTFail() }
        catch { XCTAssertEqual(error as? VersionedStoreCodec.HeaderError, .unsupportedVersion(4)) }
        XCTAssertEqual(try Data(contentsOf: layout.downloadManifest), future)
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
        try FileManager.default.removeItem(at: layout.downloadManifest)
        do { _ = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination); XCTFail() }
        catch { XCTAssertEqual(error as? VersionedStoreCodec.HeaderError, .missingStore) }
    }

    func testManifestCacheReloadsSameVersionAtomicAndInPlaceReplacements() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        try seed(.downloadManifest, at: layout.downloadManifest)
        let repository = DownloadManifestRepository(storage: layout)
        let destination = Endpoint(kind: .local, localPath: root.appendingPathComponent("photos").path)
        let jobID = UUID()
        try await repository.record(relativePaths: ["one.jpg"], jobID: jobID, destinationEndpoint: destination)
        let before = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination)
        XCTAssertEqual(before, ["one.jpg"])
        let firstBytes = try Data(contentsOf: layout.downloadManifest)
        let secondBytes = Data(try XCTUnwrap(String(data: firstBytes, encoding: .utf8)).replacingOccurrences(of: "one.jpg", with: "two.jpg").utf8)
        try secondBytes.write(to: layout.downloadManifest, options: .atomic)
        let afterAtomic = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination)
        XCTAssertEqual(afterAtomic, ["two.jpg"])
        let thirdBytes = Data(try XCTUnwrap(String(data: secondBytes, encoding: .utf8)).replacingOccurrences(of: "two.jpg", with: "six.jpg").utf8)
        XCTAssertEqual(thirdBytes.count, secondBytes.count)
        let handle = try FileHandle(forWritingTo: layout.downloadManifest)
        try handle.write(contentsOf: thirdBytes)
        try handle.synchronize()
        try handle.close()
        let afterInPlace = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination)
        XCTAssertEqual(afterInPlace, ["six.jpg"])
        for _ in 0..<5 {
            let unchanged = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination)
            XCTAssertEqual(unchanged, ["six.jpg"])
        }
    }

    func testManifestRecoveryRevalidatesChangedBackupOnEveryRead() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        try seed(.downloadManifest, at: layout.downloadManifest)
        let repository = DownloadManifestRepository(storage: layout)
        let destination = Endpoint(kind: .local, localPath: root.appendingPathComponent("photos").path)
        let jobID = UUID()
        try await repository.record(relativePaths: ["one.jpg"], jobID: jobID, destinationEndpoint: destination)
        try await repository.record(relativePaths: ["two.jpg"], jobID: jobID, destinationEndpoint: destination)
        try envelope(.downloadManifest, payload: "42").write(to: layout.downloadManifest)
        let recovered = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination)
        XCTAssertEqual(recovered, ["one.jpg"])
        let futureBackup = envelope(.downloadManifest, version: 4)
        try futureBackup.write(to: layout.downloadManifest.appendingPathExtension("backup"), options: .atomic)
        do {
            _ = try await repository.relativePaths(jobID: jobID, destinationEndpoint: destination)
            XCTFail("The changed incompatible backup must not return cached ownership")
        } catch { XCTAssertEqual(error as? VersionedStoreCodec.HeaderError, .unsupportedVersion(4)) }
        XCTAssertEqual(try Data(contentsOf: layout.downloadManifest.appendingPathExtension("backup")), futureBackup)
    }
}
