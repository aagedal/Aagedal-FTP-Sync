import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI
import SwiftMediaMetadata

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
        let supportedFixtures = Set(["populated", "backup-only", "damaged-primary", "prepared-recovery", "calendar-conflict"])
        guard supportedFixtures.contains(fixture) else { return }
        if fixture == "calendar-conflict" {
            try seedCalendarConflictFixture(at: rootURL)
            return
        }
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
                #if DEBUG
                if ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_RECONCILE_INTERRUPTED_IMAGE"] == "1" {
                    try reconcileInterruptedImageFixture(rootURL: rootURL, managed: managedRecoveryFixture, raw: rawRecoveryFixture, rawExtension: cameraRawExtension)
                }
                #endif
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
                downloadManifestRepository: downloadManifest,
                localReprocessSessionFactory: { endpoint, managed in
                    try reprocessingFixtureSession(endpoint: endpoint, managed: managed)
                }
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

    static var usesCalendarConflictFixture: Bool {
        usesVersion3Startup && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_V3_FIXTURE"] == "calendar-conflict"
    }

    /// A disposable v3 job has a local headline edit against revision 1 and a
    /// competing server headline edit at revision 2. The fake transport returns
    /// revision 3 when the open review is applied, simulating a second Mac edit.
    private static func seedCalendarConflictFixture(at rootURL: URL) throws {
        let storage = AppStorageLayout(root: rootURL.appendingPathComponent("v3", isDirectory: true), storageFormat: .version3)
        guard !FileManager.default.fileExists(atPath: storage.jobs.path) else { return }
        let photographer = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "Literal")
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Fixture clip",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_600),
            fields: .init(headline: "Base {photographer}"))
        var job = fixtureJob(rootURL: rootURL)
        job.name = "Calendar Conflict UI Fixture"
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        let baseline = MetadataAutomation(photographers: [photographer], photographerTracks: [], clips: [clip])
        job.metadataAutomation = baseline
        try JobRepository(fileURL: rootURL.appendingPathComponent("jobs-v2.json")).save([job])
        let catalog = try Version3MigrationSourceCatalog.inspect(root: rootURL)
        guard let signatures = catalog.recommendedSignatureSource else { throw FixtureInterruption.unexpectedCompletion }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let plan = try catalog.makePlan(primarySources: catalog.recommendedPrimarySources,
            signatures: signatures, calendar: calendar, migrationDate: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try Version3MigrationDriver(root: rootURL,
            temporaryDirectory: rootURL.deletingLastPathComponent()).migrateSelectedSources(plan)

        var activeBaseline = baseline
        activeBaseline.clips[0].fields.setHeadline(try .activated("Base {photographer}"))
        var local = activeBaseline
        local.clips[0].fields.setHeadline(try .activated("This Mac {photographer}"))
        job.metadataAutomation = local
        try JobRepository(storage: storage).save([job])

        let calendarID = UUID(uuidString: "A73FA2F2-148D-4AC9-8E56-0CD8E193F7B0")!
        let base = SharedMetadataCalendar(id: calendarID, name: "Fixture calendar", timeZone: "Etc/UTC", revision: 1,
            role: "owner", document: SharedMetadataDocument(activeBaseline), compatibility: .templates)
        var remote = base
        remote.revision = 2
        remote.document.clips[0].fields.setHeadline(try .activated("Server {photographer}"))
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid/", registered: true)
        try MetadataCalendarRepository(storage: storage).save(.init(accounts: [account], activeAccountID: account.id,
            bindings: [.init(accountID: account.id, jobID: job.id, snapshot: base, conflict: remote)]))
    }

    static func calendarConflictResponse(_ request: MetadataCalendarRequest) async throws -> MetadataCalendarResponse {
        guard usesCalendarConflictFixture, let rootURL,
              let remote = try MetadataCalendarRepository(storage: AppStorageLayout(
                root: rootURL.appendingPathComponent("v3", isDirectory: true), storageFormat: .version3))
                .load().bindings.first?.conflict else { throw URLError(.notConnectedToInternet) }
        // A write reaching this transport is an error. The UI test requires
        // the specific stale-review warning from the earlier getCalendar.
        guard request.action == "getCalendar" else { throw URLError(.unsupportedURL) }
        var latest = remote
        latest.revision = 3
        latest.document.clips[0].fields.setHeadline(try .activated("Newest server {photographer}"))
        return MetadataCalendarResponse(service: "aagedal-metadata-sync", protocolVersion: 3,
            calendar: latest, capabilities: ["metadata-templates-v1"])
    }

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
                try seedMetadataRecoveryFixture(job: &job, rootURL: rootURL, managed: managedRecoveryFixture, images: imageRecoveryFixture)
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
                fields: ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_MATCHING_CLIP_IMAGE"] == "1"
                    ? ScheduledMetadataFields(headline: "Scoped capture") : ScheduledMetadataFields(),
                gpsPosition: ScheduledGPSPosition(
                    latitude: 59.9139,
                    longitude: 10.7522,
                    label: "Oslo"
                )
            )
            job.metadataAutomation = MetadataAutomation(
                isEnabled: true,
                timestampPolicy: ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_MATCHING_CLIP_IMAGE"] == "1"
                    ? .cameraCapture : .sourceModification,
                photographers: [photographer],
                clips: [clip]
            )
        }
        return job
    }

    private static var managedRecoveryFixture: Bool {
        enabled && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_MANAGED_RECOVERY"] == "1"
    }

    private static var imageRecoveryFixture: Bool {
        enabled && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_IMAGE_RECOVERY"] == "1"
    }

    private static var rawRecoveryFixture: Bool {
        enabled && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_RAW_RECOVERY"] == "1"
    }

    // A closed fixture set prevents environment values from becoming paths.
    private static var cameraRawExtension: String {
        ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_RAW_EXTENSION"] == "cr3" ? "cr3" : "arw"
    }

    private static var interruptsImagePublication: Bool {
        #if DEBUG
        enabled && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_INTERRUPT_PUBLICATION"] == "1"
        #else
        false
        #endif
    }

    private static func reprocessingFixtureSession(endpoint: Endpoint, managed: ManagedOutputFolder?) throws -> LocalEndpointSession {
        #if DEBUG
        guard interruptsImagePublication, let rootURL,
              URL(fileURLWithPath: endpoint.localPath).resolvingSymlinksInPath().path
                == rootURL.appendingPathComponent("Destination").resolvingSymlinksInPath().path else {
            return try LocalEndpointSession(endpoint: endpoint, managedFolder: managed)
        }
        return try LocalEndpointSession(endpoint: endpoint, managedFolder: managed, matchingImportHook: { phase in
            let name: String
            switch phase {
            case .prepared: name = "prepared"
            case .originalsHeld: name = "originalsHeld"
            case .published(let index): name = "published-\(index)"
            case .beforeCommit: name = "beforeCommit"
            }
            let requested = ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_INTERRUPTION_PHASE"] ?? "beforeCommit"
            guard name == requested else { return }
            try Data(name.utf8).write(to: rootURL.appendingPathComponent("native-image-interruption"), options: .atomic)
            // Only a DEBUG, explicitly isolated UI fixture can reach this hook.
            // The runner survives; the app leaves its actual image transaction on disk.
            kill(getpid(), SIGKILL)
        })
        #else
        return try LocalEndpointSession(endpoint: endpoint, managedFolder: managed)
        #endif
    }

    /// Real folder permissions let native tests reach recovery admission instead
    /// of failing at placeholder-bookmark resolution. Seed once so relaunch after
    /// manual reconciliation cannot silently recreate the retained backup.
    static func seedMetadataRecoveryFixture(job: inout SyncJob, rootURL: URL, managed: Bool = false, images: Bool = false) throws {
        let manager = FileManager.default
        for side in ["Source", "Destination"] {
            let folder = rootURL.appendingPathComponent(side, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try FolderBookmark.create(for: folder)
            let endpoint = Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
            if side == "Source" { job.left = endpoint } else { job.right = endpoint }
        }
        job.metadataGeocoding = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, localeIdentifier: "en_US")
        if images {
            job.metadataGeocoding = try MetadataGeocodingSettings(cityPolicy: .fillEmpty,
                localeIdentifier: "en_US", geofences: [.init(id: UUID(uuidString: "CFE8C6D6-56C1-4CB0-96B9-3195F9A4A781")!, name: "Recovery Venue", vertices: [
                    .init(latitude: 59.4, longitude: 10.2), .init(latitude: 59.4, longitude: 10.3),
                    .init(latitude: 59.6, longitude: 10.3), .init(latitude: 59.6, longitude: 10.2)
                ])])
        }
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        if managed { job.processedFilesLocation = .processedSubfolder }
        let marker = rootURL.appendingPathComponent("metadata-recovery-fixture-seeded")
        guard !manager.fileExists(atPath: marker.path) else { return }
        let destination = recoveryFixtureDestination(rootURL: rootURL, managed: managed)
        let recovery = destination.appendingPathComponent(".aagedal-sync-ui-fixture.transaction", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        if !interruptsImagePublication {
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
        }
        if images {
            let nested = destination.appendingPathComponent("nested", isDirectory: true)
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)
            if rawRecoveryFixture {
                try seedCameraRawRecoveryImage(rootURL: rootURL, nested: nested)
                try Data("seeded".utf8).write(to: marker, options: .atomic)
                return
            }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let pixels = bitmap.bitmapData else {
                throw AppError.invalidConfiguration("Cannot create recovery image fixture")
            }
            pixels.initialize(repeating: 100, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            guard let bytes = bitmap.representation(using: .jpeg, properties: [:]) else {
                throw AppError.invalidConfiguration("Cannot encode recovery image fixture")
            }
            let matchingClip = ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_MATCHING_CLIP_IMAGE"] == "1"
            let filename = matchingClip ? "MAP_recovery.jpg" : "recovery.jpg"
            let image = nested.appendingPathComponent(filename)
            try bytes.write(to: image)
            var metadata = try ImageMetadata.read(from: image)
            metadata.setGPS(latitude: 59.5, longitude: 10.25)
            if matchingClip {
                let capture = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 60 * 60 + 30 * 60)
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                let value = Data((formatter.string(from: capture) + "\0").utf8)
                var exif = ExifData()
                exif.exifIFD = IFD(entries: [IFDEntry(tag: ExifTag.dateTimeOriginal,
                    type: .ascii, count: UInt32(value.count), valueData: value)])
                metadata.exif = exif
            }
            try metadata.write(to: image)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                      ofItemAtPath: image.path)
            try manager.copyItem(at: image, to: rootURL.appendingPathComponent("Source/\(filename)"))
        }
        try Data("seeded".utf8).write(to: marker, options: .atomic)
    }

    /// The opt-in runner stages an authorized disposable copy in the signed
    /// DEBUG test bundle. Never read an operator's original through the app.
    private static func seedCameraRawRecoveryImage(rootURL: URL, nested: URL) throws {
        #if DEBUG
        guard interruptsImagePublication,
              let fixture = Bundle.main.url(forResource: "UITestRecovery", withExtension: cameraRawExtension) else {
            throw AppError.invalidConfiguration("Opt-in camera RAW test bundle is missing")
        }
        let manager = FileManager.default
        let sidecar = Data("""
        <?xml version="1.0"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:custom="https://example.invalid/recovery/" xmp:Rating="4" custom:Keep="Camera &amp; desk" exif:GPSLatitude="59,30N" exif:GPSLongitude="10,15E"><dc:description><rdf:Alt><rdf:li xml:lang="x-default">Preserve camera sidecar — æøå</rdf:li></rdf:Alt></dc:description><dc:subject><rdf:Bag><rdf:li>Recovery keyword æøå</rdf:li><rdf:li>Desk &amp; camera</rdf:li></rdf:Bag></dc:subject><dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© Recovery fixture</rdf:li></rdf:Alt></dc:rights></rdf:Description></rdf:RDF></x:xmpmeta>
        """.utf8)
        for folder in [nested, rootURL.appendingPathComponent("Source")] {
            let image = folder.appendingPathComponent("recovery." + cameraRawExtension)
            try manager.copyItem(at: fixture, to: image)
            let xmp = folder.appendingPathComponent("recovery.xmp")
            try sidecar.write(to: xmp)
            for file in [image, xmp] {
                try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
            }
        }
        #else
        throw AppError.invalidConfiguration("Camera recovery fixtures require DEBUG")
        #endif
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

    #if DEBUG
    /// Explicit recovery choice for the single-image SIGKILL fixture. Preserve
    /// the entire transaction and the staged or visible replacement before
    /// restoring originals for a fresh native retry. This is not production recovery logic.
    static func reconcileInterruptedImageFixture(rootURL: URL, managed: Bool = false, raw: Bool = false, rawExtension: String = "arw") throws {
        let manager = FileManager.default
        // macOS may expose the owning sandbox's temporary root through an
        // alias. Canonicalize that root, then reject redirects below it.
        let rootURL = rootURL.resolvingSymlinksInPath()
        let destination = recoveryFixtureDestination(rootURL: rootURL, managed: managed)
        let candidates = try manager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".aagedal-sync-") && $0.pathExtension == "transaction" }
        guard !candidates.isEmpty else { return } // Relaunch must not restore twice.
        let phase = try String(contentsOf: rootURL.appendingPathComponent("native-image-interruption"), encoding: .utf8)
        let published = phase == "beforeCommit" || phase == "published-0"
        guard candidates.count == 1, published || phase == "originalsHeld",
              try Data(contentsOf: rootURL.appendingPathComponent("metadata-recovery-fixture-seeded")) == Data("seeded".utf8) else {
            throw AppError.invalidConfiguration("Unexpected interrupted image fixture")
        }
        let recovery = candidates[0]
        let manifestURL = recovery.appendingPathComponent("recovery.json")
        guard manifestURL.standardizedFileURL.path == manifestURL.resolvingSymlinksInPath().path else {
            throw AppError.invalidConfiguration("Redirected interrupted image fixture")
        }
        let manifest = try JSONDecoder().decode(LocalEndpointSession.MatchingRecoveryManifest.self,
                                               from: Data(contentsOf: manifestURL))
        guard !raw || ["arw", "cr3"].contains(rawExtension) else {
            throw AppError.invalidConfiguration("Unsupported camera recovery extension")
        }
        let expectedPaths = raw ? ["nested/recovery." + rawExtension, "nested/recovery.xmp"] : ["nested/recovery.jpg"]
        let outputPath = expectedPaths.last!
        guard manifest.schemaVersion == 1,
              manifest.originals.map(\.relativePath) == expectedPaths,
              manifest.outputs.count == 1, let publication = manifest.outputs.first,
              publication.relativePath == outputPath, publication.snapshotFilename == "output-copy-0",
              publication.stagedFilename == "output-stage-0", publication.rollbackFilename == "rollback-output-0" else {
            throw AppError.invalidConfiguration("Unexpected interrupted image path map")
        }
        func checkRegular(_ url: URL) throws {
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw AppError.invalidConfiguration("Redirected interrupted image evidence")
            }
        }
        var restore: [(URL, Data, Date?)] = []
        // Validate the entire group before writing either member.
        for (index, original) in manifest.originals.enumerated() {
            guard original.isReplaced == (original.relativePath == outputPath),
                  original.heldFilename == "original-held-\(index)",
                  original.snapshotFilename == "original-copy-\(index)" else {
                throw AppError.invalidConfiguration("Unexpected interrupted image holdings")
            }
            let held = recovery.appendingPathComponent(original.heldFilename)
            let snapshot = recovery.appendingPathComponent(original.snapshotFilename)
            let source = rootURL.appendingPathComponent("Source/" + URL(fileURLWithPath: original.relativePath).lastPathComponent)
            let visible = destination.appendingPathComponent(original.relativePath)
            for url in [held, snapshot, source] { try checkRegular(url) }
            let bytes = try Data(contentsOf: held)
            guard bytes == (try Data(contentsOf: source)), bytes == (try Data(contentsOf: snapshot)) else {
                throw AppError.invalidConfiguration("Interrupted image evidence changed before recovery")
            }
            if original.isReplaced && published {
                try checkRegular(visible)
            } else {
                guard !manager.fileExists(atPath: visible.path),
                      visible.standardizedFileURL.path == visible.resolvingSymlinksInPath().path else {
                    throw AppError.invalidConfiguration("Unpublished destination changed before recovery")
                }
            }
            restore.append((visible, bytes, try (original.isReplaced && published ? visible : held).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
        }
        let visible = destination.appendingPathComponent(outputPath)
        let publishedSnapshot = recovery.appendingPathComponent(publication.snapshotFilename)
        try checkRegular(publishedSnapshot)
        let publicationEvidence = published ? visible : recovery.appendingPathComponent(publication.stagedFilename)
        try checkRegular(publicationEvidence)
        guard try Data(contentsOf: publicationEvidence) == Data(contentsOf: publishedSnapshot) else {
            throw AppError.invalidConfiguration("Interrupted publication changed before recovery")
        }
        let preserved = rootURL.appendingPathComponent("reconciled-image-recovery")
        let rescuedPublication = rootURL.appendingPathComponent(raw ? "rescued-publication.xmp" : "rescued-publication.jpg")
        guard !manager.fileExists(atPath: preserved.path), !manager.fileExists(atPath: rescuedPublication.path) else {
            throw AppError.invalidConfiguration("Interrupted image rescue already exists")
        }
        try manager.copyItem(at: publicationEvidence, to: rescuedPublication)
        // Keep recovery admission blocked until both originals are restored.
        for (url, bytes, date) in restore {
            try bytes.write(to: url, options: .atomic)
            if let date { try manager.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        }
        try manager.moveItem(at: recovery, to: preserved)
    }
    #endif

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
