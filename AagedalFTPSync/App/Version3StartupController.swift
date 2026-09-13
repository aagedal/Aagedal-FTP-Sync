import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement

/// Production startup keeps routine launches out of recovery UI. A fresh install is
/// created silently, a healthy committed v3 store opens automatically, and a normal
/// legacy install gets one explicit upgrade action. Detailed source selection remains
/// reserved for ambiguous or recovery cases. Process observation and the cooperative
/// lease still gate every write; no process is forcibly quit.
@MainActor
final class Version3StartupController: ObservableObject {
    typealias Driver = Version3MigrationDriver
    enum Phase: Equatable { case idle, loading, upgrade, selection, existing, recovery, ready }
    struct RunningCopy: Identifiable, Equatable, Sendable {
        let id: Int32
        let name: String
    }
    @MainActor final class Session {
        let store: AppStore
        let calendar: MetadataCalendarCoordinator
        /// Retains the cooperative lease for as long as the published pair lives.
        let owner: Version3BootstrapCoordinator.Runtime?
        init(store: AppStore, calendar: MetadataCalendarCoordinator, owner: Version3BootstrapCoordinator.Runtime? = nil) {
            self.store = store
            self.calendar = calendar
            self.owner = owner
        }
    }
    enum Failure: Error, Equatable {
        case acknowledgementRequired, otherCopiesRunning, unavailable, invalidSelection, testRuntimeUnavailable
    }

    @MainActor struct Dependencies {
        var preparePaths: @MainActor () throws -> Version3StartupPaths
        var runningCopies: @MainActor () -> [RunningCopy]
        var ownProcessID: Int32
        var isTestLaunch = false
        var testStartupMode = false
        var isolatedSession: @MainActor () -> Session? = { nil }
        var observeWorkspace = false
        var factories = Version3BootstrapCoordinator.Factories()
        var calendar: @MainActor () -> Calendar = { Calendar.current }
        var now: @MainActor () -> Date = Date.init

