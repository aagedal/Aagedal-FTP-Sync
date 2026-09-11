import Foundation
import XCTest
@testable import AagedalFTPSync

final class SharedMetadataCalendarTests: XCTestCase {
    private func fixture() -> MetadataAutomation {
        let p = PhotographerProfile(name: "Example", filenamePrefix: "EX", creator: "Example", copyrightNotice: "Example")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return MetadataAutomation(photographers: [p], photographerTracks: [], clips: [
            MetadataScheduleClip(photographerID: p.id, name: "First", startsAt: start, endsAt: start.addingTimeInterval(100)),
            MetadataScheduleClip(photographerID: p.id, name: "Second", startsAt: start.addingTimeInterval(200), endsAt: start.addingTimeInterval(300))
        ])
    }

    func testIndependentEditsMergeAndMatchingEditsAreIdempotent() throws {
        let base = SharedMetadataDocument(fixture())
        var local = base, remote = base
        local.clips[0].fields.headline = "Local headline"
        remote.clips[1].fields.description = "Remote description"
        let merged = try SharedMetadataDocument.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.clips[0], local.clips[0])
        XCTAssertEqual(merged.clips[1], remote.clips[1])
        XCTAssertEqual(try SharedMetadataDocument.merge(base: base, local: merged, remote: merged), merged)
    }

    func testCompetingEditsAndDeleteVersusEditRemainConflicts() {
        let base = SharedMetadataDocument(fixture())
        var local = base, remote = base
        local.clips[0].name = "Local"
        remote.clips[0].name = "Remote"
        XCTAssertThrowsError(try SharedMetadataDocument.merge(base: base, local: local, remote: remote))
        remote.clips.removeFirst()
        XCTAssertThrowsError(try SharedMetadataDocument.merge(base: base, local: local, remote: remote))
        XCTAssertNoThrow(try SharedMetadataDocument.merge(base: base, local: base, remote: remote))
    }

    func testDisjointChangesThatCreateAnOverlapAreRejected() {
        var automation = fixture()
        automation.clips.sort { $0.startsAt < $1.startsAt }
        let base = SharedMetadataDocument(automation)
        var local = base, remote = base
        let first = local.clips.firstIndex { $0.name == "First" }!
        let second = local.clips.firstIndex { $0.name == "Second" }!
        local.clips[first].endsAt = automation.clips[0].startsAt.addingTimeInterval(180)
        remote.clips[second].startsAt = automation.clips[0].startsAt.addingTimeInterval(150)
        XCTAssertThrowsError(try SharedMetadataDocument.merge(base: base, local: local, remote: remote))
    }

    func testRangeExcludesCrossingClipsAndPrivateProfileHours() throws {
        var automation = fixture()
        let start = automation.clips[0].startsAt
        automation.photographers[0].workHours = PhotographerWorkHours(startMinutes: 540, endMinutes: 1020)
        let full = SharedMetadataDocument(automation)
        let range = MetadataSharingRange(start: start, end: start.addingTimeInterval(250))
        let scoped = full.restricted(to: range, timeZone: "Etc/UTC")
        XCTAssertEqual(scoped.clips.map(\.name), ["First"])
        let encoded = String(decoding: try MetadataCalendarClient.encoder().encode(scoped), as: UTF8.self)
        for key in ["workHours", "workHourOverrides", "timestampPolicy", "existingFieldPolicy", "isEnabled"] {
            XCTAssertFalse(encoded.contains(key))
        }
        XCTAssertEqual(try MetadataCalendarClient.decoder().decode(SharedMetadataDocument.self, from: MetadataCalendarClient.encoder().encode(scoped)), scoped)
    }

    func testScopedApplyKeepsOutsideProgrammingAndLocalPolicies() throws {
        var automation = fixture()
        automation.isEnabled = true
        automation.timestampPolicy = .cameraCapture
        let range = MetadataSharingRange(start: automation.clips[0].startsAt, end: automation.clips[0].endsAt)
        let base = SharedMetadataDocument(automation).restricted(to: range, timeZone: "Etc/UTC")
        var remote = base
        remote.clips[0].fields.headline = "Shared update"
        let result = try remote.applying(to: automation, replacing: base, range: range, timeZone: "Etc/UTC")
        XCTAssertEqual(result.timestampPolicy, .cameraCapture)
        XCTAssertTrue(result.isEnabled)
        XCTAssertTrue(result.clips.contains(automation.clips[1]))
        XCTAssertTrue(result.clips.contains(remote.clips[0]))
    }

    func testCorruptSyncStateIsNotSilentlyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = MetadataCalendarRepository(url: directory.appendingPathComponent("state.json"))
        try Data("broken state".utf8).write(to: repository.url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try String(contentsOf: repository.url, encoding: .utf8), "broken state")
    }
}

private actor CalendarTransportFixture {
    var calendar: SharedMetadataCalendar
    var failAfterCommit = false
    var writes = 0
    var requests: [String] = []
    var offline = false
    private var suspendedAction: String?
    private var suspendedRequest: CheckedContinuation<Void, Never>?
    init(calendar: SharedMetadataCalendar) { self.calendar = calendar }
    func loseNextResponse() { failAfterCommit = true }
    func setOffline(_ value: Bool) { offline = value }
    func suspendNextRequest(_ action: String) { suspendedAction = action }
    var isSuspended: Bool { suspendedRequest != nil }
    func resumeRequest() { suspendedRequest?.resume(); suspendedRequest = nil }
    func send(_ body: MetadataCalendarRequest) async throws -> MetadataCalendarResponse {
        requests.append(body.action)
        if suspendedAction == body.action {
            suspendedAction = nil
            await withCheckedContinuation { suspendedRequest = $0 }
        }
        if offline { throw URLError(.notConnectedToInternet) }
        if body.action == "listCalendars" {
            return MetadataCalendarResponse(service: "aagedal-metadata-sync", protocolVersion: 2, calendars: [])
        }
        if body.action == "putCalendar" {
            if body.expectedRevision != calendar.revision {
                return MetadataCalendarResponse(service: "aagedal-metadata-sync", protocolVersion: 2, error: "revision_conflict", calendar: calendar)
            }
            calendar.document = body.document!
            calendar.revision += 1
            writes += 1
            if failAfterCommit { failAfterCommit = false; throw URLError(.networkConnectionLost) }
        }
        return MetadataCalendarResponse(service: "aagedal-metadata-sync", protocolVersion: 2, calendar: calendar)
    }
    func replaceRemote(_ doc: SharedMetadataDocument) { calendar.document = doc; calendar.revision += 1 }
}

