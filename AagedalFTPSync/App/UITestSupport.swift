import AppKit
import Foundation
import ServiceManagement

/// Launch plumbing used only by the isolated UI-test target. The opt-in marker
/// and per-run session identifier keep test persistence away from the user's
/// Application Support files and prevent test credentials from reaching Keychain.
enum UITestSupport {
    static let enabled = ProcessInfo.processInfo.environment["AAGEDAL_UI_TESTING"] == "1"

    private static var sessionID: String? {
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

    @MainActor
    static func makeStore() -> AppStore? {
        guard let rootURL else { return nil }

        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let jobRepository = JobRepository(
            fileURL: fileURL("jobs-v2.json", rootURL: rootURL),
            beforeSave: oneShotJobSaveFailure()
        )
        let fixture = fixtureJob(rootURL: rootURL)
        if ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_SEED_JOB"] == "1",
           (try? jobRepository.load().isEmpty) == true {
            try? jobRepository.save([fixture])
        }

        let sourceSignatures = SourceSignatureRepository(
            fileURL: fileURL("original-source-signatures-v1.json", rootURL: rootURL)
        )
        return AppStore(
            repository: jobRepository,
            metadataPresetRepository: MetadataPresetRepository(
                fileURL: fileURL("metadata-presets-v1.json", rootURL: rootURL)
            ),
            photographerProfileRepository: PhotographerProfileRepository(
                fileURL: fileURL("photographers-v1.json", rootURL: rootURL)
            ),
            serverProfileRepository: ServerProfileRepository(
                fileURL: fileURL("server-profiles-v1.json", rootURL: rootURL)
            ),
            metadataAuditRepository: MetadataAuditRepository(
                fileURL: fileURL("metadata-audit-v1.json", rootURL: rootURL)
            ),
            syncFailureRepository: SyncFailureRepository(
                fileURL: fileURL("sync-errors-v1.json", rootURL: rootURL)
            ),
            sourceSignatureRepository: sourceSignatures,
            keychain: KeychainStore(
                passwordReader: { _ in nil },
                passwordWriter: { _, _ in },
                passwordRemover: { _ in }
            ),
            engine: SyncEngine(sourceSignatureRepository: sourceSignatures),
            failureNotificationCoordinator: SyncFailureNotificationCoordinator(
                delivery: UITestNotificationDelivery()
            ),
            launchAtLoginCoordinator: UITestLaunchAtLoginCoordinator(),
            jobDraftTemplate: fixture
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

    private static var rootURL: URL? {
        guard let sessionID else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalFTPSyncUITests", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    private static func fileURL(_ name: String, rootURL: URL) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: false)
    }

    private static func fixtureJob(rootURL: URL) -> SyncJob {
        let sourcePath = rootURL.appendingPathComponent("Source", isDirectory: true).path
        let destinationPath = rootURL.appendingPathComponent("Destination", isDirectory: true).path
        let placeholderBookmark = Data("ui-test-folder-access".utf8)
        var job = SyncJob(name: "UI Smoke Fixture")
        job.left = Endpoint(kind: .local, localPath: sourcePath, bookmark: placeholderBookmark)
        job.right = Endpoint(kind: .local, localPath: destinationPath, bookmark: placeholderBookmark)
        job.isEnabled = false
        job.startsOnAppLaunch = false
        return job
    }

    private static func oneShotJobSaveFailure() -> @Sendable () throws -> Void {
        guard ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_FAIL_FIRST_JOB_SAVE"] == "1" else {
            return {}
        }
        let fault = OneShotSaveFault()
        return { try fault.check() }
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
