import Foundation
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

@MainActor
final class Version3BootstrapCoordinatorTests: XCTestCase {
    private typealias Bootstrap = Version3BootstrapCoordinator
    private typealias Driver = Version3MigrationDriver
    private enum Injected: Error { case exclusion, factory, interrupted }

    private func fixture() throws -> (root: URL, temporary: URL) {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("bootstrap-\(UUID().uuidString)")
        let root = base.appendingPathComponent("profile"), temporary = base.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, temporary)
    }
    private func plan(jobs: Bool = false) -> Driver.Plan {
        var sources = Dictionary(uniqueKeysWithValues: Version3JSONStoreConversion.primaryFilenames.map { ($0, Driver.Source.absent) })
        if jobs { sources["jobs-v2.json"] = .file("jobs-v2.json") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Etc/UTC")!
        return Driver.Plan(legacyFiles: Array(Driver.fixedLegacyPaths).sorted(), primarySources: sources,
            signatures: .absent, calendar: calendar, migrationDate: Date(timeIntervalSince1970: 1_800_000_000))
    }
    private var forbiddenKeychain: KeychainStore {
        KeychainStore(passwordReader: { _ in XCTFail("Bootstrap must not read credentials"); return nil },
            passwordWriter: { _, _ in XCTFail("Bootstrap must not write credentials") },
            passwordRemover: { _ in XCTFail("Bootstrap must not delete credentials") })
    }
    private func appStore(_ admission: Driver.Admission) throws -> AppStore {
        try AppStore.makePausedForValidatedStorage(admission.storage, retainedCredentialIDs: admission.currentCredentialIDs,
            allowsCredentialGarbageCollection: admission.allowsCredentialGarbageCollection,
            keychain: forbiddenKeychain, launchAtLoginCoordinator: BootstrapLaunchStub())
    }
    private func calendar(_ admission: Driver.Admission) throws -> MetadataCalendarCoordinator {
        try MetadataCalendarCoordinator.makePausedForValidatedStorage(admission.storage, keychain: forbiddenKeychain,
            transport: { _, _, _, _, _ in XCTFail("Bootstrap must not use network"); throw URLError(.cancelled) })
    }
    private var factories: Bootstrap.Factories {
        .init(appStore: { try self.appStore($0) }, calendar: { try self.calendar($0) })
    }
    private func failureStage(_ coordinator: Bootstrap) -> Bootstrap.Stage? {
        if case .recoveryRequired(let failure) = coordinator.state { return failure.stage }
        return nil
    }
    private func assertLeaseHeld(_ root: URL) {
        XCTAssertThrowsError(try Version3StorageLease.acquire(root: root)) {
            XCTAssertEqual($0 as? Version3StorageLease.Failure, .alreadyHeld)
        }
    }

    func testMigrationPublishesOnlyCompletePausedPairAndCannotStartAgain() async throws {
        let (root, temporary) = try fixture()
        var job = SyncJob(name: "Starts only after explicit runtime activation")
        job.isEnabled = true; job.startsOnAppLaunch = true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let legacy = try encoder.encode([job])
        try legacy.write(to: root.appendingPathComponent("jobs-v2.json"))
        var order: [String] = []
        var coordinator: Bootstrap!
        defer { coordinator = nil }
        let factories = Bootstrap.Factories(appStore: { admission in
            XCTAssertNil(coordinator.runtime)
            guard case .loading = coordinator.state else { throw Injected.factory }
            order.append("app")
            return try self.appStore(admission)
        }, calendar: { admission in
            XCTAssertNil(coordinator.runtime)
            guard case .loading = coordinator.state else { throw Injected.factory }
            order.append("calendar")
            return try self.calendar(admission)
        })
        coordinator = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: { order.append("exclusion") }, factories: factories)
        let runtime = try await coordinator.start(.migrateSelectedSources(plan(jobs: true)))
        XCTAssertTrue(coordinator.runtime === runtime)
        XCTAssertEqual(order, ["exclusion", "exclusion", "exclusion", "app", "exclusion", "calendar", "exclusion"])
        XCTAssertEqual(runtime.appStore.jobs.count, 1)
        XCTAssertFalse(try XCTUnwrap(runtime.appStore.jobs.first).isEnabled)
        XCTAssertTrue(try XCTUnwrap(runtime.appStore.jobs.first).startsOnAppLaunch)
        XCTAssertTrue(runtime.calendar.isPaused)
        XCTAssertFalse(runtime.calendar.busy)
        XCTAssertFalse(runtime.admission.allowsCredentialGarbageCollection)
        XCTAssertEqual(runtime.admission.storage.root, root.appendingPathComponent("v3", isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("jobs-v2.json")), legacy)
        try runtime.validateLease()
        assertLeaseHeld(root)
        let calls = order.count
        do { _ = try await coordinator.start(.openCommitted); XCTFail("Second start must fail") }
        catch { XCTAssertEqual(error as? Bootstrap.Failure, .alreadyStarted) }
        XCTAssertEqual(order.count, calls)
        XCTAssertTrue(coordinator.runtime === runtime)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(runtime.calendar.isPaused)
        XCTAssertFalse(runtime.appStore.jobs[0].isEnabled)
        // Break this test-only factory capture; production defaults capture no owner.
        coordinator = nil
    }

    func testOpenWithoutMigrationFailsClosedBeforeFactoriesAndKeepsLease() async throws {
        let (root, temporary) = try fixture()
        var constructionCalls = 0
        var coordinator: Bootstrap? = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {},
            factories: .init(appStore: { _ in constructionCalls += 1; throw Injected.factory },
                             calendar: { _ in constructionCalls += 1; throw Injected.factory }))
        do { _ = try await coordinator!.start(.openCommitted); XCTFail("Missing committed storage must fail") }
        catch { XCTAssertEqual(error as? Driver.Failure, .migrationRequired) }
        XCTAssertEqual(failureStage(coordinator!), .admission)
        XCTAssertNil(coordinator?.runtime)
        XCTAssertEqual(constructionCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
        assertLeaseHeld(root)
        do { _ = try await coordinator!.start(.migrateSelectedSources(plan())); XCTFail("Failure must not enable implicit retry") }
        catch { XCTAssertEqual(error as? Bootstrap.Failure, .alreadyStarted) }
        coordinator = nil
        let lease = try Version3StorageLease.acquire(root: root)
        withExtendedLifetime(lease) {}
    }

    func testWriterExclusionFailureBeforeOrAfterLeaseNeverConstructsFallbacks() async throws {
        for failingCall in [1, 2] {
            let (root, temporary) = try fixture()
            var calls = 0
            let coordinator = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {
                calls += 1
                if calls == failingCall { throw Injected.exclusion }
            }, factories: .init(appStore: { _ in XCTFail(); throw Injected.factory }, calendar: { _ in XCTFail(); throw Injected.factory }))
            do { _ = try await coordinator.start(.migrateSelectedSources(plan())); XCTFail() }
            catch { XCTAssertTrue(error is Injected) }
            XCTAssertEqual(failureStage(coordinator), .writerExclusion)
            XCTAssertNil(coordinator.runtime)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3").path))
            if failingCall == 1 {
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(Version3StorageLease.lockName).path))
            } else { assertLeaseHeld(root) }
            withExtendedLifetime(coordinator) {}
        }
    }

    func testCalendarFailureKeepsConstructedAppStorePrivateAndLeaseAlive() async throws {
        let (root, temporary) = try fixture()
        weak var created: AppStore?
        var coordinator: Bootstrap? = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {},
            factories: .init(appStore: { admission in
                let store = try self.appStore(admission); created = store; return store
            }, calendar: { _ in throw Injected.factory }))
        do { _ = try await coordinator!.start(.migrateSelectedSources(plan())); XCTFail() }
        catch { XCTAssertTrue(error is Injected) }
        XCTAssertEqual(failureStage(coordinator!), .calendar)
        XCTAssertNil(coordinator?.runtime)
        XCTAssertNotNil(created)
        assertLeaseHeld(root)
        coordinator = nil
        let lease = try Version3StorageLease.acquire(root: root)
        withExtendedLifetime(lease) {}
    }

    func testFinalExclusionFailureRetainsBothPausedStoresWithoutReadyPublication() async throws {
        let (root, temporary) = try fixture()
        var checks = 0
        weak var createdApp: AppStore?
        weak var createdCalendar: MetadataCalendarCoordinator?
        let coordinator = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {
            checks += 1
            if checks == 5 { throw Injected.exclusion }
        }, factories: .init(appStore: { admission in
            let store = try self.appStore(admission); createdApp = store; return store
        }, calendar: { admission in
            let calendar = try self.calendar(admission); createdCalendar = calendar; return calendar
        }))
        do { _ = try await coordinator.start(.migrateSelectedSources(plan())); XCTFail("Final exclusion check must fail") }
        catch { XCTAssertTrue(error is Injected) }
        XCTAssertEqual(checks, 5)
        XCTAssertEqual(failureStage(coordinator), .writerExclusion)
        XCTAssertNil(coordinator.runtime)
        XCTAssertNotNil(createdApp)
        XCTAssertTrue(try XCTUnwrap(createdCalendar).isPaused)
        assertLeaseHeld(root)
        withExtendedLifetime(coordinator) {}
    }

    func testRuntimeOwnerRetainsLeaseAfterCoordinatorIsDisposed() async throws {
        let (root, temporary) = try fixture()
        var coordinator: Bootstrap? = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {}, factories: factories)
        var runtime: Bootstrap.Runtime? = try await coordinator!.start(.migrateSelectedSources(plan()))
        coordinator = nil
        try runtime?.validateLease()
        assertLeaseHeld(root)
        withExtendedLifetime(runtime) {}
        runtime = nil
        let lease = try Version3StorageLease.acquire(root: root)
        withExtendedLifetime(lease) {}
    }

    func testExplicitPreparedRecoveryAndCommittedOpenRemainSeparateOperations() async throws {
        let (root, temporary) = try fixture()
        let driver = Driver(root: root, temporaryDirectory: temporary)
        XCTAssertThrowsError(try driver.migrateSelectedSources(plan(), checkpoint: {
            if case .boundaryPrepared = $0 { throw Injected.interrupted }
        }))
        var failedOpen: Bootstrap? = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {}, factories: factories)
        do { _ = try await failedOpen!.start(.openCommitted); XCTFail("Prepared stage must require explicit recovery") } catch {}
        XCTAssertNil(failedOpen?.runtime)
        failedOpen = nil
        var recovery: Bootstrap? = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {}, factories: factories)
        _ = try await recovery!.start(.recoverPrepared)
        XCTAssertTrue(try XCTUnwrap(recovery?.runtime).calendar.isPaused)
        recovery = nil
        let reopened = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {}, factories: factories)
        let runtime = try await reopened.start(.openCommitted)
        XCTAssertTrue(runtime.calendar.isPaused)
        XCTAssertTrue(runtime.appStore.jobs.isEmpty)
        withExtendedLifetime(reopened) {}
    }

    func testCancellationBeforeLeaseAndAfterAppConstructionNeverPublishesPartialRuntime() async throws {
        for afterConstruction in [false, true] {
            let (root, temporary) = try fixture()
            weak var created: AppStore?
            let coordinator = Bootstrap(root: root, temporaryDirectory: temporary, validateWriterExclusion: {},
                factories: .init(appStore: { admission in
                    let store = try self.appStore(admission); created = store
                    withUnsafeCurrentTask { $0?.cancel() }
                    return store
                }, calendar: { _ in XCTFail("Cancelled construction must not reach calendar"); throw Injected.factory }))
            let task = Task { @MainActor in
                if !afterConstruction { withUnsafeCurrentTask { $0?.cancel() } }
                return try await coordinator.start(.migrateSelectedSources(self.plan()))
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(coordinator.runtime)
            XCTAssertEqual(failureStage(coordinator), afterConstruction ? .appStore : .writerExclusion)
            if afterConstruction { XCTAssertNotNil(created); assertLeaseHeld(root) }
            else {
                XCTAssertNil(created)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(Version3StorageLease.lockName).path))
            }
            withExtendedLifetime(coordinator) {}
        }
    }
}

@MainActor
private final class BootstrapLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws { XCTFail("Bootstrap must not change launch at login") }
    func openSettings() { XCTFail("Bootstrap must not open system settings") }
}
