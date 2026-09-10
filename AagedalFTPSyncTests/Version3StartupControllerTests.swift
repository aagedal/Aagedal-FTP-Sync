import Foundation
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

@MainActor
final class Version3StartupControllerTests: XCTestCase {
    private typealias Controller = Version3StartupController
    private enum Injected: Error { case failed }

    private func base() throws -> URL {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("startup-controller-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
    private var keychain: KeychainStore {
        KeychainStore(passwordReader: { _ in XCTFail("Startup must not read credentials"); return nil },
            passwordWriter: { _, _ in XCTFail("Startup must not write credentials") },
            passwordRemover: { _ in XCTFail("Startup must not delete credentials") })
    }
    private var factories: Version3BootstrapCoordinator.Factories {
        .init(appStore: { admission in
            try AppStore.makePausedForValidatedStorage(admission.storage, retainedCredentialIDs: admission.currentCredentialIDs,
                allowsCredentialGarbageCollection: false, keychain: self.keychain,
                launchAtLoginCoordinator: ControllerLaunchStub())
        }, calendar: { admission in
            try MetadataCalendarCoordinator.makePausedForValidatedStorage(admission.storage, keychain: self.keychain,
                transport: { _, _, _, _, _ in XCTFail("Startup must not use network"); throw URLError(.cancelled) })
        })
    }
    private func dependencies(_ base: URL, peers: @escaping @MainActor () -> [Controller.RunningCopy] = { [] }) -> Controller.Dependencies {
        .init(preparePaths: {
            try Version3StartupPaths.prepare(root: base.appendingPathComponent("profile"), temporaryParent: base)
        }, runningCopies: peers, ownProcessID: 100, factories: factories,
            calendar: { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt; return calendar },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    func testInspectionIsIdempotentAndDoesNotConstructRuntimeOrMigrate() async throws {
        let base = try base()
        var calls = 0
        var deps = dependencies(base)
        let prepare = deps.preparePaths
        deps.preparePaths = { calls += 1; return try prepare() }
        deps.factories = .init(appStore: { _ in XCTFail("Inspection must not construct AppStore"); throw Injected.failed },
            calendar: { _ in XCTFail("Inspection must not construct calendar"); throw Injected.failed })
        let controller = Controller(dependencies: deps)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.session)
        await controller.load()
        await controller.load()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.phase, .selection)
        XCTAssertEqual(controller.primarySelections.count, 9)
        XCTAssertEqual(controller.signatureSelection, .absent)
        XCTAssertNil(controller.session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("profile/v3").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("profile").path).isEmpty)
    }

    func testMigrationRequiresAcknowledgementAndExcludesOwnProcessFromPeerDetection() async throws {
        let base = try base()
        var peers: [Controller.RunningCopy] = [.init(id: 100, name: "This copy"), .init(id: 101, name: "Another copy")]
        let controller = Controller(dependencies: dependencies(base, peers: { peers }))
        await controller.load()
        XCTAssertEqual(controller.otherRunningCopies.map(\.id), [101])
        await controller.migrate()
        XCTAssertEqual(controller.phase, .selection)
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        XCTAssertNil(controller.session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("profile").appendingPathComponent(Version3StorageLease.lockName).path))
        peers = [.init(id: 100, name: "This copy")]
        controller.refreshRunningCopies()
        await controller.migrate()
        XCTAssertEqual(controller.phase, .ready)
        let session = try XCTUnwrap(controller.session)
        XCTAssertTrue(session.calendar.isPaused)
        XCTAssertTrue(session.store.jobs.isEmpty)
        XCTAssertNotNil(session.owner)
        XCTAssertFalse(controller.canRetryInspection)
        XCTAssertThrowsError(try Version3StorageLease.acquire(root: base.appendingPathComponent("profile")))
    }

    func testBackupOnlyPrimaryRequiresExplicitSelectionAndItsSourceIsPreserved() async throws {
        let base = try base()
        let root = base.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let backup = root.appendingPathComponent("jobs-v2.json.backup")
        let bytes = Data("[]".utf8)
        try bytes.write(to: backup)
        let controller = Controller(dependencies: dependencies(base))
        await controller.load()
        XCTAssertNil(controller.primarySelections["jobs-v2.json"])
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        XCTAssertEqual(controller.phase, .selection)
        XCTAssertNil(controller.session)
        controller.primarySelections["jobs-v2.json"] = .file("jobs-v2.json.backup")
        await controller.migrate()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }

