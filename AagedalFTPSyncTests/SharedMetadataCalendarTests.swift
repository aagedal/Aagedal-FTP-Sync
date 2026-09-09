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
    init(calendar: SharedMetadataCalendar) { self.calendar = calendar }
    func loseNextResponse() { failAfterCommit = true }
    func send(_ body: MetadataCalendarRequest) throws -> MetadataCalendarResponse {
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
        sync.start(store: store, polling: false)
        return (root, store, sync, repository, calendar)
    }

    private func finishOperation(_ sync: MetadataCalendarCoordinator) async throws {
        let deadline = Date().addingTimeInterval(5)
        while sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(sync.busy, "The receive operation should finish")
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
            sync.start(store: store, polling: false)
            if let keepLocal {
                sync.resolve(binding, keepLocal: keepLocal)
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
        a.start(store: storeA, polling: false); b.start(store: storeB, polling: false)
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

        // A date-limited third device can edit its clip without seeing or replacing
        // the other dates on the same shared calendar.
        a.createInvite(calendarID: calendar.id, role: "editor", range: MetadataSharingRange(start: first.startsAt, end: first.endsAt))
        try await finishOperation(a)
        let jobC = SyncJob(name: "Limited receiving job")
        let storeC = try makeStore(root: root.appendingPathComponent("c"), job: jobC)
        let c = MetadataCalendarCoordinator(repository: MetadataCalendarRepository(url: root.appendingPathComponent("c/sync.json")), keychain: keychain, transport: transport)
        c.start(store: storeC, polling: false)
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
        restarted.start(store: store, polling: false)
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
        first.start(store: store, polling: false)
        await server.loseNextResponse()
        await first.refresh()
        XCTAssertEqual(try repository.load().bindings[0].snapshot.revision, 1)
        let second = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: transport)
        second.start(store: store, polling: false)
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