@MainActor
final class MetadataCalendarCoordinatorTests: XCTestCase {
    private func makeStore(root: URL, job: SyncJob, beforeSave: @escaping @Sendable () throws -> Void = {}) throws -> AppStore {
        var job = job
        job.isEnabled = false
        job.startsOnAppLaunch = false
        job.left = Endpoint(kind: .local, localPath: root.appendingPathComponent("input").path, bookmark: Data([1]))
        job.right = Endpoint(kind: .local, localPath: root.appendingPathComponent("output").path, bookmark: Data([1]))
        let jobs = JobRepository(fileURL: root.appendingPathComponent("jobs.json"), beforeSave: beforeSave)
        try jobs.save([job])
        return AppStore(repository: jobs,
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            photographerProfileRepository: PhotographerProfileRepository(fileURL: root.appendingPathComponent("photographers.json")),
            serverProfileRepository: ServerProfileRepository(fileURL: root.appendingPathComponent("servers.json")),
            metadataAuditRepository: MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json")),
            syncFailureRepository: SyncFailureRepository(fileURL: root.appendingPathComponent("failures.json")),
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")))
    }

    private func receiveFixture(jobGate: ReceiveSaveGate? = nil, syncGate: ReceiveSaveGate? = nil) throws
        -> (URL, AppStore, MetadataCalendarCoordinator, MetadataCalendarRepository, SharedMetadataCalendar) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = PhotographerProfile(name: "Local photographer", filenamePrefix: "LOC", creator: "Local photographer", copyrightNotice: "Local copyright")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Original programming", startsAt: start, endsAt: start.addingTimeInterval(600))
        var job = SyncJob(name: "Local job")
        job.intervalSeconds = 42
        job.metadataAutomation = MetadataAutomation(isEnabled: true, timestampPolicy: .cameraCapture, photographers: [profile], clips: [clip])
        let store = try makeStore(root: root, job: job, beforeSave: { try jobGate?.check() })
        let sharedProfile = PhotographerProfile(name: "Shared photographer", filenamePrefix: "SHR", creator: "Shared photographer", copyrightNotice: "Shared copyright")
        let sharedClip = MetadataScheduleClip(photographerID: sharedProfile.id, name: "Shared programming", startsAt: start, endsAt: start.addingTimeInterval(300))
        let doc = SharedMetadataDocument(MetadataAutomation(photographers: [sharedProfile], photographerTracks: [], clips: [sharedClip]))
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Shared calendar", timeZone: "Etc/UTC", revision: 1, role: "editor", document: doc)
        let account = MetadataSyncAccount(id: UUID(), address: "https://sync.example.org/", registered: true)
        let repository = MetadataCalendarRepository(url: root.appendingPathComponent("sync.json"), beforeSave: { try syncGate?.check() })
        try repository.save(MetadataCalendarState(accounts: [account], activeAccountID: account.id))
        let server = CalendarTransportFixture(calendar: calendar)
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: { body, _, _, _, _ in try await server.send(body) })
        sync.start(store: store, polling: false, observingChanges: false)
        return (root, store, sync, repository, calendar)
    }

    private func finishOperation(_ sync: MetadataCalendarCoordinator) async throws {
        let deadline = Date().addingTimeInterval(5)
        while sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(sync.busy, "The receive operation should finish")
    }

    private func liveFixture(now: @escaping () -> Date = Date.init,
                             waitForChangeDebounce: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws -> (URL, AppStore, MetadataCalendarCoordinator, CalendarTransportFixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = PhotographerProfile(name: "Example", filenamePrefix: "EX", creator: "Example", copyrightNotice: "")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Original",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_100))
        var job = SyncJob(name: "Live calendar")
        job.metadataAutomation = MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [clip])
        let store = try makeStore(root: root, job: job)
        let account = MetadataSyncAccount(id: UUID(), address: "https://sync.example.org/", registered: true)
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Example", timeZone: "Etc/UTC", revision: 1,
            role: "editor", document: SharedMetadataDocument(job.metadataAutomation!))
        let repository = MetadataCalendarRepository(url: root.appendingPathComponent("sync.json"))
        try repository.save(MetadataCalendarState(accounts: [account], activeAccountID: account.id,
            bindings: [MetadataCalendarBinding(accountID: account.id, jobID: job.id, snapshot: calendar)]))
        let server = CalendarTransportFixture(calendar: calendar)
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain, changeDebounce: .milliseconds(100), waitForChangeDebounce: waitForChangeDebounce, now: now,
            transport: { body, _, _, _, _ in try await server.send(body) })
        sync.start(store: store, polling: false)
        return (root, store, sync, server)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected sync to make progress", file: file, line: line)
    }

    func testSavedEditsSyncWithoutPollingAndRapidChangesCoalesce() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await sync.refresh(jobID: id)
        var edited = store.jobs[0].metadataAutomation!
        edited.clips[0].name = "First edit"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await eventually { sync.activity(for: id).phase == .pending }
        let before = await server.writes
        XCTAssertEqual(before, 0)
        edited.clips[0].name = "Latest edit"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await eventually { await server.writes == 1 && sync.activity(for: id).phase == .current }
        let remote = await server.calendar
        XCTAssertEqual(remote.document.clips[0].name, "Latest edit")
        XCTAssertEqual(sync.state.bindings[0].snapshot, remote)
        try await Task.sleep(for: .milliseconds(200))
        let requests = await server.requests
        XCTAssertEqual(requests, ["getCalendar", "getCalendar", "putCalendar"], "Applying sync results must not create an echo request")
    }

    func testManualRefreshDuringEditDebounceDoesNotProduceDelayedEcho() async throws {
        let delay = CalendarDebounceGate()
        let (root, store, sync, server) = try liveFixture(waitForChangeDebounce: { _ in await delay.wait() })
        defer {
            sync.stop()
            Task { await delay.release() }
            try? FileManager.default.removeItem(at: root)
        }
        let id = store.jobs[0].id
        await sync.refresh(jobID: id)
        var edited = store.jobs[0].metadataAutomation!
        edited.clips[0].name = "Manual refresh commits this edit"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await eventually {
            let waiting = await delay.waitingCount
            return sync.activity(for: id).phase == .pending && waiting > 0
        }
        // The gate makes this ordering independent of machine speed: the edit's
        // debounce cannot dispatch while the explicit refresh updates its baseline.
        await sync.refresh(jobID: id)
        let committed = await server.calendar
        XCTAssertEqual(committed.document.clips[0].name, edited.clips[0].name)
        XCTAssertEqual(sync.state.bindings[0].snapshot, committed)
        XCTAssertEqual(sync.activity(for: id).phase, .current)
        let beforeRelease = await server.requests
        XCTAssertEqual(beforeRelease, ["getCalendar", "getCalendar", "putCalendar"])
        await delay.release()
        try await eventually { await delay.allReturned }
        // No follow-up request should appear after all held debounce calls return.
        try await Task.sleep(for: .milliseconds(200))
        let afterRelease = await server.requests
        XCTAssertEqual(afterRelease, beforeRelease, "A completed edit must be re-evaluated after debounce, not fetched again")
        XCTAssertEqual(sync.activity(for: id).phase, .current)
    }

    func testLocalProcessingPolicyChangesDoNotTriggerCalendarRequests() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await sync.refresh(jobID: id)
        var edited = store.jobs[0].metadataAutomation!
        edited.timestampPolicy = edited.timestampPolicy == .localArrival ? .cameraCapture : .localArrival
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await Task.sleep(for: .milliseconds(200))
        let requests = await server.requests
        XCTAssertEqual(requests, ["getCalendar"])
        XCTAssertEqual(sync.activity(for: id).phase, .current)
    }

    func testClosingUnchangedDraftAutomaticallyReceivesWaitingRemoteEdit() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await sync.refresh(jobID: id)
        let original = store.jobs[0].metadataAutomation!
        store.metadataDraftsBeingEdited.insert(id)
        try await eventually { sync.activity(for: id).phase == .paused }
        var incoming = SharedMetadataDocument(original)
        incoming.clips[0].name = "Another Mac's edit"
        await server.replaceRemote(incoming)
        await sync.refresh(jobID: id)
        XCTAssertEqual(store.jobs[0].metadataAutomation, original)
        store.metadataDraftsBeingEdited.remove(id)
        try await eventually { sync.activity(for: id).phase == .current }
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), incoming)
        let writes = await server.writes
        XCTAssertEqual(writes, 0)
    }

    func testRefreshRequestsDuringFetchAreCoalescedAndRunAfterItFinishes() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await server.suspendNextRequest("getCalendar")
        let running = Task { await sync.refresh(jobID: id) }
        try await eventually { await server.isSuspended }
        await sync.refresh(jobID: id)
        await sync.refresh(jobID: id)
        await sync.refresh(jobID: id)
        let blockedRequests = await server.requests
        XCTAssertEqual(blockedRequests, ["getCalendar"])
        await server.resumeRequest()
        await running.value
        try await eventually { await server.requests.count == 2 && !sync.busy }
        let requests = await server.requests
        XCTAssertEqual(requests, ["getCalendar", "getCalendar"])
        XCTAssertEqual(sync.activity(for: id).phase, .current)
    }

    func testSavedEditDuringAnotherOperationSyncsWhenThatOperationFinishes() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await server.suspendNextRequest("listCalendars")
        sync.perform { _ = try await server.send(MetadataCalendarRequest(action: "listCalendars")) }
        try await eventually { await server.isSuspended }
        var edited = store.jobs[0].metadataAutomation!
        edited.clips[0].name = "Saved while busy"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await eventually { sync.activity(for: id).phase == .pending }
        // Keep the other operation in flight beyond the save debounce.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sync.busy)
        await server.resumeRequest()
        try await eventually { await server.writes == 1 && sync.activity(for: id).phase == .current }
        let remote = await server.calendar
        XCTAssertEqual(remote.document.clips[0].name, "Saved while busy")
    }

    func testNewEditDuringUploadIsSentWithoutOverwritingItOrCreatingConflict() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await server.suspendNextRequest("putCalendar")
        var edited = store.jobs[0].metadataAutomation!
        edited.clips[0].name = "First saved edit"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await eventually { await server.isSuspended }
        edited.clips[0].name = "Edited during upload"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        await server.resumeRequest()
        try await eventually { await server.writes == 2 && sync.activity(for: id).phase == .current }
        XCTAssertNil(sync.state.bindings[0].conflict)
        let remote = await server.calendar
        XCTAssertEqual(remote.document.clips[0].name, "Edited during upload")
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), remote.document)
    }

    func testOfflineEditsStaySavedAndRetryRestoresCurrentStatus() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await sync.refresh(jobID: id)
        let lastSuccess = sync.activity(for: id).lastSuccess
        await server.setOffline(true)
        var edited = store.jobs[0].metadataAutomation!
        edited.clips[0].name = "Saved offline"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await eventually { sync.activity(for: id).phase == .offline }
        XCTAssertEqual(sync.activity(for: id).lastSuccess, lastSuccess)
        XCTAssertTrue(sync.activity(for: id).detail.contains("retries automatically"))
        let saved = try JobRepository(fileURL: root.appendingPathComponent("jobs.json")).load()
        XCTAssertEqual(saved[0].metadataAutomation?.clips[0].name, "Saved offline")
        await server.setOffline(false)
        await sync.refresh(jobID: id)
        XCTAssertEqual(sync.activity(for: id).phase, .current)
        XCTAssertNil(sync.state.bindings[0].conflict)
        let remote = await server.calendar
        XCTAssertEqual(remote.document.clips[0].name, "Saved offline")
    }

    func testOfflinePollingSkipsRedundantRequestsAndBacksOff() async throws {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let (root, store, sync, server) = try liveFixture(now: { time })
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        await server.setOffline(true)
        let id = store.jobs[0].id
        await sync.refresh(automatic: true)
        var requests = await server.requests
        XCTAssertEqual(requests, ["listCalendars"], "Do not fetch from an account whose connection just failed")
        XCTAssertEqual(sync.activity(for: id).phase, .offline)
        XCTAssertEqual(sync.events.filter(\.isError).count, 1)
        await sync.refresh(automatic: true)
        requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        time = time.addingTimeInterval(10)
        await sync.refresh(automatic: true)
        requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        time = time.addingTimeInterval(10)
        await sync.refresh(automatic: true)
        requests = await server.requests
        XCTAssertEqual(requests.count, 2, "Second failure must wait 20 seconds")
        time = time.addingTimeInterval(10)
        await sync.refresh(automatic: true)
        requests = await server.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(sync.events.filter(\.isError).count, 1)
        XCTAssertEqual(sync.events.last?.occurrences, 3)
        await server.setOffline(false)
        await sync.refresh(jobID: id) // Explicit Retry Now bypasses the 40-second delay.
        XCTAssertEqual(sync.activity(for: id).phase, .current)
        requests = await server.requests
        XCTAssertEqual(requests.last, "getCalendar")
        await sync.refresh(automatic: true)
        requests = await server.requests
        XCTAssertEqual(Array(requests.suffix(2)), ["listCalendars", "getCalendar"], "Success restores normal automatic polling")
    }

    func testHealthyPollingFetchesUpdatesWithoutListingEveryTenSeconds() async throws {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let (root, store, sync, server) = try liveFixture(now: { time })
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        await sync.refresh(automatic: true)
        time = time.addingTimeInterval(10)
        await sync.refresh(automatic: true)
        var requests = await server.requests
        XCTAssertEqual(requests, ["listCalendars", "getCalendar", "getCalendar"])
        XCTAssertEqual(sync.activity(for: store.jobs[0].id).phase, .current)
        time = time.addingTimeInterval(50)
        await sync.refresh(automatic: true)
        requests = await server.requests
        XCTAssertEqual(Array(requests.suffix(2)), ["listCalendars", "getCalendar"])
    }

    func testSelectingAccountInvalidatesTheClearedCalendarPicker() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        await sync.refresh(automatic: true)
        sync.selectAccount(sync.state.activeAccountID!)
        await sync.refresh(automatic: true)
        let requests = await server.requests
        XCTAssertEqual(requests.filter { $0 == "listCalendars" }.count, 2)
        XCTAssertEqual(sync.activity(for: store.jobs[0].id).phase, .current)
    }

    func testQueuedManualRetryBypassesAnAutomaticRefreshCooldown() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        await server.setOffline(true)
        await server.suspendNextRequest("listCalendars")
        let running = Task { await sync.refresh(automatic: true) }
        try await eventually { await server.isSuspended }
        await sync.refresh(automatic: true)
        await sync.refresh(jobID: store.jobs[0].id)
        await server.resumeRequest()
        await running.value
        try await eventually { await server.requests.count == 2 && !sync.busy }
        let requests = await server.requests
        XCTAssertEqual(requests, ["listCalendars", "getCalendar"], "Queued Retry Now must survive a coalesced automatic refresh")
    }

    func testFetchNetworkFailureHasOneEventAndSavedEditsRespectCooldown() async throws {
        let (root, store, sync, server) = try liveFixture()
        defer { sync.stop(); try? FileManager.default.removeItem(at: root) }
        let id = store.jobs[0].id
        await server.setOffline(true)
        await sync.refresh(jobID: id)
        XCTAssertEqual(sync.events.filter(\.isError).count, 1)
        XCTAssertEqual(sync.events.last?.operation, "Fetch calendar")
        var edited = store.jobs[0].metadataAutomation!
        edited.clips[0].name = "Keep this edit through cooldown"
        XCTAssertTrue(store.saveMetadataAutomation(edited, for: id))
        try await Task.sleep(for: .milliseconds(250))
        let requests = await server.requests
        XCTAssertEqual(requests, ["getCalendar"])
        let saved = try JobRepository(fileURL: root.appendingPathComponent("jobs.json")).load()
        XCTAssertEqual(saved[0].metadataAutomation?.clips[0].name, edited.clips[0].name)
        await server.setOffline(false)
        await sync.refresh(jobID: id)
        let remote = await server.calendar
        XCTAssertEqual(remote.document.clips[0].name, edited.clips[0].name)
        XCTAssertEqual(sync.activity(for: id).phase, .current)
    }

    private func assertUnsafeRemotePreservesLocal(
        baseline: SharedMetadataCalendar, remote: SharedMetadataCalendar, expectedMessage: String
    ) async throws {
        // Exercise polling and both choices on an already-saved conflict. None may
        // reinterpret hidden/older records as deletions, even after restarting.
        for keepLocal in [nil, false, true] as [Bool?] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var job = SyncJob(name: "Local calendar")
            job.metadataAutomation = baseline.document.automation
            let store = try makeStore(root: root, job: job)
            let originalJobs = store.jobs
            let account = MetadataSyncAccount(id: UUID(), address: "https://sync.example.org/", registered: true)
            let binding = MetadataCalendarBinding(accountID: account.id, jobID: job.id, snapshot: baseline,
                conflict: keepLocal == nil ? nil : remote)
            let repository = MetadataCalendarRepository(url: root.appendingPathComponent("sync.json"))
            try repository.save(MetadataCalendarState(accounts: [account], activeAccountID: account.id, bindings: [binding]))
            let server = CalendarTransportFixture(calendar: remote)
            let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
            let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: { body, _, _, _, _ in try await server.send(body) })
            sync.start(store: store, polling: false, observingChanges: false)
            if let keepLocal {
                let review = try sync.conflictReview(binding)
                let choices = Dictionary(uniqueKeysWithValues: try review.plan().conflicts.map {
                    ($0.id, keepLocal ? MetadataConflictChoice.local : .server)
                })
                sync.resolve(review, choices: choices)
                try await finishOperation(sync)
                XCTAssertTrue(sync.message.contains(expectedMessage), sync.message)
            } else {
                await sync.refresh()
                XCTAssertTrue(sync.bindingMessages[binding.id]?.contains(expectedMessage) == true)
            }
            XCTAssertEqual(store.jobs, originalJobs)
            XCTAssertEqual(try repository.load().bindings, [binding])
            let writes = await server.writes
            XCTAssertEqual(writes, 0)
        }
    }

    func testChangedSharingScopeOrTimeZonePreservesLocalProgramming() async throws {
        let (root, _, _, _, calendar) = try receiveFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var narrower = calendar
        narrower.rangeStart = calendar.document.clips[0].endsAt
        narrower.rangeEnd = narrower.rangeStart!.addingTimeInterval(86_400)
        narrower.document = SharedMetadataDocument(MetadataAutomation())
        try await assertUnsafeRemotePreservesLocal(baseline: calendar, remote: narrower, expectedMessage: "date range")

        var scoped = calendar
        scoped.rangeStart = calendar.document.clips[0].startsAt
        scoped.rangeEnd = calendar.document.clips[0].endsAt
        try await assertUnsafeRemotePreservesLocal(baseline: scoped, remote: calendar, expectedMessage: "date range")

        var changedZone = calendar
        changedZone.timeZone = "America/New_York"
        try await assertUnsafeRemotePreservesLocal(baseline: calendar, remote: changedZone, expectedMessage: "time zone")
    }

    func testRestoredOlderServerSnapshotPreservesLocalProgramming() async throws {
        let (root, _, _, _, remote) = try receiveFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var baseline = remote
        baseline.revision += 1
        baseline.document.clips[0].name = "New programming absent from the backup"
        try await assertUnsafeRemotePreservesLocal(baseline: baseline, remote: remote, expectedMessage: "older calendar revision")
    }

    func testTwoDevicesAgainstPHPServer() async throws {
        guard let address = ProcessInfo.processInfo.environment["AFTPSYNC_METADATA_TEST_URL"],
              let endpoint = URL(string: address), endpoint.scheme == "http", endpoint.host == "127.0.0.1" else {
            throw XCTSkip("Set AFTPSYNC_METADATA_TEST_URL to the disposable loopback PHP server endpoint.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport: MetadataCalendarCoordinator.Transport = { body, _, id, key, setup in
            // Loopback HTTP is confined to this test transport. Production requires HTTPS.
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try MetadataCalendarClient.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2", forHTTPHeaderField: "X-Aagedal-Protocol")
            request.setValue(id.uuidString, forHTTPHeaderField: "X-Aagedal-Device-ID")
            request.setValue(key, forHTTPHeaderField: "X-Aagedal-Device-Key")
            if let setup { request.setValue(setup, forHTTPHeaderField: "X-Aagedal-Setup-Key") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return try MetadataCalendarClient.decodeResponse(data, statusCode: (response as! HTTPURLResponse).statusCode, calendarID: body.calendarID)
        }
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let profile = PhotographerProfile(name: "Example ÆØÅ", filenamePrefix: "EX", creator: "Example", copyrightNotice: "Example")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = MetadataScheduleClip(photographerID: profile.id, name: "First", startsAt: start, endsAt: start.addingTimeInterval(100))
        let second = MetadataScheduleClip(photographerID: profile.id, name: "Second", startsAt: start.addingTimeInterval(200), endsAt: start.addingTimeInterval(300))
        var jobA = SyncJob(name: "Publishing job")
        jobA.metadataAutomation = MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [first, second])
        let jobB = SyncJob(name: "Different receiving job")
        let storeA = try makeStore(root: root.appendingPathComponent("a"), job: jobA)
        let storeB = try makeStore(root: root.appendingPathComponent("b"), job: jobB)
        let a = MetadataCalendarCoordinator(repository: MetadataCalendarRepository(url: root.appendingPathComponent("a/sync.json")), keychain: keychain, transport: transport)
        let b = MetadataCalendarCoordinator(repository: MetadataCalendarRepository(url: root.appendingPathComponent("b/sync.json")), keychain: keychain, transport: transport)
        a.start(store: storeA, polling: false, observingChanges: false); b.start(store: storeB, polling: false, observingChanges: false)
        a.register(address: "https://sync.example.org/", deviceName: "Mac A", setupKey: String(repeating: "a", count: 64), invite: nil)
        try await finishOperation(a)
        XCTAssertEqual(a.account?.registered, true, a.message)
        a.publish(jobID: jobA.id, name: "Wire test", range: nil)
        try await finishOperation(a)
        let calendar = try XCTUnwrap(a.calendars.first, a.message)
        a.createInvite(calendarID: calendar.id, role: "editor", range: nil)
        try await finishOperation(a)
        XCTAssertFalse(a.invitation.isEmpty, a.message)
        b.register(address: "", deviceName: "Mac B", setupKey: nil,
                   invite: "Server: https://sync.example.org/\nInvitation: \(a.invitation)\n")
        try await finishOperation(b)
        XCTAssertEqual(b.account?.registered, true, b.message)
        XCTAssertEqual(b.suggestedCalendarID, calendar.id)
        b.attach(calendarID: calendar.id, jobID: jobB.id)
        try await finishOperation(b)
        XCTAssertEqual(SharedMetadataDocument(storeB.jobs[0].metadataAutomation!), SharedMetadataDocument(jobA.metadataAutomation!), b.message)

        // Both devices edit different clips offline, then reconnect in sequence.
        var editA = storeA.jobs[0].metadataAutomation!
        var editB = storeB.jobs[0].metadataAutomation!
        editA.clips[editA.clips.firstIndex { $0.id == first.id }!].fields.headline = "Edit from Mac A"
        editB.clips[editB.clips.firstIndex { $0.id == second.id }!].fields.headline = "Edit from Mac B"
        XCTAssertTrue(storeA.applySyncedMetadataAutomation(editA, for: jobA.id))
        XCTAssertTrue(storeB.applySyncedMetadataAutomation(editB, for: jobB.id))
        await a.refresh(jobID: jobA.id)
        await b.refresh(jobID: jobB.id)
        await a.refresh(jobID: jobA.id)
        XCTAssertEqual(a.activity(for: jobA.id).phase, .current, a.activity(for: jobA.id).detail)
        XCTAssertEqual(b.activity(for: jobB.id).phase, .current, b.activity(for: jobB.id).detail)
        let finalA = SharedMetadataDocument(storeA.jobs[0].metadataAutomation!)
        XCTAssertEqual(finalA, SharedMetadataDocument(storeB.jobs[0].metadataAutomation!))
        XCTAssertEqual(Set(finalA.clips.map(\.fields.headline)), ["Edit from Mac A", "Edit from Mac B"])
        XCTAssertFalse(a.diagnosticText().contains("Edit from Mac A"))
        XCTAssertFalse(b.diagnosticText().contains("sync.example.org"))
        XCTAssertFalse(b.diagnosticText().contains(a.invitation))

        // Competing edits to one clip require one choice; other clips and fields survive.
        var competingA = storeA.jobs[0].metadataAutomation!
        var competingB = storeB.jobs[0].metadataAutomation!
        let ai = competingA.clips.firstIndex { $0.id == first.id }!
        let bi = competingB.clips.firstIndex { $0.id == first.id }!
        competingA.clips[ai].fields.description = "Description chosen from A"
        competingB.clips[bi].fields.description = "Description chosen from B"
        competingB.clips[bi].fields.keywords = ["Independent B keyword"]
        competingA.clips[competingA.clips.firstIndex { $0.id == second.id }!].name = "Independent A clip name"
        XCTAssertTrue(storeA.applySyncedMetadataAutomation(competingA, for: jobA.id))
        XCTAssertTrue(storeB.applySyncedMetadataAutomation(competingB, for: jobB.id))
        await a.refresh(jobID: jobA.id)
        await b.refresh(jobID: jobB.id)
        let conflictBinding = try XCTUnwrap(b.binding(for: jobB.id))
        XCTAssertNotNil(conflictBinding.conflict)
        let review = try b.conflictReview(conflictBinding)
        XCTAssertEqual(try review.plan().conflicts.count, 1)
        b.resolve(review, choices: ["clip/\(first.id)": .server])
        try await finishOperation(b)
        await a.refresh(jobID: jobA.id)
        let resolvedA = SharedMetadataDocument(storeA.jobs[0].metadataAutomation!)
        XCTAssertEqual(resolvedA, SharedMetadataDocument(storeB.jobs[0].metadataAutomation!))
        XCTAssertEqual(resolvedA.clips.first { $0.id == first.id }?.fields.description, "Description chosen from A")
        XCTAssertEqual(resolvedA.clips.first { $0.id == first.id }?.fields.keywords, ["Independent B keyword"])
        XCTAssertEqual(resolvedA.clips.first { $0.id == second.id }?.name, "Independent A clip name")
        XCTAssertNil(b.binding(for: jobB.id)?.conflict)

        // A date-limited third device can edit its clip without seeing or replacing
        // the other dates on the same shared calendar.
        a.createInvite(calendarID: calendar.id, role: "editor", range: MetadataSharingRange(start: first.startsAt, end: first.endsAt))
        try await finishOperation(a)
        let jobC = SyncJob(name: "Limited receiving job")
        let storeC = try makeStore(root: root.appendingPathComponent("c"), job: jobC)
        let c = MetadataCalendarCoordinator(repository: MetadataCalendarRepository(url: root.appendingPathComponent("c/sync.json")), keychain: keychain, transport: transport)
        c.start(store: storeC, polling: false, observingChanges: false)
        c.register(address: "https://sync.example.org/", deviceName: "Mac C", setupKey: nil, invite: a.invitation)
        try await finishOperation(c)
        c.attach(calendarID: calendar.id, jobID: jobC.id)
        try await finishOperation(c)
        var limited = try XCTUnwrap(storeC.jobs[0].metadataAutomation, c.message)
        XCTAssertEqual(limited.clips.map(\.id), [first.id])
        limited.clips[0].fields.headline = "Limited editor update"
        XCTAssertTrue(storeC.applySyncedMetadataAutomation(limited, for: jobC.id))
        await c.refresh(jobID: jobC.id)
        XCTAssertEqual(c.activity(for: jobC.id).phase, .current, c.activity(for: jobC.id).detail)
        await a.refresh(jobID: jobA.id)
        let afterLimitedEdit = storeA.jobs[0].metadataAutomation!
        XCTAssertEqual(afterLimitedEdit.clips.first { $0.id == first.id }?.fields.headline, "Limited editor update")
        XCTAssertEqual(afterLimitedEdit.clips.first { $0.id == second.id }?.fields.headline, "Edit from Mac B")
    }

    func testPopulatedJobRequiresConsentThenPreservesOriginalAndReceivesIntoPausedCopy() async throws {
        let (root, store, sync, repository, calendar) = try receiveFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = store.jobs[0]
        source.startsOnAppLaunch = true
        XCTAssertTrue(store.saveJob(source, leftPassword: "", rightPassword: ""))
        store.setEnabled(true, for: source.id)
        source = store.jobs[0]
        XCTAssertTrue(source.isEnabled)
        XCTAssertTrue(source.startsOnAppLaunch)
        sync.attach(calendarID: calendar.id, jobID: source.id)
        try await finishOperation(sync)
        XCTAssertNotNil(sync.receiveProposal)
        XCTAssertEqual(store.jobs, [source])
        XCTAssertTrue(try repository.load().bindings.isEmpty)
        sync.receiveProposal = nil // Cancel has no persistent effects.
        XCTAssertEqual(store.jobs, [source])
        sync.attach(calendarID: calendar.id, jobID: source.id)
        try await finishOperation(sync)
        let proposal = try XCTUnwrap(sync.receiveProposal)
        sync.confirmReceive(proposal)
        try await finishOperation(sync)
        XCTAssertEqual(store.jobs.count, 2)
        let original = try XCTUnwrap(store.jobs.first { $0.id == source.id })
        let copy = try XCTUnwrap(store.jobs.first { $0.id == proposal.duplicate.id })
        XCTAssertEqual(original.metadataAutomation, source.metadataAutomation)
        XCTAssertFalse(original.isEnabled)
        XCTAssertFalse(original.startsOnAppLaunch)
        XCTAssertFalse(copy.isEnabled)
        XCTAssertFalse(copy.startsOnAppLaunch)
        XCTAssertEqual(copy.left, source.left)
        XCTAssertEqual(copy.right, source.right)
        XCTAssertEqual(copy.intervalSeconds, source.intervalSeconds)
        XCTAssertEqual(copy.metadataAutomation?.timestampPolicy, .cameraCapture)
        XCTAssertEqual(SharedMetadataDocument(copy.metadataAutomation!), calendar.document)
        XCTAssertEqual(try repository.load().bindings.first?.jobID, copy.id)
        XCTAssertEqual(store.selectedJobID, copy.id, "The Metadata window should show the job that received the calendar")
        XCTAssertNil(try repository.load().pendingReceive)
    }

    func testReceiveRejectsChangedSourceAfterConfirmationWasPresented() async throws {
        let (root, store, sync, _, calendar) = try receiveFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        sync.attach(calendarID: calendar.id, jobID: store.jobs[0].id)
        try await finishOperation(sync)
        let proposal = try XCTUnwrap(sync.receiveProposal)
        var changed = store.jobs[0].metadataAutomation!
        changed.clips[0].name = "New local edit"
        XCTAssertTrue(store.applySyncedMetadataAutomation(changed, for: store.jobs[0].id))
        sync.confirmReceive(proposal)
        try await finishOperation(sync)
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.jobs[0].metadataAutomation, changed)
        XCTAssertNil(sync.state.pendingReceive)
        XCTAssertTrue(sync.message.contains("original job changed"))
    }

    func testFailedJobsWriteKeepsOriginalIntactAndPendingReceiveCanBeCancelled() async throws {
        let gate = ReceiveSaveGate()
        let (root, store, sync, repository, calendar) = try receiveFixture(jobGate: gate)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = store.jobs[0]
        sync.attach(calendarID: calendar.id, jobID: source.id)
        try await finishOperation(sync)
        let proposal = try XCTUnwrap(sync.receiveProposal)
        gate.failNext()
        sync.confirmReceive(proposal)
        try await finishOperation(sync)
        XCTAssertEqual(store.jobs, [source])
        XCTAssertEqual(try JobRepository(fileURL: root.appendingPathComponent("jobs.json")).load(), [source])
        XCTAssertNotNil(try repository.load().pendingReceive)
        sync.cancelPendingReceive()
        XCTAssertNil(try repository.load().pendingReceive)
        XCTAssertEqual(store.jobs, [source])
    }

    func testInterruptedReceiveResumesWithoutDuplicatingJobOrOverwritingNewEdits() async throws {
        let gate = ReceiveSaveGate()
        let (root, store, sync, repository, calendar) = try receiveFixture(syncGate: gate)
        defer { try? FileManager.default.removeItem(at: root) }
        sync.attach(calendarID: calendar.id, jobID: store.jobs[0].id)
        try await finishOperation(sync)
        let proposal = try XCTUnwrap(sync.receiveProposal)
        gate.failAfterOneSave() // Journal succeeds; finishing the link fails after jobs commit.
        sync.confirmReceive(proposal)
        try await finishOperation(sync)
        XCTAssertEqual(store.jobs.count, 2)
        XCTAssertNotNil(try repository.load().pendingReceive)
        var edited = store.jobs.first { $0.id == proposal.duplicate.id }!.metadataAutomation!
        edited.clips[0].name = "Edit made after the copy was saved"
        XCTAssertTrue(store.applySyncedMetadataAutomation(edited, for: proposal.duplicate.id))
        let server = CalendarTransportFixture(calendar: calendar)
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let restarted = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: { body, _, _, _, _ in try await server.send(body) })
        restarted.start(store: store, polling: false, observingChanges: false)
        await restarted.refresh()
        XCTAssertEqual(store.jobs.count, 2)
        XCTAssertNil(try repository.load().pendingReceive)
        XCTAssertEqual(restarted.state.bindings.first?.jobID, proposal.duplicate.id)
        XCTAssertEqual(store.jobs.first { $0.id == proposal.duplicate.id }?.metadataAutomation?.clips.first?.name, "Edit made after the copy was saved")
    }

    func testOpenDraftMergesIndependentIncomingEditAndRejectsCompetingEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = PhotographerProfile(name: "Example", filenamePrefix: "EX", creator: "Example", copyrightNotice: "")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = MetadataScheduleClip(photographerID: profile.id, name: "First", startsAt: start, endsAt: start.addingTimeInterval(100))
        let second = MetadataScheduleClip(photographerID: profile.id, name: "Second", startsAt: start.addingTimeInterval(200), endsAt: start.addingTimeInterval(300))
        let original = MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [first, second])
        var job = SyncJob(name: "Example job"); job.metadataAutomation = original
        let store = try makeStore(root: root, job: job)
        store.selectedJobID = job.id
        let editor = MetadataProgrammingCoordinator()
        editor.loadSelectedJob(from: store)
        editor.draft.clips[0].fields.headline = "Draft headline"
        var incoming = original; incoming.clips[1].fields.description = "Incoming description"
        XCTAssertTrue(store.applySyncedMetadataAutomation(incoming, for: job.id))
        XCTAssertTrue(editor.save(in: store), store.alertMessage ?? "Save rejected")
        XCTAssertEqual(store.jobs[0].metadataAutomation?.clips.first(where: { $0.id == first.id })?.fields.headline, "Draft headline")
        XCTAssertEqual(store.jobs[0].metadataAutomation?.clips.first(where: { $0.id == second.id })?.fields.description, "Incoming description")

        editor.draft.clips[0].name = "Local name"
        var competing = store.jobs[0].metadataAutomation!
        competing.clips[0].name = "Remote name"
        XCTAssertTrue(store.applySyncedMetadataAutomation(competing, for: job.id))
        XCTAssertFalse(editor.save(in: store))
        XCTAssertEqual(store.jobs[0].metadataAutomation, competing)
        XCTAssertEqual(editor.draft.clips[0].name, "Local name")
    }

    func testLostCommitResponseSurvivesRestartWithoutDuplicateWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = PhotographerProfile(name: "Example", filenamePrefix: "EX", creator: "Example", copyrightNotice: "")
        let clip = MetadataScheduleClip(photographerID: p.id, name: "Example", startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_100))
        let base = SharedMetadataDocument(MetadataAutomation(photographers: [p], photographerTracks: [], clips: [clip]))
        var changed = base; changed.clips[0].name = "Offline edit"
        var job = SyncJob(name: "Example job"); job.metadataAutomation = changed.automation
        let store = try makeStore(root: root, job: job)
        let account = MetadataSyncAccount(id: UUID(), address: "https://sync.example.org/", registered: true)
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Example", timeZone: "Etc/UTC", revision: 1, role: "owner", document: base)
        let binding = MetadataCalendarBinding(accountID: account.id, jobID: job.id, snapshot: calendar)
        let repository = MetadataCalendarRepository(url: root.appendingPathComponent("sync.json"))
        try repository.save(MetadataCalendarState(accounts: [account], activeAccountID: account.id, bindings: [binding]))
        let server = CalendarTransportFixture(calendar: calendar)
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let transport: MetadataCalendarCoordinator.Transport = { body, _, _, _, _ in try await server.send(body) }
        let first = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: transport)
        first.start(store: store, polling: false, observingChanges: false)
        await server.loseNextResponse()
        await first.refresh()
        XCTAssertEqual(try repository.load().bindings[0].snapshot.revision, 1)
        let second = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: transport)
        second.start(store: store, polling: false, observingChanges: false)
        await second.refresh()
        XCTAssertNil(second.state.bindings[0].conflict)
        XCTAssertEqual(second.state.bindings[0].snapshot.document, changed)
        XCTAssertEqual(second.activity(for: job.id).phase, .current)
        XCTAssertNotNil(second.activity(for: job.id).lastSuccess)
        let writes = await server.writes
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), changed)

        var incoming = changed; incoming.clips[0].fields.headline = "Incoming update"
        await server.replaceRemote(incoming)
        store.metadataDraftsBeingEdited.insert(job.id)
        await second.refresh()
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), changed)
        XCTAssertEqual(second.activity(for: job.id).phase, .paused)
        store.metadataDraftsBeingEdited.remove(job.id)
        await second.refresh()
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), incoming)

        var remote = incoming; remote.clips[0].name = "Remote edit"
        var local = incoming; local.clips[0].name = "Another local edit"
        XCTAssertTrue(store.applySyncedMetadataAutomation(local.automation, for: job.id))
        await server.replaceRemote(remote)
        await second.refresh()
        XCTAssertNotNil(second.state.bindings[0].conflict)
        XCTAssertEqual(second.activity(for: job.id).phase, .conflict)
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), local)
        XCTAssertEqual(try repository.load().bindings[0].conflict?.document, remote)
    }
}

