import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement

/// User-mediated production startup. Process observation can detect another copy,
/// but cannot prove that older/noncooperating writers are excluded. The user's
/// explicit undertaking to keep every other copy closed remains a prerequisite
/// throughout admission and this runtime's lifetime. No process is forcibly quit.
@MainActor
final class Version3StartupController: ObservableObject {
    typealias Driver = Version3MigrationDriver
    enum Phase: Equatable { case idle, loading, selection, existing, recovery, ready }
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
                result.factories = .init(appStore: { admission in
                    try AppStore.makePausedForValidatedStorage(admission.storage, retainedCredentialIDs: admission.currentCredentialIDs,
                        allowsCredentialGarbageCollection: false, keychain: keychain,
                        launchAtLoginCoordinator: StartupTestLaunchCoordinator())
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

    /// Idempotent inspection only: never starts admission or constructs AppStore.
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
            let inspection = try await Task.detached(priority: .userInitiated) {
                if try Self.exists(root.appendingPathComponent(".v3-storage-boundary.json"))
                    || Self.exists(root.appendingPathComponent("v3")) {
                    return Optional<Version3MigrationSourceCatalog>.none
                }
                return try Version3MigrationSourceCatalog.inspect(root: root)
            }.value
            refreshRunningCopies()
            catalog = inspection
            if let inspection {
                primarySelections = [:]
                for primary in inspection.primaries {
                    if primary.choices.contains(.file(primary.filename)) { primarySelections[primary.filename] = .file(primary.filename) }
                    else if primary.choices == [.absent] { primarySelections[primary.filename] = .absent }
                    // Selecting a backup always requires a deliberate UI choice.
                }
                signatureSelection = inspection.signatureChoices == [.absent] ? .absent : nil
                phase = .selection
            } else {
                phase = .existing
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
        guard phase == .selection, let catalog, let signatures = signatureSelection else {
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
        await admit(.openCommitted)
    }

    func recoverPrepared() async {
        guard phase == .existing else { return }
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
            userFacingMessage = "Your saved data is open. Jobs and calendar sync remain paused until you explicitly start them."
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
        if error is DecodingError { return "A saved JSON store has an invalid structure or value type." }
        if let header = error as? VersionedStoreCodec.HeaderError {
            switch header {
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
