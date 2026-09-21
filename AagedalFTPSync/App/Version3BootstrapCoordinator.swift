import Combine
import Foundation

/// Bundle configuration holds the user-approved Photo Agent default policy.
/// The reviewed AuraFace payload is shipped in the app and admitted locally.
enum ProductionFaceRecognitionAdmission {
    struct Configuration: Sendable {
        static let enabledKey = "AFTAuraFaceEnabled"
        static let maximumDistanceKey = "AFTAuraFaceMaximumCosineDistance"
        static let minimumGapKey = "AFTAuraFaceMinimumRunnerUpGap"
        static let minimumQualityKey = "AFTAuraFaceMinimumCaptureQuality"

        let policy: FaceRecognitionAcceptancePolicy

        static func load(from info: [String: Any]) throws -> Self? {
            guard info[enabledKey] as? Bool == true else { return nil }
            guard let maximumDistance = (info[maximumDistanceKey] as? NSNumber)?.doubleValue,
                  let minimumGap = (info[minimumGapKey] as? NSNumber)?.doubleValue,
                  let minimumQuality = (info[minimumQualityKey] as? NSNumber)?.doubleValue else {
                throw AuraFaceComponentError.invalidTrustConfiguration
            }
            return try Self(
                policy: FaceRecognitionAcceptancePolicy(
                    maximumCosineDistance: maximumDistance,
                    minimumRunnerUpGap: minimumGap,
                    minimumCaptureQuality: minimumQuality,
                    unavailableQualityPolicy: .reject
                )
            )
        }
    }

    /// Optional-feature failures never fall through to an unverified context and
    /// never prevent opening the app. Face-enabled jobs remain paused with their
    /// actionable runtime blocker until all three dependencies are admitted.
    static func admitIfReady(
        _ admission: Version3MigrationDriver.Admission,
        bundle: Bundle = .main
    ) async -> MetadataFaceRecognitionContext? {
        do {
            guard let configuration = try Configuration.load(
                from: bundle.infoDictionary ?? [:]
            ) else { return nil }
            guard let library = try PeopleLibraryRepository(
                    root: admission.storage.peopleLibraryDirectory
                  ).currentSnapshot() else { return nil }
            let runtime = try BundledAuraFaceModel.admit(from: bundle)
            return try MetadataFaceRecognitionContext(
                service: FaceRecognitionAnalysisService(admittedRuntime: runtime),
                snapshot: library,
                runtimeRevision: runtime.runtimeRevision,
                acceptancePolicy: configuration.policy
            )
        } catch {
            return nil
        }
    }

}

/// Production version 3 bootstrap. The caller must independently exclude older app
/// processes and every existing repository
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
        case writerExclusion, lease, admission, faceRecognition, appStore, calendar, publication
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
        var faceRecognition: @Sendable (Version3MigrationDriver.Admission) async throws
            -> MetadataFaceRecognitionContext?
        var appStore: @MainActor (
            Version3MigrationDriver.Admission,
            MetadataFaceRecognitionContext?
        ) throws -> AppStore
        var calendar: @MainActor (Version3MigrationDriver.Admission) throws -> MetadataCalendarCoordinator
        init(
            faceRecognition: @escaping @Sendable (Version3MigrationDriver.Admission) async throws
                -> MetadataFaceRecognitionContext? = {
                    await ProductionFaceRecognitionAdmission.admitIfReady($0)
                },
            appStore: @escaping @MainActor (
                Version3MigrationDriver.Admission,
                MetadataFaceRecognitionContext?
            ) throws -> AppStore = { admission, faceRecognitionContext in
                try AppStore.makePausedForValidatedStorage(admission.storage,
                    retainedCredentialIDs: admission.currentCredentialIDs,
                    allowsCredentialGarbageCollection: admission.allowsCredentialGarbageCollection,
                    faceRecognitionContext: faceRecognitionContext)
            },
            calendar: @escaping @MainActor (Version3MigrationDriver.Admission) throws -> MetadataCalendarCoordinator = { admission in
                try MetadataCalendarCoordinator.makePausedForValidatedStorage(admission.storage)
            }
        ) {
            self.faceRecognition = faceRecognition
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
            stage = .faceRecognition
            let faceRecognitionContext = try await factories.faceRecognition(admission)
            try Task.checkCancellation()
            try lease.validate()
            stage = .writerExclusion
            try validateWriterExclusion()
            stage = .appStore
            let appStore = try factories.appStore(admission, faceRecognitionContext)
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

    /// Only completed failures before store construction may release their owner.
    var canResetSavedData: Bool {
        guard case .recoveryRequired(let recovery) = state else { return false }
        return retainedAppStore == nil && retainedCalendar == nil
            && [.writerExclusion, .lease, .admission, .faceRecognition].contains(recovery.stage)
    }

    func leaseForReset() throws -> Version3StorageLease {
        guard canResetSavedData else { throw Failure.alreadyStarted }
        let held = try lease ?? Version3StorageLease.acquire(root: driver.root)
        try held.validate()
        return held
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