final class MetadataCalendarProtocolTests: XCTestCase {
    func testMissingPrivateConfigurationIsExplainedForBothServerEnvelopes() {
        for version in [1, 2] {
            let data = Data("{\"service\":\"aagedal-metadata-sync\",\"protocolVersion\":\(version),\"error\":\"not_configured\"}".utf8)
            XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(data, statusCode: 503, calendarID: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains("private config.php"))
                XCTAssertTrue(error.localizedDescription.contains("$configPath"))
                XCTAssertFalse(error.localizedDescription.contains("unsupported protocol"))
            }
        }
    }

    func testOldHostingAPIResponseDirectsUserToUploadCurrentFiles() {
        let data = Data(#"{"service":"aagedal-metadata-sync","protocolVersion":1,"error":"unauthorized"}"#.utf8)
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(data, statusCode: 401, calendarID: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("index.php and live.php"))
        }
    }

    func testMissingLiveAPIAndBootstrapErrorsStayActionable() {
        for (code, status, expected) in [("live_api_missing", 503, "Upload live.php"), ("bootstrap_disabled", 403, "First-device setup")] {
            let data = Data("{\"service\":\"aagedal-metadata-sync\",\"protocolVersion\":2,\"error\":\"\(code)\"}".utf8)
            XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(data, statusCode: status, calendarID: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected))
            }
        }
    }

    func testUnknownProtocolsAndUnrelatedServicesStillFailValidation() {
        let future = Data(#"{"service":"aagedal-metadata-sync","protocolVersion":99,"error":"not_configured"}"#.utf8)
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(future, statusCode: 503, calendarID: nil)) { error in
            XCTAssertEqual(error as? MetadataSyncServerError, .unsupportedProtocol)
        }
        let unrelated = Data(#"{"service":"unrelated","protocolVersion":2,"error":"not_configured"}"#.utf8)
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(unrelated, statusCode: 503, calendarID: nil)) { error in
            XCTAssertEqual(error as? MetadataSyncServerError, .invalidResponse)
        }
        let unexpected = Data(#"{"service":"aagedal-metadata-sync","protocolVersion":2,"error":"private exception detail"}"#.utf8)
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(unexpected, statusCode: 503, calendarID: nil)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private exception detail"))
        }
    }
}

