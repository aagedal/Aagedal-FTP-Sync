import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Isolated launch plumbing for UI tests and hosted unit tests. Neither test host
/// may start the user's normal jobs or load their Keychain credentials.
enum UITestSupport {
    static let enabled = ProcessInfo.processInfo.environment["AAGEDAL_UI_TESTING"] == "1"
    static let usesVersion3Startup = enabled
        && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_V3_STARTUP"] == "1"
    private static let hostedUnitTests = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static var sessionID: String? {
        if hostedUnitTests && !enabled {
            return "unit-\(ProcessInfo.processInfo.processIdentifier)"
        }
        guard enabled,
              let rawValue = ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_SESSION"] else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = rawValue.unicodeScalars.filter(allowed.contains).map(String.init).joined()
        return value.isEmpty ? nil : value
    }

    static var configurationPackageURL: URL? {
        rootURL?.appendingPathComponent("round-trip.aftpsync", isDirectory: false)
    }

    static var dynamicTypeSizeOverride: DynamicTypeSize? {
        guard enabled,
              ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_ACCESSIBILITY_TEXT"] == "1" else {
            return nil
        }
        return .accessibility3
    }

    /// Seeds only the explicitly isolated version-3 startup root. This keeps the
    /// destructive migration UI testable without copying a developer's real 2.9
    /// Application Support data or making the production bootstrap test-aware.
    static func seedVersion3StartupFixtureIfRequested(at rootURL: URL) throws {
        guard enabled,
              usesVersion3Startup,
              let fixture = ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_V3_FIXTURE"] else {
            return
        }
        let supportedFixtures = Set(["populated", "backup-only", "damaged-primary", "prepared-recovery"])
        guard supportedFixtures.contains(fixture) else { return }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let filename = fixture == "backup-only" ? "jobs-v2.json.backup" : "jobs-v2.json"
        let repository = JobRepository(fileURL: fileURL(filename, rootURL: rootURL))
        guard try repository.load().isEmpty else { return }

        var job = fixtureJob(rootURL: rootURL)
        switch fixture {
        case "backup-only": job.name = "Recovery Backup UI Fixture"
        case "prepared-recovery": job.name = "Prepared Recovery UI Fixture"
        default: job.name = "Migrated 2.9 UI Fixture"
        }
        job.isEnabled = true
        job.startsOnAppLaunch = true
        try repository.save([job])

        if fixture == "damaged-primary" {
            try Data(contentsOf: fileURL("jobs-v2.json", rootURL: rootURL))
                .write(to: fileURL("jobs-v2.json.backup", rootURL: rootURL))
            try Data("{\"damaged\":".utf8).write(to: fileURL("jobs-v2.json", rootURL: rootURL))
        } else if fixture == "prepared-recovery" {
            try prepareInterruptedVersion3Migration(at: rootURL)
            var changed = job
            changed.name = "Legacy Changed After Preparation"
            try repository.save([changed])
        }
    }

    @MainActor
    static func makeStore() -> AppStore? {
        guard let rootURL else { return nil }

        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fixture = fixtureJob(rootURL: rootURL)
        let jobRepository: JobRepository
        if enabled, ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_RECOVERY"] == "1" {
            do {
                if ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_RECONCILE_RECOVERY"] == "1" {
                    try reconcileMetadataRecoveryFixture(rootURL: rootURL, managed: managedRecoveryFixture)
                }
                jobRepository = try recoveryFixtureRepository(job: fixture, rootURL: rootURL)
            } catch {
                preconditionFailure("Unable to persist isolated metadata recovery fixture: \(error)")
            }
        } else {
            jobRepository = JobRepository(
                fileURL: fileURL("jobs-v2.json", rootURL: rootURL),
                beforeSave: oneShotJobSaveFailure()
            )
        }
        if ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_SEED_JOB"] == "1",
           (try? jobRepository.load().isEmpty) == true {
            try? jobRepository.save([fixture])
        }

        let sourceSignatures = SourceSignatureRepository(
            fileURL: fileURL("original-source-signatures-v1.json", rootURL: rootURL)
        )
        let serverProfileRepository = ServerProfileRepository(
            fileURL: fileURL("server-profiles-v1.json", rootURL: rootURL)
        )
        if ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_SEED_SERVER"] == "1",
           (try? serverProfileRepository.load().isEmpty) == true {
            try? serverProfileRepository.save([
                ServerProfile(
                    name: "Disposable UI Server",
                    kind: .ftp,
                    host: "server.test.invalid",
                    username: "fixture"
                )
            ])
        }
        let downloadManifest = DownloadManifestRepository(
            fileURL: fileURL("download-manifest-v1.json", rootURL: rootURL)
        )
        return AppStore(
            repository: jobRepository,
            metadataPresetRepository: MetadataPresetRepository(
                fileURL: fileURL("metadata-presets-v1.json", rootURL: rootURL)
            ),
            photographerProfileRepository: PhotographerProfileRepository(
                fileURL: fileURL("photographers-v1.json", rootURL: rootURL)
            ),
            serverProfileRepository: serverProfileRepository,
            metadataAuditRepository: MetadataAuditRepository(
                fileURL: fileURL("metadata-audit-v1.json", rootURL: rootURL)
            ),
            syncFailureRepository: SyncFailureRepository(
                fileURL: fileURL("sync-errors-v1.json", rootURL: rootURL)
            ),
            sourceSignatureRepository: sourceSignatures,
            downloadManifestRepository: downloadManifest,
            keychain: KeychainStore(
                passwordReader: { _ in nil },
                passwordWriter: { _, _ in },
                passwordRemover: { _ in }
            ),
            engine: SyncEngine(
                sourceSignatureRepository: sourceSignatures,
                downloadManifestRepository: downloadManifest
            ),
            failureNotificationCoordinator: SyncFailureNotificationCoordinator(
                delivery: UITestNotificationDelivery()
            ),
            launchAtLoginCoordinator: UITestLaunchAtLoginCoordinator(),
            jobDraftTemplate: fixture,
            peopleLibraryRepository: PeopleLibraryRepository(
                root: rootURL.appendingPathComponent("people-library", isDirectory: true)
            )
        )
    }

    @MainActor
    static func activateJobsWindow() {
        guard enabled else { return }
        RegularWindowController.shared.prepareForOpening(windowID: "jobs")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows
            .first(where: { $0.title == "Aagedal FTP Sync" })?
            .makeKeyAndOrderFront(nil)
    }

    static var rootURL: URL? {
        guard let sessionID else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalFTPSyncUITests", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    private static func fileURL(_ name: String, rootURL: URL) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: false)
    }

    private enum FixtureInterruption: Error { case preparedBoundary, unexpectedCompletion }

    /// Leaves a valid PREPARED boundary with no installed v3 directory. The later
    /// legacy edit proves that the recovery action uses the frozen snapshot rather
    /// than importing whatever an older app wrote after the interruption.
    private static func prepareInterruptedVersion3Migration(at rootURL: URL) throws {
        let catalog = try Version3MigrationSourceCatalog.inspect(root: rootURL)
        guard let signatures = catalog.recommendedSignatureSource else {
            throw FixtureInterruption.unexpectedCompletion
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let plan = try catalog.makePlan(
            primarySources: catalog.recommendedPrimarySources,
            signatures: signatures,
            calendar: calendar,
            migrationDate: Date(timeIntervalSince1970: 1_800_000_000)
        )
        do {
            _ = try Version3MigrationDriver(
                root: rootURL,
                temporaryDirectory: rootURL.deletingLastPathComponent()
            ).migrateSelectedSources(plan) { checkpoint in
                if case .boundaryPrepared = checkpoint {
                    throw FixtureInterruption.preparedBoundary
                }
            }
            throw FixtureInterruption.unexpectedCompletion
        } catch FixtureInterruption.preparedBoundary {
            return
        }
    }

    private static func fixtureJob(rootURL: URL) -> SyncJob {
        let sourcePath = rootURL.appendingPathComponent("Source", isDirectory: true).path
        let destinationPath = rootURL.appendingPathComponent("Destination", isDirectory: true).path
        let placeholderBookmark = Data("ui-test-folder-access".utf8)
        var job = SyncJob(name: "UI Smoke Fixture")
        job.left = Endpoint(kind: .local, localPath: sourcePath, bookmark: placeholderBookmark)
        job.right = Endpoint(kind: .local, localPath: destinationPath, bookmark: placeholderBookmark)
        if ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_SEED_REMOTE_JOB"] == "1" {
            // Inert loopback connection; the fixture job stays disabled and no
            // server operation is started by this editor-only UI test.
            job.left = Endpoint(kind: .ftp, host: "127.0.0.1", username: "ui-fixture",
                remotePath: "/incoming")
        }
        job.isEnabled = false
        job.startsOnAppLaunch = false
        if enabled, ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_RECOVERY"] == "1" {
            do {
                try seedMetadataRecoveryFixture(job: &job, rootURL: rootURL, managed: managedRecoveryFixture)
            } catch {
                preconditionFailure("Unable to prepare isolated metadata recovery fixture: \(error)")
            }
        }
        if ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_SEED_MAP"] == "1" {
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: Date())
            let photographer = PhotographerProfile(
                id: UUID(uuidString: "C542A26A-2872-42E5-B021-7AA3E599D3A8")!,
                name: "Map Photographer",
                filenamePrefix: "MAP",
                creator: "Map Photographer",
                copyrightNotice: ""
            )
            let clip = MetadataScheduleClip(
                id: UUID(uuidString: "D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")!,
                photographerID: photographer.id,
                name: "Map Assignment",
                startsAt: dayStart.addingTimeInterval(9 * 60 * 60),
                endsAt: dayStart.addingTimeInterval(10 * 60 * 60),
                gpsPosition: ScheduledGPSPosition(
                    latitude: 59.9139,
                    longitude: 10.7522,
                    label: "Oslo"
                )
            )
            job.metadataAutomation = MetadataAutomation(
                isEnabled: true,
                photographers: [photographer],
                clips: [clip]
            )
        }
        return job
    }

    private static var managedRecoveryFixture: Bool {
        enabled && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_MANAGED_RECOVERY"] == "1"
    }

    /// Real folder permissions let native tests reach recovery admission instead
    /// of failing at placeholder-bookmark resolution. Seed once so relaunch after
    /// manual reconciliation cannot silently recreate the retained backup.
    static func seedMetadataRecoveryFixture(job: inout SyncJob, rootURL: URL, managed: Bool = false) throws {
        let manager = FileManager.default
        for side in ["Source", "Destination"] {
            let folder = rootURL.appendingPathComponent(side, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try FolderBookmark.create(for: folder)
            let endpoint = Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
            if side == "Source" { job.left = endpoint } else { job.right = endpoint }
        }
        job.metadataGeocoding = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, localeIdentifier: "en_US")
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        if managed { job.processedFilesLocation = .processedSubfolder }
        let marker = rootURL.appendingPathComponent("metadata-recovery-fixture-seeded")
        guard !manager.fileExists(atPath: marker.path) else { return }
        let destination = recoveryFixtureDestination(rootURL: rootURL, managed: managed)
        let recovery = destination.appendingPathComponent(".aagedal-sync-ui-fixture.transaction", isDirectory: true)
        try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
        try Data("retained original fixture bytes".utf8).write(to: recovery.appendingPathComponent("original-held-0"))
        try Data("retained original fixture bytes".utf8).write(to: recovery.appendingPathComponent("original-copy-0"))
        try Data("visible destination fixture bytes".utf8).write(to: destination.appendingPathComponent("preserved.txt"))
        try Data("visible destination fixture bytes".utf8).write(to: recovery.appendingPathComponent("output-copy-0"))
        let manifest = LocalEndpointSession.MatchingRecoveryManifest(schemaVersion: 1,
            originals: [.init(relativePath: "preserved.txt", snapshotFilename: "original-copy-0",
                              heldFilename: "original-held-0", isReplaced: true)],
            outputs: [.init(relativePath: "preserved.txt", stagedFilename: "output-stage-0",
                            snapshotFilename: "output-copy-0", rollbackFilename: "rollback-output-0")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: recovery.appendingPathComponent("recovery.json"), options: .atomic)
        try Data("seeded".utf8).write(to: marker, options: .atomic)
    }

    /// Geocoding is a v3 setting and cannot be saved in the ordinary legacy UI
    /// fixture repository. Initialize only this disposable job store; never
    /// replace an existing store or silently discard a decoding failure.
    static func recoveryFixtureRepository(job: SyncJob, rootURL: URL) throws -> JobRepository {
        let layout = AppStorageLayout(root: rootURL, storageFormat: .version3)
        if !FileManager.default.fileExists(atPath: layout.jobs.path) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try VersionedStoreCodec(format: .version3, store: .jobs).encode([job], encoder: encoder)
            try data.write(to: layout.jobs, options: .atomic)
        }
        let repository = JobRepository(storage: layout)
        _ = try repository.load()
        return repository
    }

    /// Explicit test-only relaunch step: the sandboxed UI runner cannot mutate
    /// the app's container. Keep every recovery snapshot outside the destination.
    static func reconcileMetadataRecoveryFixture(rootURL: URL, managed: Bool = false) throws {
        let manager = FileManager.default
        let destination = recoveryFixtureDestination(rootURL: rootURL, managed: managed)
        let recovery = destination.appendingPathComponent(".aagedal-sync-ui-fixture.transaction")
        guard manager.fileExists(atPath: recovery.path) else { return }
        let original = recovery.appendingPathComponent("original-held-0")
        guard try Data(contentsOf: rootURL.appendingPathComponent("metadata-recovery-fixture-seeded")) == Data("seeded".utf8),
              try Data(contentsOf: original) == Data("retained original fixture bytes".utf8) else {
            throw AppError.invalidConfiguration("Unexpected isolated recovery fixture contents")
        }
        try Data("reviewed visible fixture bytes".utf8).write(to: destination.appendingPathComponent("preserved.txt"))
        try manager.moveItem(at: original, to: rootURL.appendingPathComponent("rescued-original.txt"))
        try manager.moveItem(at: recovery, to: rootURL.appendingPathComponent("reconciled-recovery"))
    }

    private static func recoveryFixtureDestination(rootURL: URL, managed: Bool) -> URL {
        let destination = rootURL.appendingPathComponent("Destination", isDirectory: true)
        return managed ? destination.appendingPathComponent("Synced Files", isDirectory: true) : destination
    }

    private static func oneShotJobSaveFailure() -> @Sendable () throws -> Void {
        guard ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_FAIL_FIRST_JOB_SAVE"] == "1" else {
            return {}
        }
        let fault = OneShotSaveFault()
        return { try fault.check() }
    }
}

extension View {
    @ViewBuilder
    func applyingUITestDynamicTypeSize() -> some View {
        if let size = UITestSupport.dynamicTypeSizeOverride {
            dynamicTypeSize(size)
        } else {
            self
        }
    }
}

private final class OneShotSaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        guard shouldFail else { return }
        shouldFail = false
        throw AppError.transferFailed("The UI smoke test intentionally blocked this save. Try saving again.")
    }
}

@MainActor
private final class UITestNotificationDelivery: SyncFailureNotificationDelivering {
    func deliver(_ notification: SyncFailureNotification) {}
}

@MainActor
private final class UITestLaunchAtLoginCoordinator: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws {}
    func openSettings() {}
}