    func testBoundaryOrUnexplainedV3DirectoryNeverOffersFreshMigration() async throws {
        for boundary in [true, false] {
            let base = try base()
            let root = base.appendingPathComponent("profile")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            if boundary { try Data("damaged boundary".utf8).write(to: root.appendingPathComponent(".v3-storage-boundary.json")) }
            else { try FileManager.default.createDirectory(at: root.appendingPathComponent("v3"), withIntermediateDirectories: false) }
            let controller = Controller(dependencies: dependencies(base))
            await controller.load()
            XCTAssertEqual(controller.phase, .existing)
            XCTAssertNil(controller.catalog)
            XCTAssertNil(controller.session)
            await controller.migrate()
            XCTAssertNil(controller.session)
            controller.userConfirmedOtherCopiesClosed = true
            await controller.openExisting()
            XCTAssertEqual(controller.phase, .recovery)
            XCTAssertFalse(controller.canRetryInspection)
            await controller.retryInspection()
            XCTAssertEqual(controller.phase, .recovery)
            XCTAssertNil(controller.session)
            XCTAssertThrowsError(try Version3StorageLease.acquire(root: root))
        }
    }

    func testFailedRuntimeConstructionRetainsSingleAttemptOwnerAndNeverPublishesPair() async throws {
        let base = try base()
        var calls = 0
        var deps = dependencies(base)
        deps.factories = .init(appStore: { _ in calls += 1; throw Injected.failed },
            calendar: { _ in XCTFail("Must not construct after AppStore failure"); throw Injected.failed })
        let controller = Controller(dependencies: deps)
        await controller.load()
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        XCTAssertEqual(controller.phase, .recovery)
        XCTAssertNil(controller.session)
        XCTAssertEqual(calls, 1)
        await controller.retryInspection()
        await controller.openExisting()
        await controller.recoverPrepared()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(controller.canRetryInspection)
        XCTAssertThrowsError(try Version3StorageLease.acquire(root: base.appendingPathComponent("profile")))
    }

    func testInspectionFailureCanRetryBeforeAnyAdmissionOwnerExists() async throws {
        let base = try base()
        var fail = true
        var deps = dependencies(base)
        let prepare = deps.preparePaths
        deps.preparePaths = { if fail { throw Injected.failed }; return try prepare() }
        let controller = Controller(dependencies: deps)
        await controller.load()
        XCTAssertEqual(controller.phase, .recovery)
        XCTAssertTrue(controller.canRetryInspection)
        XCTAssertNil(controller.rootURL)
        fail = false
        await controller.retryInspection()
        XCTAssertEqual(controller.phase, .selection)
        XCTAssertFalse(controller.userConfirmedOtherCopiesClosed)
    }

    func testInvalidIsolatedTestLaunchNeverInspectsProductionPathsOrPeers() async throws {
        var deps = Controller.Dependencies(preparePaths: { XCTFail("Must not inspect production paths"); throw Injected.failed },
            runningCopies: { XCTFail("Must not query production peers"); return [] }, ownProcessID: 100)
        deps.isTestLaunch = true
        deps.isolatedSession = { nil }
        let controller = Controller(dependencies: deps)
        await controller.load()
        await controller.retryInspection()
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        await controller.openExisting()
        await controller.recoverPrepared()
        XCTAssertTrue(controller.isTestSession)
        XCTAssertEqual(controller.phase, .recovery)
        XCTAssertNil(controller.rootURL)
        XCTAssertNil(controller.session)
        XCTAssertFalse(controller.canRetryInspection)
    }

    func testIsolatedV3ModeCanMigrateButCannotActivateNetwork() async throws {
        let base = try base()
        var deps = dependencies(base, peers: { XCTFail("Isolated startup must not query production peers"); return [] })
        deps.isTestLaunch = true
        deps.testStartupMode = true
        deps.isolatedSession = { XCTFail("V3 startup must not construct legacy fixture"); return nil }
        let controller = Controller(dependencies: deps)
        await controller.load()
        XCTAssertTrue(controller.isTestSession)
        XCTAssertEqual(controller.phase, .selection)
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(try XCTUnwrap(controller.session).calendar.isPaused)
        XCTAssertThrowsError(try controller.activateCalendarSync())
        XCTAssertTrue(controller.userFacingMessage.contains("isolated"))
        XCTAssertTrue(controller.rootURL!.path.hasPrefix(base.path))
    }