private final class ReceiveSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?
    func failNext() { lock.withLock { remaining = 0 } }
    func failAfterOneSave() { lock.withLock { remaining = 1 } }
    func check() throws {
        try lock.withLock {
            guard let count = remaining else { return }
            if count == 0 {
                remaining = nil
                throw MetadataSyncFailure(message: "Synthetic storage failure")
            }
            remaining = count - 1
        }
    }
}

final class MetadataSyncFeedbackTests: XCTestCase {
    func testInvitationAcceptsCopiedTextAndWhitespaceWithoutRelaxingServerValidation() throws {
        let token = String(repeating: "a", count: 64)
        let parsed = try MetadataSyncInvitation("Server: https://SYNC.example.org/calendar/\r\nInvitation: \(token)\r\n")
        XCTAssertEqual(parsed.address, "https://sync.example.org/calendar/")
        XCTAssertEqual(parsed.token, token)
        XCTAssertEqual(try MetadataSyncInvitation(" \(token)\n").token, token)
        XCTAssertNil(parsed.protocolVersion)
        let template = try MetadataSyncInvitation("Aagedal template calendar invitation\nServer: https://SYNC.example.org/calendar/\nInvitation: \(token)")
        XCTAssertEqual(template.protocolVersion, .templates)
        XCTAssertEqual(template.address, parsed.address)
        XCTAssertEqual(template.token, token)
        XCTAssertEqual(try MetadataSyncInvitation("Aagedal template calendar invitation\r\nServer: https://SYNC.example.org/calendar/\r\nInvitation: \(token)\r\n").protocolVersion, .templates)
        XCTAssertThrowsError(try MetadataSyncInvitation("Aagedal template calendar invitation v4\nInvitation: \(token)"))
        XCTAssertThrowsError(try MetadataSyncInvitation("Server: http://sync.example.org/\nInvitation: \(token)"))
        XCTAssertThrowsError(try MetadataSyncInvitation("not an invitation"))
    }

