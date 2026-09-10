import Combine
import Foundation

/// Explicit opt-in bootstrap; the normal App entry point is unchanged. The caller
/// must independently exclude older app processes and every existing repository
/// writer, then retain this coordinator/runtime until all its writers are closed.
/// The cooperative v3 lease alone cannot establish that older-process exclusion.
/// The supplied validator asserts independently maintained continuous exclusion,
/// not a momentary process-list check. It is rechecked at boundaries, not during
/// detached admission; the caller maintains exclusion throughout that operation
/// and prevents incompatible writers throughout the runtime lifetime.
@MainActor
final class Version3BootstrapCoordinator: ObservableObject {
    enum Operation: Sendable {
        case migrateSelectedSources(Version3MigrationDriver.Plan)
        case openCommitted
        case recoverPrepared
    }
    enum Stage: Equatable, Sendable {
        case writerExclusion, lease, admission, appStore, calendar, publication
    }
    struct Recovery {
        let stage: Stage
        let underlyingError: Error
    }
    enum State {
        case idle
        case loading
        case ready(Runtime)
        case recoveryRequired(Recovery)
    }
    enum Failure: Error, Equatable { case alreadyStarted }

    /// A single published pair. Keep this owner alive while using either store;
    /// it retains the lease even if the bootstrap coordinator is no longer held.
    /// Extracting a store does not transfer its lifetime responsibilities.
    @MainActor
    final class Runtime {
        let appStore: AppStore
        let calendar: MetadataCalendarCoordinator
        let admission: Version3MigrationDriver.Admission
        private let lease: Version3StorageLease
        fileprivate init(appStore: AppStore, calendar: MetadataCalendarCoordinator,
                         admission: Version3MigrationDriver.Admission, lease: Version3StorageLease) {
            self.appStore = appStore
            self.calendar = calendar
            self.admission = admission
            self.lease = lease
        }
        /// Recheck observed root/lock replacement before a later runtime action.
        /// This does not validate exclusion of older or noncooperating writers.
        func validateLease() throws { try lease.validate() }
    }

    /// Strict production defaults; injectable construction seams permit failure
    /// ordering tests. Factories must return paused stores using the admitted root
    /// and must not start work, write settings, or return legacy/default stores.
    struct Factories {
        var appStore: @MainActor (Version3MigrationDriver.Admission) throws -> AppStore
        var calendar: @MainActor (Version3MigrationDriver.Admission) throws -> MetadataCalendarCoordinator
        init(
            appStore: @escaping @MainActor (Version3MigrationDriver.Admission) throws -> AppStore = { admission in
                try AppStore.makePausedForValidatedStorage(admission.storage,
                    retainedCredentialIDs: admission.currentCredentialIDs,
                    allowsCredentialGarbageCollection: admission.allowsCredentialGarbageCollection)
            },
            calendar: @escaping @MainActor (Version3MigrationDriver.Admission) throws -> MetadataCalendarCoordinator = { admission in
                try MetadataCalendarCoordinator.makePausedForValidatedStorage(admission.storage)
            }
        ) {
            self.appStore = appStore
            self.calendar = calendar
        }
    }

    @Published private(set) var state: State = .idle
    var runtime: Runtime? {
        if case .ready(let runtime) = state { return runtime }
        return nil
    }
    private let driver: Version3MigrationDriver
    private let validateWriterExclusion: @MainActor () throws -> Void
    private let factories: Factories
    private var started = false
    private var lease: Version3StorageLease?
    // Keep partially constructed paused objects private after a failed attempt.
    // Their owner and lease survive together; no partial/default runtime escapes.
    private var retainedAppStore: AppStore?
    private var retainedCalendar: MetadataCalendarCoordinator?

    init(root: URL, temporaryDirectory: URL,
         validateWriterExclusion: @escaping @MainActor () throws -> Void,
         factories: Factories = Factories()) {
        driver = Version3MigrationDriver(root: root, temporaryDirectory: temporaryDirectory)
        self.validateWriterExclusion = validateWriterExclusion
        self.factories = factories
    }

    /// One explicit attempt per coordinator, including failures. A retry/recovery
    /// requires disposing of this coordinator and all stores before creating a new
    /// one; stop() alone is not a proof that older tasks have drained. Admission
    /// finishes before either store is constructed, and both stay paused at ready.
    /// No credential collection, scheduler start, calendar receipt replay or
    /// polling is performed here. Errors publish recovery state, never fallbacks.
    @discardableResult
    func start(_ operation: Operation) async throws -> Runtime {
        guard !started else { throw Failure.alreadyStarted }
        started = true
        state = .loading
        var stage: Stage = .writerExclusion
        do {
            try Task.checkCancellation()
            try validateWriterExclusion()
            stage = .lease
            let lease = try Version3StorageLease.acquire(root: driver.root)
            self.lease = lease
            try lease.validate()
            stage = .writerExclusion
            try validateWriterExclusion()
            try Task.checkCancellation()
            stage = .admission
            // Keep filesystem/SQLite admission off the main actor. Cancellation
            // propagates, but we still await worker completion before failure is
            // published, retaining the lease while any admission work remains.
            let driver = self.driver
            let admissionTask = Task.detached(priority: .userInitiated) {
                try await Self.admit(operation, driver: driver)
            }
            let admission = try await withTaskCancellationHandler {
                try await admissionTask.value
            } onCancel: {
                admissionTask.cancel()
            }
            try Task.checkCancellation()
            try lease.validate()
            stage = .writerExclusion
            try validateWriterExclusion()
            stage = .appStore
            let appStore = try factories.appStore(admission)
            retainedAppStore = appStore
            try Task.checkCancellation()
            try lease.validate()
            stage = .writerExclusion
            try validateWriterExclusion()
            stage = .calendar
            let calendar = try factories.calendar(admission)
            retainedCalendar = calendar
            stage = .publication
            try Task.checkCancellation()
            try lease.validate()
            stage = .writerExclusion
            try validateWriterExclusion()
            let runtime = Runtime(appStore: appStore, calendar: calendar, admission: admission, lease: lease)
            state = .ready(runtime)
            return runtime
        } catch {
            state = .recoveryRequired(Recovery(stage: stage, underlyingError: error))
            throw error
        }
    }

    private nonisolated static func admit(_ operation: Operation, driver: Version3MigrationDriver) async throws -> Version3MigrationDriver.Admission {
        try Task.checkCancellation()
        switch operation {
        case .migrateSelectedSources(let plan): return try driver.migrateSelectedSources(plan)
        case .openCommitted: return try await driver.openCommitted()
        case .recoverPrepared: return try await driver.recoverPreparedInstallation()
        }
    }
}
