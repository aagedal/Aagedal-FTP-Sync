import Foundation
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataCalendarPausedStartupTests: XCTestCase {
    private func fixture() throws -> (AppStorageLayout, MetadataCalendarState, MetadataSyncEvent) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("paused-calendar-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let photographer = PhotographerProfile(name: "Saved photographer", filenamePrefix: "SP", creator: "{literal}", copyrightNotice: "{{unchanged}}")
        let start = Date(timeIntervalSince1970: 1_800_000_000.125)
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Saved programming", startsAt: start,
            endsAt: start.addingTimeInterval(600), fields: ScheduledMetadataFields(headline: "{gps:city}"))
        var source = SyncJob(name: "Source")
        source.metadataAutomation = MetadataAutomation(photographers: [photographer], photographerTracks: [], clips: [clip])
        var duplicate = source
        duplicate.id = UUID()
        duplicate.name = "Received copy"
        duplicate.isEnabled = false
        duplicate.startsOnAppLaunch = false
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid", registered: true)
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Pending calendar", timeZone: "Etc/UTC", revision: 7,
            role: "editor", document: SharedMetadataDocument(source.metadataAutomation!))
        let pending = MetadataCalendarReceiveProposal(accountID: account.id, source: source, duplicate: duplicate, calendar: calendar)
        let state = MetadataCalendarState(accounts: [account], activeAccountID: account.id, pendingReceive: pending)
        let event = MetadataSyncEvent(date: start, jobID: source.id, operation: "Saved event", detail: "Retained history")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [
            layout.jobs.lastPathComponent: encoder.encode([source]),
            layout.metadataCalendar.lastPathComponent: MetadataCalendarClient.encoder().encode(state),
            layout.metadataSyncEvents.lastPathComponent: JSONEncoder().encode([event])])
        for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
        return (layout, state, event)
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: root.path)
            .map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
    }

    private var forbiddenKeychain: KeychainStore {
        KeychainStore(passwordReader: { _ in XCTFail("Paused startup must not read credentials"); return nil },
            passwordWriter: { _, _ in XCTFail("Paused startup must not write credentials") },
            passwordRemover: { _ in XCTFail("Paused startup must not delete credentials") })
    }

    private func paused(_ layout: AppStorageLayout) throws -> MetadataCalendarCoordinator {
        try MetadataCalendarCoordinator.makePausedForValidatedStorage(layout, keychain: forbiddenKeychain,
            changeDebounce: .zero, transport: { _, _, _, _, _ in
                XCTFail("Paused startup must not use the network")
                throw URLError(.cancelled)
            })
    }

    func testStrictFactoryPreservesPendingReceiptEventsAndEverySavedByteWhilePaused() async throws {
        let (layout, state, event) = try fixture()
        let before = try snapshot(layout.root)
        let coordinator = try paused(layout)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertFalse(coordinator.busy)
        XCTAssertNil(coordinator.currentOperation)
        XCTAssertNil(coordinator.receiveProposal)
        XCTAssertNil(coordinator.receivedJobID)
        XCTAssertEqual(coordinator.state.pendingReceive?.source, state.pendingReceive?.source)
        XCTAssertEqual(coordinator.state.pendingReceive?.duplicate, state.pendingReceive?.duplicate)
        XCTAssertEqual(coordinator.state.pendingReceive?.calendar, state.pendingReceive?.calendar)
        XCTAssertEqual(coordinator.state.activeAccountID, state.activeAccountID)
        XCTAssertEqual(coordinator.events.first?.id, event.id)
        XCTAssertEqual(coordinator.events.first?.date, event.date)
        XCTAssertTrue(coordinator.eventStorageError.isEmpty)
        XCTAssertEqual(try snapshot(layout.root), before)
    }

    func testPausedRefreshSetupAndDirectMutationEntryPointsCannotReplayReceiptOrWrite() async throws {
        let (layout, state, _) = try fixture()
        let coordinator = try paused(layout)
        let before = try snapshot(layout.root)
        var performed = false
        coordinator.perform { performed = true }
        coordinator.register(address: "https://another.invalid", deviceName: "Fixture", setupKey: nil, invite: nil)
        coordinator.selectAccount(UUID())
        coordinator.cancelPendingReceive()
        coordinator.retryPendingReceive()
        let pending = try XCTUnwrap(state.pendingReceive)
        coordinator.confirmReceive(pending)
        coordinator.detach(MetadataCalendarBinding(accountID: pending.accountID, jobID: pending.source.id, snapshot: pending.calendar))
        await coordinator.refresh()
        await coordinator.refresh(jobID: pending.source.id, automatic: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(performed)
        XCTAssertFalse(coordinator.busy)
        XCTAssertEqual(coordinator.state.pendingReceive?.id, pending.id)
        XCTAssertEqual(coordinator.state.activeAccountID, state.activeAccountID)
        XCTAssertEqual(try snapshot(layout.root), before)
    }

    func testStrictFactoryRejectsMissingOrCorruptStateAndEventsWithoutFallbackOrWrites() throws {
        let (layout, _, _) = try fixture()
        let original = try snapshot(layout.root)
        for target in [layout.metadataCalendar, layout.metadataSyncEvents] {
            let saved = try XCTUnwrap(original[target.lastPathComponent])
            try FileManager.default.removeItem(at: target)
            let missing = try snapshot(layout.root)
            XCTAssertThrowsError(try paused(layout))
            XCTAssertEqual(try snapshot(layout.root), missing)
            for data in [Data("malformed".utf8), Data("[]".utf8),
                         Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":4,\"store\":\"metadataCalendar\",\"payload\":{}}".utf8)] {
                try data.write(to: target)
                let damaged = try snapshot(layout.root)
                XCTAssertThrowsError(try paused(layout))
                XCTAssertEqual(try snapshot(layout.root), damaged)
            }
            try saved.write(to: target)
        }
    }

    func testStrictFactoryRejectsLegacyLayoutWithoutCreatingAnything() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("absent-paused-calendar-\(UUID())")
        XCTAssertThrowsError(try paused(AppStorageLayout(root: root))) {
            XCTAssertTrue($0 is AppPersistenceStartupError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExplicitStartWithoutPollingOrObservationActivatesOnlyRequestedWorkAndStopPausesAgain() async throws {
        let (layout, state, _) = try fixture()
        let coordinator = try paused(layout)
        let store = try AppStore.makePausedForValidatedStorage(layout, retainedCredentialIDs: [],
            allowsCredentialGarbageCollection: false, keychain: forbiddenKeychain,
            launchAtLoginCoordinator: PausedCalendarLaunchStub())
        let before = try snapshot(layout.root)
        coordinator.start(store: store, polling: false, observingChanges: false)
        XCTAssertFalse(coordinator.isPaused)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(coordinator.state.pendingReceive?.id, state.pendingReceive?.id)
        XCTAssertEqual(try snapshot(layout.root), before)
        var count = 0
        coordinator.perform { count += 1 }
        for _ in 0..<50 where coordinator.busy { await Task.yield() }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(coordinator.busy)
        coordinator.stop()
        XCTAssertTrue(coordinator.isPaused)
        coordinator.perform { count += 1 }
        await coordinator.refresh()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try snapshot(layout.root), before)
    }

    func testStrictRestartWaitsForInFlightTransportAndRejectsItsLateResponse() async throws {
        let (layout, originalState, _) = try fixture()
        var state = originalState
        state.pendingReceive = nil
        try MetadataCalendarRepository(storage: layout).save(state)
        let gate = PausedCalendarTransportGate()
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
            passwordWriter: { _, _ in XCTFail("Unexpected credential write") }, passwordRemover: { _ in XCTFail("Unexpected credential deletion") })
        let coordinator = try MetadataCalendarCoordinator.makePausedForValidatedStorage(layout, keychain: keychain,
            transport: { _, _, _, _, _ in await gate.response() })
        let store = try AppStore.makePausedForValidatedStorage(layout, retainedCredentialIDs: [],
            allowsCredentialGarbageCollection: false, keychain: keychain,
            launchAtLoginCoordinator: PausedCalendarLaunchStub())
        let before = try snapshot(layout.root)
        coordinator.start(store: store, polling: false, observingChanges: false)
        let refresh = Task { await coordinator.refresh() }
        let deadline = Date().addingTimeInterval(5)
        while !(await gate.isWaiting), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        coordinator.stop()
        coordinator.start(store: store, polling: false, observingChanges: false)
        XCTAssertTrue(coordinator.isPaused, "An in-flight operation must finish before strict reactivation")
        await gate.release()
        await refresh.value
        XCTAssertFalse(coordinator.busy)
        XCTAssertTrue(coordinator.calendars.isEmpty, "The late server response must not be applied")
        XCTAssertEqual(try snapshot(layout.root), before)
        coordinator.start(store: store, polling: false, observingChanges: false)
        XCTAssertFalse(coordinator.isPaused)
        coordinator.stop()
    }

    func testLegacyInitializerStillAllowsExplicitActionsBeforeStart() async throws {
        let (layout, state, _) = try fixture()
        let legacyURL = layout.root.appendingPathComponent("legacy-calendar.json")
        let repository = MetadataCalendarRepository(url: legacyURL)
        try repository.save(state)
        let coordinator = MetadataCalendarCoordinator(repository: repository, keychain: forbiddenKeychain)
        XCTAssertFalse(coordinator.isPaused)
        var performed = false
        coordinator.perform { performed = true }
        for _ in 0..<50 where coordinator.busy { await Task.yield() }
        XCTAssertTrue(performed)
        coordinator.stop()
        XCTAssertFalse(coordinator.isPaused)
    }
}

@MainActor
private final class PausedCalendarLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws { XCTFail("Startup must not change launch registration") }
    func openSettings() { XCTFail("Startup must not open settings") }
}


private actor PausedCalendarTransportGate {
    private var continuation: CheckedContinuation<MetadataCalendarResponse, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }
    private var value: MetadataCalendarResponse {
        MetadataCalendarResponse(service: "metadata-sync", protocolVersion: 1, calendars: [
            MetadataCalendarSummary(id: UUID(), name: "Late response", timeZone: "Etc/UTC", role: "editor")])
    }
    func response() async -> MetadataCalendarResponse {
        if released { return value }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: value)
        continuation = nil
    }
}