    func testDiagnosticsDoNotStoreRawNetworkOrCalendarErrors() {
        let privateText = "https://private.example.org/secret?key=secret-key"
        let error = URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: privateText])
        XCTAssertFalse(MetadataSyncEvent.errorDetail(error).contains(privateText))
        XCTAssertFalse(MetadataSyncEvent.errorDetail(MetadataSyncFailure(message: privateText)).contains(privateText))
        XCTAssertTrue(MetadataSyncEvent.errorDetail(error).contains("-1004"))
    }

    func testDiagnosticHistoryIsBoundedAndSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MetadataSyncEventRepository(url: root.appendingPathComponent("events.json"))
        let events = (0..<205).map { MetadataSyncEvent(operation: "Fetch calendar", detail: "Request completed.", revision: Int64($0)) }
        try repository.save(events)
        let loaded = repository.load()
        XCTAssertEqual(loaded.count, 200)
        XCTAssertEqual(loaded.first?.revision, 5)
        XCTAssertEqual(loaded.last?.revision, 204)
    }
}

extension SharedMetadataCalendarTests {
    func testDifferentFieldsOnSameClipMergeAutomatically() throws {
        let base = SharedMetadataDocument(fixture())
        var local = base, remote = base
        local.clips[0].fields.headline = "Local headline"
        remote.clips[0].fields.description = "Server description"
        let merged = try SharedMetadataDocument.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.clips[0].fields.headline, "Local headline")
        XCTAssertEqual(merged.clips[0].fields.description, "Server description")
    }

    func testChoicesPerClipKeepUncontestedFieldsAndOtherClips() throws {
        let base = SharedMetadataDocument(fixture())
        var local = base, remote = base
        for index in base.clips.indices {
            local.clips[index].fields.headline = "Local \(index)"
            remote.clips[index].fields.headline = "Server \(index)"
        }
        local.clips[0].fields.description = "Independent local description"
        remote.clips[0].fields.keywords = ["Independent server keyword"]
        remote.clips[1].name = "Independent server name"
        let initial = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote)
        XCTAssertEqual(initial.conflicts.count, 2)
        XCTAssertEqual(initial.unresolvedCount, 2)
        XCTAssertThrowsError(try initial.resolved())
        let choices: [String: MetadataConflictChoice] = ["clip/\(base.clips[0].id)": .local, "clip/\(base.clips[1].id)": .server]
        let resolved = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote, choices: choices).resolved()
        XCTAssertEqual(resolved.clips[0].fields.headline, "Local 0")
        XCTAssertEqual(resolved.clips[1].fields.headline, "Server 1")
        XCTAssertEqual(resolved.clips[0].fields.description, local.clips[0].fields.description)
        XCTAssertEqual(resolved.clips[0].fields.keywords, remote.clips[0].fields.keywords)
        XCTAssertEqual(resolved.clips[1].name, remote.clips[1].name)
    }

    func testDeletingConflictingClipDoesNotDiscardUnrelatedServerEdits() throws {
        let base = SharedMetadataDocument(fixture())
        var local = base, remote = base
        let deleted = local.clips.removeFirst()
        remote.clips[0].fields.description = "Edited before deletion arrived"
        remote.clips[1].name = "Unrelated edit"
        for choice in [MetadataConflictChoice.local, .server] {
            let plan = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote, choices: ["clip/\(deleted.id)": choice])
            let result = try plan.resolved()
            XCTAssertEqual(plan.conflicts.count, 1)
            XCTAssertEqual(result.clips.contains { $0.id == deleted.id }, choice == .server)
            XCTAssertEqual(result.clips.first { $0.id == remote.clips[1].id }?.name, "Unrelated edit")
            if choice == .server { XCTAssertTrue(result.clips.contains(remote.clips[0])) }
        }
    }

    func testConcurrentAdditionWithSameIDRequiresChoice() throws {
        let full = SharedMetadataDocument(fixture())
        var base = full, local = full, remote = full
        base.clips.removeFirst()
        local.clips[0].name = "Local addition"
        remote.clips[0].name = "Remote addition"
        let plan = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertThrowsError(try plan.resolved())
        let result = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote, choices: [plan.conflicts[0].id: .server]).resolved()
        XCTAssertEqual(result, remote)
    }

    func testOverlapResolutionKeepsIndependentlyMergedText() throws {
        let base = SharedMetadataDocument(fixture())
        let first = base.clips.firstIndex { $0.name == "First" }!, second = base.clips.firstIndex { $0.name == "Second" }!
        var local = base, remote = base
        local.clips[first].endsAt = base.clips[first].startsAt.addingTimeInterval(180)
        remote.clips[second].startsAt = base.clips[first].startsAt.addingTimeInterval(150)
        local.clips[second].fields.description = "Keep this local description"
        remote.clips[first].fields.headline = "Keep this server headline"
        let initial = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote)
        XCTAssertEqual(initial.conflicts.count, 1)
        XCTAssertTrue(initial.conflicts[0].id.hasPrefix("overlap/"))
        for choice in [MetadataConflictChoice.local, .server] {
            let result = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote, choices: [initial.conflicts[0].id: choice]).resolved()
            XCTAssertEqual(result.clips[first].fields.headline, remote.clips[first].fields.headline)
            XCTAssertEqual(result.clips[second].fields.description, local.clips[second].fields.description)
            let side = choice == .local ? local : remote
            XCTAssertEqual(result.clips[first].endsAt, side.clips[first].endsAt)
            XCTAssertEqual(result.clips[second].startsAt, side.clips[second].startsAt)
        }
    }

    func testReadOnlyReviewRequiresServerChoicesForEveryLocalEdit() throws {
        let base = SharedMetadataDocument(fixture())
        var local = base, remote = base
        local.clips[0].fields.headline = "Local change"
        remote.clips[1].fields.description = "Incoming change"
        let initial = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote, readOnly: true)
        XCTAssertEqual(initial.conflicts.count, 1)
        XCTAssertThrowsError(try initial.resolved())
        XCTAssertThrowsError(try MetadataCalendarMerge.plan(base: base, local: local, remote: remote,
            choices: [initial.conflicts[0].id: .local], readOnly: true).resolved())
        let result = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote,
            choices: [initial.conflicts[0].id: .server], readOnly: true).resolved()
        XCTAssertEqual(result, remote)
    }

    func testPhotographerDeletionAndNewClipRequireDependencyChoice() throws {
        let full = SharedMetadataDocument(fixture())
        var base = full, local = full
        base.clips = []; local.clips = []
        local.photographers = []
        let initial = try MetadataCalendarMerge.plan(base: base, local: local, remote: full)
        XCTAssertEqual(initial.conflicts.count, 1)
        XCTAssertTrue(initial.conflicts[0].id.hasPrefix("reference/"))
        let retained = try MetadataCalendarMerge.plan(base: base, local: local, remote: full,
            choices: [initial.conflicts[0].id: .server]).resolved()
        XCTAssertEqual(retained, full)
        let deleted = try MetadataCalendarMerge.plan(base: base, local: local, remote: full,
            choices: [initial.conflicts[0].id: .local]).resolved()
        XCTAssertEqual(deleted, local)
    }

    func testInvalidDuplicateRecordsAreRejectedBeforeMerge() {
        let base = SharedMetadataDocument(fixture())
        var invalid = base
        invalid.clips.append(invalid.clips[0])
        XCTAssertThrowsError(try MetadataCalendarMerge.plan(base: base, local: invalid, remote: base))
    }
}