        static var production: Self {
            let testLaunch = UITestSupport.enabled || NSClassFromString("XCTestCase") != nil
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let testStartupMode = UITestSupport.enabled && ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_V3_STARTUP"] == "1"
            var result = Self(preparePaths: {
                if testStartupMode {
                    guard let root = UITestSupport.rootURL else { throw Failure.testRuntimeUnavailable }
                    try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try UITestSupport.seedVersion3StartupFixtureIfRequested(at: root)
                    return try Version3StartupPaths.prepare(root: root, temporaryParent: FileManager.default.temporaryDirectory)
                }
                // Foundation owns creation of this trusted system location on a
                // fresh profile; the strict helper then creates only our final root.
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                return try Version3StartupPaths.prepare(root: support.appendingPathComponent("AagedalFTPSync", isDirectory: true),
                    temporaryParent: FileManager.default.temporaryDirectory)
            }, runningCopies: {
                guard let identifier = Bundle.main.bundleIdentifier else { return [] }
                return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map {
                    RunningCopy(id: $0.processIdentifier, name: $0.localizedName ?? "Aagedal FTP Sync")
                }
            }, ownProcessID: ProcessInfo.processInfo.processIdentifier,
                isTestLaunch: testLaunch, testStartupMode: testStartupMode, isolatedSession: {
                    // An invalid/missing UI-test session never falls through to
                    // Foundation's real Application Support location.
                    guard let root = UITestSupport.rootURL, let store = UITestSupport.makeStore() else { return nil }
                    let calendar = MetadataCalendarCoordinator(repository: MetadataCalendarRepository(url: root.appendingPathComponent("metadata-sync-v1.json")),
                        keychain: KeychainStore(passwordReader: { _ in nil }, passwordWriter: { _, _ in }, passwordRemover: { _ in }),
                        transport: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) })
                    return Session(store: store, calendar: calendar)
                }, observeWorkspace: true)
            if testStartupMode {
                let keychain = KeychainStore(passwordReader: { _ in nil }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
                result.factories = .init(appStore: { admission, faceRecognitionContext in
                    try AppStore.makePausedForValidatedStorage(admission.storage, retainedCredentialIDs: admission.currentCredentialIDs,
                        allowsCredentialGarbageCollection: false, keychain: keychain,
                        launchAtLoginCoordinator: StartupTestLaunchCoordinator(),
                        faceRecognitionContext: faceRecognitionContext)
                }, calendar: { admission in
                    try MetadataCalendarCoordinator.makePausedForValidatedStorage(admission.storage, keychain: keychain,
                        transport: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) })
                })
            }
            return result
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var session: Session?
    @Published private(set) var catalog: Version3MigrationSourceCatalog?
    @Published private(set) var rootURL: URL?
    @Published private(set) var userFacingMessage = ""
    @Published private(set) var recoveryDetail = ""
    @Published private(set) var otherRunningCopies: [RunningCopy] = []
    @Published private(set) var requiresRelaunchAfterConflict = false
    @Published var primarySelections: [String: Driver.Source] = [:]
    @Published var signatureSelection: Driver.Signatures?
    @Published var userConfirmedOtherCopiesClosed = false
    let isTestSession: Bool
    var busy: Bool { phase == .loading }
    var canRetryInspection: Bool { (!isTestSession || dependencies.testStartupMode) && !busy && bootstrapOwner == nil && session == nil }

    private let dependencies: Dependencies
    private var paths: Version3StartupPaths?
    private var loaded = false
    private var bootstrapOwner: Version3BootstrapCoordinator?
    private var attempt: Task<Version3BootstrapCoordinator.Runtime, Error>?
    private var workspaceObservation: AnyCancellable?

    convenience init() { self.init(dependencies: .production) }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        self.isTestSession = dependencies.isTestLaunch
        if dependencies.isTestLaunch && !dependencies.testStartupMode {
            loaded = true
            if let isolated = dependencies.isolatedSession() {
                session = isolated
                phase = .ready
            } else {
                phase = .recovery
                userFacingMessage = "The isolated test session could not be created. Production storage was not opened."
                recoveryDetail = "Stage: isolated test setup. A valid test session identifier and isolated fixture are required."
            }
            return
        }
        refreshRunningCopies()
        if dependencies.observeWorkspace && !dependencies.isTestLaunch {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservation = Publishers.Merge(center.publisher(for: NSWorkspace.didLaunchApplicationNotification),
                center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshRunningCopies() }
                }
        }
    }

    /// Idempotent startup orchestration. Routine cases admit storage immediately;
    /// only upgrades and recovery conditions remain visible for user action.
    func load() async {
        guard !loaded, !isTestSession || dependencies.testStartupMode else { return }
        loaded = true
        phase = .loading
        userFacingMessage = ""
        recoveryDetail = ""
        do {
            let prepared = try paths ?? dependencies.preparePaths()
            paths = prepared
            rootURL = prepared.root
            let root = prepared.root
            let storagePresence = try await Task.detached(priority: .userInitiated) {
                (
                    boundary: try Self.exists(root.appendingPathComponent(".v3-storage-boundary.json")),
                    current: try Self.exists(root.appendingPathComponent("v3"))
                )
            }.value
            refreshRunningCopies()
            if storagePresence.boundary || storagePresence.current {
                phase = .existing
                if storagePresence.boundary, storagePresence.current, otherRunningCopies.isEmpty {
                    // Legacy versions do not write the v3 directory. With no live peer,
                    // the v3 lease is the authority needed for an ordinary reopen.
                    userConfirmedOtherCopiesClosed = true
                    await admit(.openCommitted)
                } else {
                    userFacingMessage = otherRunningCopies.isEmpty
                        ? "Saved 3.0 data needs recovery review before it can be opened."
                        : "Close the other running copy before opening saved 3.0 data."
                }
                return
            }

            let inspection = try await Task.detached(priority: .userInitiated) {
                try Version3MigrationSourceCatalog.inspect(root: root)
            }.value
            catalog = inspection
            primarySelections = inspection.recommendedPrimarySources
            signatureSelection = inspection.recommendedSignatureSource

            if !inspection.hasLegacyData, otherRunningCopies.isEmpty {
                // No legacy bytes exist to choose or protect. Create an empty v3 store
                // without presenting migration internals on a brand-new installation.
                phase = .upgrade
                userConfirmedOtherCopiesClosed = true
                await migrateSelectedSources()
            } else if inspection.supportsStreamlinedUpgrade {
                phase = .upgrade
                userFacingMessage = inspection.hasLegacyData
                    ? "Your existing settings are ready for a one-time upgrade. Your original 2.9 data will be kept as a recovery copy."
                    : "A new 3.0 library is ready after every other copy of the app is closed."
            } else {
                phase = .selection
                userFacingMessage = "Some saved data needs recovery review before upgrading. Choose which retained source to use."
            }
        } catch {
            phase = .recovery
            userFacingMessage = "The storage locations could not be inspected safely. Saved files were not replaced. Resolve the location problem, then inspect again."
            recoveryDetail = "Stage: inspection. " + Self.safeReason(error)
        }
    }

    func retryInspection() async {
        guard canRetryInspection else {
            if !isTestSession { userFacingMessage = "Quit and reopen the app before another startup attempt. The current storage owner is retained until the app closes." }
            return
        }
        loaded = false
        catalog = nil
        userConfirmedOtherCopiesClosed = false
        await load()
    }

    func refreshRunningCopies() {
        guard !isTestSession else { return }
        otherRunningCopies = dependencies.runningCopies().filter { $0.id != dependencies.ownProcessID }.sorted { $0.id < $1.id }
        if !otherRunningCopies.isEmpty, session != nil || attempt != nil {
            requiresRelaunchAfterConflict = true
            session?.calendar.stop()
            session?.store.suspendForExternalWriter()
            userFacingMessage = "Another copy was observed while this storage was in use. Calendar sync is paused; existing jobs may still be finishing. Quit every copy, then reopen this app to revalidate the saved data."
        }
        if !otherRunningCopies.isEmpty, attempt != nil {
            // Bootstrap cancellation waits for detached admission to finish before
            // reporting failure; retaining its owner keeps the lease held meanwhile.
            attempt?.cancel()
        }
    }

    func migrate() async {
        guard phase == .selection else { return }
        await migrateSelectedSources()
    }

    /// The button is the user's explicit request to use the recommended current
    /// sources. It never authorizes backup fallback or source repair.
    func upgrade() async {
        guard phase == .upgrade else { return }
        userConfirmedOtherCopiesClosed = true
        await migrateSelectedSources()
    }

    func reviewMigrationSources() {
        guard phase == .upgrade, catalog?.hasLegacyData == true else { return }
        userConfirmedOtherCopiesClosed = false
        phase = .selection
        userFacingMessage = "Review the retained sources. Backups are never selected automatically."
    }

    private func migrateSelectedSources() async {
        guard let catalog, let signatures = signatureSelection else {
            userFacingMessage = "Choose a source for each saved store and for source signatures before migrating."
            return
        }
        do {
            let plan = try catalog.makePlan(primarySources: primarySelections, signatures: signatures,
                calendar: dependencies.calendar(), migrationDate: dependencies.now())
            await admit(.migrateSelectedSources(plan))
        } catch {
            userFacingMessage = "The selected sources are incomplete or no longer available. Review each source choice before migrating."
            recoveryDetail = "Stage: source selection. " + Self.safeReason(error)
        }
    }

    func openExisting() async {
        guard phase == .existing else { return }
        userConfirmedOtherCopiesClosed = true
        await admit(.openCommitted)
    }

    func recoverPrepared() async {
        guard phase == .existing else { return }
        userConfirmedOtherCopiesClosed = true
        await admit(.recoverPrepared)
    }

    /// Deliberate activation only; saved jobs remain paused and are controlled by
    /// their existing individual Run controls. Test sessions never enable network.
    func activateCalendarSync() throws {
        do {
            guard !isTestSession, let session, let owner = session.owner else { throw Failure.unavailable }
            try validateWriterPrerequisite()
            try owner.validateLease()
            session.calendar.start(store: session.store)
            userFacingMessage = session.calendar.isPaused
                ? "Calendar sync is still finishing an earlier operation. Wait for it to finish before starting again."
                : "Calendar sync is active. Jobs remain under their individual Run controls."
        } catch {
            if isTestSession { userFacingMessage = "Calendar network activity stays disabled in isolated test sessions." }
            else if requiresRelaunchAfterConflict { userFacingMessage = "Quit every copy and reopen this app before using this storage again. The earlier writer conflict must be revalidated." }
            else if !userConfirmedOtherCopiesClosed { userFacingMessage = "Confirm that every other copy is closed before starting calendar sync." }
            else if !otherRunningCopies.isEmpty { userFacingMessage = "Quit the other running copies before starting calendar sync." }
            else { userFacingMessage = "Calendar sync could not start safely. Keep this runtime paused and quit the app before reopening the saved data." }
            throw error
        }
    }

    private func admit(_ operation: Version3BootstrapCoordinator.Operation) async {
        guard bootstrapOwner == nil, let paths, session == nil else { return }
        do { try validateWriterPrerequisite() }
        catch {
            userFacingMessage = otherRunningCopies.isEmpty
                ? "Confirm that every other copy is closed and will stay closed while this app uses the storage."
                : "Quit the other running copies before continuing. This app will not quit them for you."
            return
        }
        let owner = Version3BootstrapCoordinator(root: paths.root, temporaryDirectory: paths.temporaryDirectory,
            validateWriterExclusion: { [weak self] in
                guard let self else { throw Failure.unavailable }
                try self.validateWriterPrerequisite()
            }, factories: dependencies.factories)
        bootstrapOwner = owner
        phase = .loading
        userFacingMessage = ""
        recoveryDetail = ""
        let task = Task { try await owner.start(operation) }
        attempt = task
        do {
            let runtime = try await task.value
            // The bootstrap task may have finished just before a workspace event
            // latched a conflict. Revalidate on this actor before publication;
            // cancelling an already completed task alone cannot invalidate value.
            try Task.checkCancellation()
            try validateWriterPrerequisite()
            try runtime.validateLease()
            attempt = nil
            session = Session(store: runtime.appStore, calendar: runtime.calendar, owner: runtime)
            phase = .ready
            switch operation {
            case .openCommitted:
                let restoration = runtime.appStore.restoreConfiguredLaunchJobs()
                if restoration.startedJobNames.isEmpty {
                    userFacingMessage = restoration.blockedJobNames.isEmpty
                        ? "Your saved data is open. No jobs are configured to start on launch. Calendar sync remains paused until you explicitly start it."
                        : "Your saved data is open. Jobs configured for launch remain stopped because face recognition is not ready. Calendar sync also remains paused."
                } else if restoration.blockedJobNames.isEmpty {
                    userFacingMessage = "Your saved data is open. Jobs configured to start on launch are active. Calendar sync remains paused until you explicitly start it."
                } else {
                    userFacingMessage = "Your saved data is open. Available launch jobs are active; face-recognition launch jobs remain stopped. Calendar sync remains paused."
                }
            case .migrateSelectedSources, .recoverPrepared:
                userFacingMessage = "Your saved data is open. Jobs and calendar sync remain paused until you explicitly start them."
            }
        } catch {
            attempt = nil
            phase = .recovery
            userFacingMessage = "Startup could not complete safely. Saved data remains available for recovery. Quit and reopen the app before trying Open or Recover; no default configuration was loaded."
            let stage: String
            if case .recoveryRequired(let recovery) = owner.state { stage = String(describing: recovery.stage) }
            else { stage = "publication" }
            recoveryDetail = "Stage: \(stage). " + Self.safeReason(error)
            if case .migrateSelectedSources(let plan) = operation {
                let files = plan.primarySources.values.compactMap { source -> String? in
                    if case .file(let name) = source { return name }; return nil
                }.sorted()
                if !files.isEmpty { recoveryDetail += "\nSelected JSON sources: " + files.joined(separator: ", ") }
            }
        }
    }

    /// No decoder debugDescription, payload value, calendar content or credential
    /// is shown. Our admission enum labels contain only fixed categories/paths.
    private static func safeReason(_ error: Error) -> String {
        if error is CancellationError { return "The startup attempt was cancelled; writer exclusion may have changed." }
        if error is MetadataTemplateRecordError { return "A saved activated template has an unsupported marker or invalid source. The original store was retained." }
        if error is DecodingError { return "A saved JSON store has an invalid structure or value type." }
        if let header = error as? VersionedStoreCodec.HeaderError {
            switch header {
            case .requiresVersion3Storage: return "Activated templates were found in legacy storage; retain this data and open its compatible versioned copy."
            case .missingStore: return "A required versioned store is missing."
            case .invalidEnvelope: return "A store header is malformed."
            case .wrongFormat: return "A store has the wrong format identity."
            case .unsupportedVersion(let version): return "Store schema version \(version) is unsupported."
            case .wrongStore: return "A file contains a different store identity."
            }
        }
        if error is Driver.Failure || error is Version3MigrationSourceCatalog.Failure
            || error is Version3JSONStoreConversion.ConversionError || error is Version3StartupPaths.Failure
            || error is Version3StorageLease.Failure || error is Failure {
            return String(describing: error)
        }
        return error.localizedDescription
    }

    private func validateWriterPrerequisite() throws {
        refreshRunningCopies()
        guard !requiresRelaunchAfterConflict else { throw Failure.unavailable }
        guard userConfirmedOtherCopiesClosed else { throw Failure.acknowledgementRequired }
        guard otherRunningCopies.isEmpty else { throw Failure.otherCopiesRunning }
        try Task.checkCancellation()
    }

    private nonisolated static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw Version3StartupPaths.Failure.fileSystem(errno)
    }
}

@MainActor
private final class StartupTestLaunchCoordinator: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws {}
    func openSettings() {}
}