    func testObservedCopyAfterPublicationLatchesRecoveryAndRetainsRuntimeLease() async throws {
        let base = try base()
        let root = base.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var job = SyncJob(name: "Keep saved launch choices")
        job.isEnabled = true
        job.startsOnAppLaunch = true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([job]).write(to: root.appendingPathComponent("jobs-v2.json"))
        var peers: [Controller.RunningCopy] = []
        let controller = Controller(dependencies: dependencies(base, peers: { peers }))
        await controller.load()
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        let session = try XCTUnwrap(controller.session)
        let savedJobsURL = root.appendingPathComponent("v3/jobs-v2.json")
        let savedJobs = try Data(contentsOf: savedJobsURL)
        let pausedJobs = session.store.jobs
        peers = [.init(id: 101, name: "Another version of this app")]
        controller.refreshRunningCopies()
        XCTAssertTrue(controller.requiresRelaunchAfterConflict)
        XCTAssertTrue(session.store.isSuspendedForExternalWriter)
        session.store.setEnabled(true, for: job.id)
        session.store.startAll()
        session.store.runNow(job.id)
        XCTAssertEqual(session.store.jobs, pausedJobs)
        XCTAssertEqual(try Data(contentsOf: savedJobsURL), savedJobs)
        XCTAssertTrue(session.calendar.isPaused)
        XCTAssertTrue(controller.userFacingMessage.contains("Quit every copy"))
        peers = []
        controller.refreshRunningCopies()
        XCTAssertTrue(controller.requiresRelaunchAfterConflict)
        XCTAssertThrowsError(try controller.activateCalendarSync())
        XCTAssertTrue(controller.session === session)
        XCTAssertThrowsError(try Version3StorageLease.acquire(root: base.appendingPathComponent("profile")))
    }

    func testPeerAtFinalControllerPublicationCheckKeepsCompletedRuntimePrivate() async throws {
        let base = try base()
        var calendarConstructed = false
        var checksAfterCalendar = 0
        var deps = dependencies(base, peers: {
            guard calendarConstructed else { return [] }
            checksAfterCalendar += 1
            // Allow bootstrap's last check; fail the controller's post-await check.
            return checksAfterCalendar >= 2 ? [.init(id: 101, name: "Copy observed before publication")] : []
        })
        let makeCalendar = deps.factories.calendar
        deps.factories.calendar = { admission in
            let calendar = try makeCalendar(admission)
            calendarConstructed = true
            return calendar
        }
        let controller = Controller(dependencies: deps)
        await controller.load()
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        XCTAssertEqual(checksAfterCalendar, 2)
        XCTAssertEqual(controller.phase, .recovery)
        XCTAssertNil(controller.session)
        XCTAssertTrue(controller.requiresRelaunchAfterConflict)
        XCTAssertFalse(controller.canRetryInspection)
        XCTAssertThrowsError(try Version3StorageLease.acquire(root: base.appendingPathComponent("profile")))
    }

    func testPeerAppearingAtFactoryBoundaryPreventsPublicationAndRetainsLease() async throws {
        let base = try base()
        var peers: [Controller.RunningCopy] = []
        var deps = dependencies(base, peers: { peers })
        let makeApp = deps.factories.appStore
        deps.factories.appStore = { admission in
            let store = try makeApp(admission)
            peers = [.init(id: 101, name: "Newly launched copy")]
            return store
        }
        let controller = Controller(dependencies: deps)
        await controller.load()
        controller.userConfirmedOtherCopiesClosed = true
        await controller.migrate()
        XCTAssertEqual(controller.phase, .recovery)
        XCTAssertNil(controller.session)
        XCTAssertTrue(controller.requiresRelaunchAfterConflict)
        XCTAssertFalse(controller.canRetryInspection)
        XCTAssertThrowsError(try Version3StorageLease.acquire(root: base.appendingPathComponent("profile")))
    }
}

@MainActor
private final class ControllerLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws { XCTFail("Startup must not alter login registration") }
    func openSettings() { XCTFail("Startup must not open system settings") }
}