extension MetadataCalendarCoordinatorTests {
    private func conflictFixture(syncGate: ReceiveSaveGate? = nil) throws
        -> (URL, AppStore, MetadataCalendarCoordinator, MetadataCalendarRepository, CalendarTransportFixture) {
        let (root, store, _, repository, initial) = try receiveFixture(syncGate: syncGate)
        var baseline = initial
        let first = baseline.document.clips[0]
        baseline.document.clips.append(MetadataScheduleClip(photographerID: first.photographerID, name: "Independent clip",
            startsAt: first.endsAt.addingTimeInterval(600), endsAt: first.endsAt.addingTimeInterval(900)))
        baseline.document = try baseline.document.validated()
        var local = baseline.document, remote = baseline
        let index = local.clips.firstIndex { $0.id == first.id }!
        local.clips[index].fields.headline = "Local headline"
        local.clips[index].fields.description = "Independent local description"
        remote.document.clips[index].fields.headline = "Server headline"
        remote.document.clips[1 - index].name = "Independent server clip"
        remote.revision += 1
        XCTAssertTrue(store.applySyncedMetadataAutomation(local.automation, for: store.jobs[0].id))
        var state = try repository.load()
        let account = state.accounts[0]
        state.bindings = [MetadataCalendarBinding(accountID: account.id, jobID: store.jobs[0].id, snapshot: baseline, conflict: remote)]
        try repository.save(state)
        let server = CalendarTransportFixture(calendar: remote)
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: { body, _, _, _, _ in try await server.send(body) })
        sync.start(store: store, polling: false, observingChanges: false)
        return (root, store, sync, repository, server)
    }

    func testConflictResolutionPersistsAndSendsOnlySelectedConflictingValues() async throws {
        let (root, store, sync, repository, server) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try sync.conflictReview(sync.state.bindings[0])
        let conflict = try XCTUnwrap(review.plan().conflicts.first)
        sync.resolve(review, choices: [conflict.id: .server])
        try await finishOperation(sync)
        let result = SharedMetadataDocument(store.jobs[0].metadataAutomation!)
        let resolved = try XCTUnwrap(result.clips.first { $0.name == "Shared programming" })
        XCTAssertEqual(resolved.fields.headline, "Server headline")
        XCTAssertEqual(resolved.fields.description, "Independent local description")
        XCTAssertTrue(result.clips.contains { $0.name == "Independent server clip" })
        let serverDocument = await server.calendar.document
        XCTAssertEqual(result, serverDocument)
        XCTAssertEqual(try repository.load().bindings[0].snapshot.document, result)
        XCTAssertNil(sync.state.bindings[0].conflict)
        XCTAssertEqual(sync.activity(for: store.jobs[0].id).phase, .current)
    }

    func testLocalChangeAfterReviewOpensRequiresFreshChoices() async throws {
        let (root, store, sync, repository, server) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = sync.state.bindings[0]
        let review = try sync.conflictReview(binding)
        let conflict = try XCTUnwrap(review.plan().conflicts.first)
        var changed = store.jobs[0].metadataAutomation!
        changed.clips[0].fields.keywords = ["New edit while reviewing"]
        XCTAssertTrue(store.applySyncedMetadataAutomation(changed, for: store.jobs[0].id))
        sync.resolve(review, choices: [conflict.id: .server])
        try await finishOperation(sync)
        XCTAssertTrue(sync.message.contains("local calendar changed"), sync.message)
        XCTAssertEqual(store.jobs[0].metadataAutomation, changed)
        XCTAssertEqual(try repository.load().bindings, [binding])
        let writes = await server.writes
        XCTAssertEqual(writes, 0)
    }

    func testRemoteChangeAfterReviewOpensRequiresFreshChoices() async throws {
        let (root, store, sync, repository, server) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalJobs = store.jobs
        let review = try sync.conflictReview(sync.state.bindings[0])
        let conflict = try XCTUnwrap(review.plan().conflicts.first)
        var changed = review.remote.document
        changed.clips[0].fields.keywords = ["New remote edit"]
        await server.replaceRemote(changed)
        sync.resolve(review, choices: [conflict.id: .server])
        try await finishOperation(sync)
        XCTAssertTrue(sync.message.contains("server changed again"), sync.message)
        XCTAssertEqual(store.jobs, originalJobs)
        XCTAssertEqual(try repository.load().bindings[0].conflict?.document, changed)
        let writes = await server.writes
        XCTAssertEqual(writes, 0)
        let refreshed = try sync.conflictReview(sync.state.bindings[0])
        let choices = Dictionary(uniqueKeysWithValues: try refreshed.plan().conflicts.map { ($0.id, MetadataConflictChoice.server) })
        sync.resolve(refreshed, choices: choices)
        try await finishOperation(sync)
        XCTAssertNil(sync.state.bindings[0].conflict)
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!).clips[0].fields.keywords, ["New remote edit"])
    }

    func testResolvedChangesSurviveLostResponseAndRestart() async throws {
        let (root, store, sync, repository, server) = try conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try sync.conflictReview(sync.state.bindings[0])
        let choices = Dictionary(uniqueKeysWithValues: try review.plan().conflicts.map { ($0.id, MetadataConflictChoice.local) })
        let expected = try review.plan(choices: choices).resolved()
        await server.loseNextResponse()
        sync.resolve(review, choices: choices)
        try await finishOperation(sync)
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), expected)
        XCTAssertEqual(sync.activity(for: store.jobs[0].id).phase, .offline)
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) }, passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let restarted = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: { body, _, _, _, _ in try await server.send(body) })
        restarted.start(store: store, polling: false, observingChanges: false)
        await restarted.refresh()
        XCTAssertNil(restarted.state.bindings[0].conflict)
        XCTAssertEqual(restarted.state.bindings[0].snapshot.document, expected)
        let writes = await server.writes
        XCTAssertEqual(writes, 1)
    }

    func testFailedBaselineSaveRetainsResolvedJobAndOriginalConflict() async throws {
        let gate = ReceiveSaveGate()
        let (root, store, sync, repository, server) = try conflictFixture(syncGate: gate)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = sync.state.bindings[0]
        let review = try sync.conflictReview(binding)
        let choices = Dictionary(uniqueKeysWithValues: try review.plan().conflicts.map { ($0.id, MetadataConflictChoice.local) })
        let expected = try review.plan(choices: choices).resolved()
        gate.failNext()
        sync.resolve(review, choices: choices)
        try await finishOperation(sync)
        XCTAssertEqual(SharedMetadataDocument(store.jobs[0].metadataAutomation!), expected)
        XCTAssertEqual(try repository.load().bindings, [binding])
        let writes = await server.writes
        XCTAssertEqual(writes, 0)
        let refreshed = try sync.conflictReview(binding)
        sync.resolve(refreshed, choices: choices)
        try await finishOperation(sync)
        XCTAssertNil(sync.state.bindings[0].conflict)
        let document = await server.calendar.document
        XCTAssertEqual(document, expected)
    }
}

extension SharedMetadataCalendarTests {
    func testOverlapChoicesIncludeSchedulesTheyWouldOtherwiseCollideWith() throws {
        var automation = fixture()
        let start = automation.clips[0].startsAt
        automation.clips.append(MetadataScheduleClip(photographerID: automation.photographers[0].id, name: "Third",
            startsAt: start.addingTimeInterval(400), endsAt: start.addingTimeInterval(500)))
        let base = SharedMetadataDocument(automation)
        var local = base, remote = base
        let a = base.clips.firstIndex { $0.name == "First" }!
        let b = base.clips.firstIndex { $0.name == "Second" }!
        let c = base.clips.firstIndex { $0.name == "Third" }!
        local.clips[a].startsAt = start.addingTimeInterval(1000)
        local.clips[a].endsAt = start.addingTimeInterval(1100)
        local.clips[c].startsAt = start.addingTimeInterval(50)
        local.clips[c].endsAt = start.addingTimeInterval(150)
        remote.clips[b].startsAt = start.addingTimeInterval(1050)
        remote.clips[b].endsAt = start.addingTimeInterval(1150)
        let initial = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote)
        XCTAssertEqual(initial.conflicts.count, 1)
        let conflict = try XCTUnwrap(initial.conflicts.first)
        for clip in base.clips { XCTAssertTrue(conflict.id.contains(clip.id.uuidString)) }
        for choice in [MetadataConflictChoice.local, .server] {
            let resolved = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote, choices: [conflict.id: choice]).resolved()
            XCTAssertEqual(resolved, choice == .local ? local : remote)
        }
    }
}

extension SharedMetadataCalendarTests {
    func testRowDatesAreCanonicalButOrderWithinEachDayRemainsEditable() throws {
        var automation = fixture()
        let p = automation.photographers[0].id
        let second = PhotographerProfile(name: "Another photographer", filenamePrefix: "AN", creator: "Another", copyrightNotice: "Example")
        automation.photographers.append(second)
        let day = PhotographerWorkDate(automation.clips[0].startsAt)
        let next = PhotographerWorkDate(automation.clips[0].startsAt.addingTimeInterval(86_400))
        let early = MetadataPhotographerTrack(photographerID: p, date: day)
        let late = MetadataPhotographerTrack(photographerID: p, date: next)
        let another = MetadataPhotographerTrack(photographerID: second.id, date: day)
        automation.photographerTracks = [late, another, early]
        let document = SharedMetadataDocument(automation)
        XCTAssertEqual(document.photographerTracks, [another, early, late])
        var wire = document
        wire.photographerTracks = [late, another, early]
        let result = try MetadataCalendarMerge.plan(base: wire, local: document, remote: wire, readOnly: true)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(try result.resolved(), document)
    }
}


private actor CalendarDebounceGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var startedCount = 0
    private(set) var completedCount = 0
    var waitingCount: Int { continuations.count }
    var allReturned: Bool { completedCount == startedCount }

    func wait() async {
        startedCount += 1
        if !released { await withCheckedContinuation { continuations.append($0) } }
        completedCount += 1
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
