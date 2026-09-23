import Foundation
import MetadataTemplates
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

private actor NamespaceCalendarServer {
    var calendar: SharedMetadataCalendar
    var requests: [MetadataCalendarRequest] = []
    var wireRequests: [URLRequest] = []
    var offline = false
    var wrongNamespace = false
    init(_ calendar: SharedMetadataCalendar) { self.calendar = calendar }
    func replaceRemote(_ document: SharedMetadataDocument) { calendar.document = document; calendar.revision += 1 }
    func setOffline() { offline = true }
    func setWrongNamespace() { wrongNamespace = true }
    func captured() -> [MetadataCalendarRequest] { requests }
    func capturedWire() -> [URLRequest] { wireRequests }
    func refuseCapabilities(_ request: URLRequest) throws -> (Data, Int) {
        wireRequests.append(request)
        return (try JSONSerialization.data(withJSONObject: ["service": "aagedal-metadata-sync", "protocolVersion": 3,
            "capabilities": [], "documentSchemaVersions": [1, 3], "templateLanguageVersions": [1]]), 200)
    }
    func send(_ body: MetadataCalendarRequest) throws -> MetadataCalendarResponse {
        requests.append(body)
        if offline { throw URLError(.notConnectedToInternet) }
        let version = wrongNamespace ? MetadataCalendarProtocol.legacy : body.routingProtocol
        if body.action == "listCalendars" {
            return .init(service: "aagedal-metadata-sync", protocolVersion: version.rawValue,
                calendars: [.init(id: calendar.id, name: calendar.name, timeZone: calendar.timeZone, role: calendar.role,
                    compatibility: version == .templates ? .templates : .legacy)],
                capabilities: version == .templates ? ["metadata-templates-v1"] : nil)
        }
        if body.action == "putCalendar", !wrongNamespace {
            guard body.expectedRevision == calendar.revision, let document = body.document else {
                return .init(service: "aagedal-metadata-sync", protocolVersion: version.rawValue,
                    error: "revision_conflict", calendar: calendar,
                    capabilities: version == .templates ? ["metadata-templates-v1"] : nil)
            }
            calendar.document = document
            calendar.revision += 1
        }
        var returned = calendar
        if wrongNamespace { returned.compatibility = .legacy }
        return .init(service: "aagedal-metadata-sync", protocolVersion: version.rawValue, calendar: returned,
            capabilities: version == .templates ? ["metadata-templates-v1"] : nil)
    }
}

@MainActor
final class MetadataCalendarNamespaceCoordinatorTests: XCTestCase {
    private struct Fixture {
        let store: AppStore
        let sync: MetadataCalendarCoordinator
        let repository: MetadataCalendarRepository
        let server: NamespaceCalendarServer
        let job: SyncJob
        let calendar: SharedMetadataCalendar
    }

    private func fixture(protocolVersion: MetadataCalendarProtocol = .templates,
                         activeBaseline: Bool = true, localHeadline: MetadataTemplateText? = nil,
                         revision: Int64 = 1, capabilityFailure: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root, storageFormat: .version3)
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "Literal")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Fixture",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_600),
            fields: .init(headline: "Literal {photographer}"))
        var job = SyncJob(name: "Namespace fixture", left: .init(kind: .local, localPath: root.appendingPathComponent("in").path, bookmark: Data([1])),
            right: .init(kind: .local, localPath: root.appendingPathComponent("out").path, bookmark: Data([2])), isEnabled: false,
            metadataAutomation: .init(photographers: [profile], photographerTracks: [], clips: [clip]))
        job.startsOnAppLaunch = false
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [storage.jobs.lastPathComponent: encoder.encode([job])])
        for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
        var baseline = try XCTUnwrap(job.metadataAutomation)
        if activeBaseline { baseline.clips[0].fields.setHeadline(try .activated("{photographer}")) }
        var local = baseline
        if let localHeadline { local.clips[0].fields.setHeadline(localHeadline) }
        job.metadataAutomation = local
        try JobRepository(storage: storage).save([job])
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: revision,
            role: "owner", document: SharedMetadataDocument(baseline), compatibility: protocolVersion == .templates ? .templates : .legacy)
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid/", registered: true)
        let repository = MetadataCalendarRepository(storage: storage)
        try repository.save(.init(accounts: [account], activeAccountID: account.id,
            bindings: [.init(accountID: account.id, jobID: job.id, snapshot: calendar)]))
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
            passwordWriter: { _, _ in XCTFail("Bound sync must not replace credentials") },
            passwordRemover: { _ in XCTFail("Bound sync must not remove credentials") })
        let store = try AppStore.makePausedForValidatedStorage(storage, retainedCredentialIDs: [],
            allowsCredentialGarbageCollection: false, keychain: keychain, launchAtLoginCoordinator: NamespaceLaunchStub())
        let server = NamespaceCalendarServer(calendar)
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain,
            transport: { body, address, id, key, setup in
                if capabilityFailure {
                    let client = MetadataCalendarClient(transport: { try await server.refuseCapabilities($0) })
                    return try await client.send(body, address: address, deviceID: id, key: key,
                        setupKey: setup, protocolVersion: body.routingProtocol)
                }
                return try await server.send(body)
            })
        sync.start(store: store, polling: false, observingChanges: false)
        addTeardownBlock { await MainActor.run { sync.stop() } }
        return .init(store: store, sync: sync, repository: repository, server: server, job: job, calendar: calendar)
    }

    func testCalendarAccessPanelsRouteByAccountAndKeepResultsIndependent() async throws {
        let f = try fixture()
        f.sync.stop()
        var state = try f.repository.load()
        let first = try XCTUnwrap(state.accounts.first)
        let second = MetadataSyncAccount(id: UUID(), address: "https://second.invalid/", registered: true)
        state.accounts.append(second)
        state.activeAccountID = second.id
        try f.repository.save(state)
        let otherCalendarID = UUID()
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
            passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let sync = MetadataCalendarCoordinator(repository: f.repository, keychain: keychain,
            transport: { body, address, accountID, _, _ in
                XCTAssertEqual(body.routingProtocol, .templates)
                XCTAssertEqual(address, accountID == first.id ? first.address : second.address)
                XCTAssertEqual(body.calendarID, accountID == first.id ? f.calendar.id : otherCalendarID)
                return .init(service: "aagedal-metadata-sync", protocolVersion: 3,
                    members: [.init(id: accountID, name: address, role: "owner")],
                    capabilities: ["metadata-templates-v1"])
            })
        sync.start(store: f.store, polling: false, observingChanges: false)
        defer { sync.stop() }
        let firstResult = try await sync.calendarAccessRequest(.init(action: "listMembers", calendarID: f.calendar.id),
            accountID: first.id, protocolVersion: .templates)
        let secondResult = try await sync.calendarAccessRequest(.init(action: "listMembers", calendarID: otherCalendarID),
            accountID: second.id, protocolVersion: .templates)
        XCTAssertEqual(firstResult.members?.first?.id, first.id)
        XCTAssertEqual(secondResult.members?.first?.id, second.id)
        XCTAssertTrue(sync.members.isEmpty, "Panel results must not overwrite global member state")
        XCTAssertFalse(sync.busy)
        XCTAssertEqual(sync.account?.id, second.id)
    }

    func testRemoveServerDetachesItsJobsAndPreservesOtherServersAndLocalMetadata() throws {
        let f = try fixture()
        f.sync.stop()
        var state = try f.repository.load()
        let removed = try XCTUnwrap(state.accounts.first)
        let other = MetadataSyncAccount(id: UUID(), address: "https://other.invalid/", registered: true, name: "Other")
        state.accounts.append(other)
        try f.repository.save(state)
        let originalJobs = f.store.jobs
        let keychain = KeychainStore(passwordReader: { _ in XCTFail("Removal must not read credentials"); return nil },
            passwordWriter: { _, _ in XCTFail("Removal must not replace credentials") },
            passwordRemover: { XCTAssertEqual($0, removed.credentialID) })
        let sync = MetadataCalendarCoordinator(repository: f.repository, keychain: keychain,
            transport: { _, _, _, _, _ in XCTFail("Removal must not contact a server"); throw URLError(.cancelled) })
        sync.start(store: f.store, polling: false, observingChanges: false)
        defer { sync.stop() }
        sync.removeAccount(removed.id)
        let reopened = try f.repository.load()
        XCTAssertEqual(reopened.accounts.map(\.id), [other.id])
        XCTAssertEqual(reopened.activeAccountID, other.id)
        XCTAssertTrue(reopened.bindings.isEmpty)
        XCTAssertEqual(f.store.jobs, originalJobs)
        XCTAssertEqual(sync.state.accounts.map(\.id), [other.id])
    }

    func testFailedServerRemovalPreservesBindingsAndCredentials() throws {
        let f = try fixture()
        f.sync.stop()
        let before = try Data(contentsOf: f.repository.url)
        let original = try f.repository.load()
        let repository = MetadataCalendarRepository(url: f.repository.url,
            storage: AppStorageLayout(root: f.repository.url.deletingLastPathComponent(), storageFormat: .version3),
            beforeSave: { throw MetadataSyncFailure(message: "Save refused") })
        let keychain = KeychainStore(passwordReader: { _ in nil }, passwordWriter: { _, _ in },
            passwordRemover: { _ in XCTFail("Keep the credential when persistence fails") })
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain)
        sync.start(store: f.store, polling: false, observingChanges: false)
        defer { sync.stop() }
        sync.removeAccount(try XCTUnwrap(original.accounts.first?.id))
        XCTAssertEqual(try Data(contentsOf: f.repository.url), before)
        XCTAssertEqual(sync.state.bindings, original.bindings)
        XCTAssertEqual(sync.state.accounts.map(\.id), original.accounts.map(\.id))
        XCTAssertTrue(sync.message.contains("Save refused"))
    }

    func testNamedServerRegistrationDoesNotAttachJobsAndRenamePreservesIdentity() async throws {
        let f = try fixture()
        f.sync.stop()
        var original = try f.repository.load()
        original.bindings = []
        try f.repository.save(original)
        let originalJobs = f.store.jobs
        let account = try XCTUnwrap(original.accounts.first)
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
            passwordWriter: { _, _ in XCTFail("Reuse existing credentials") },
            passwordRemover: { _ in XCTFail("Preserve existing credentials") })
        let sync = MetadataCalendarCoordinator(repository: f.repository, keychain: keychain,
            transport: { body, _, _, _, _ in
                if body.action == "acceptInvite" {
                    return .init(service: "aagedal-metadata-sync", protocolVersion: 3,
                        capabilities: ["metadata-templates-v1"])
                }
                return try await f.server.send(body)
            })
        sync.start(store: f.store, polling: false, observingChanges: false)
        defer { sync.stop() }
        let invitation = MetadataSyncInvitation.copyText(token: String(repeating: "b", count: 64),
            address: account.address, protocolVersion: .templates)
        sync.register(address: "", deviceName: "Mac", setupKey: nil, invite: invitation,
            protocolVersion: .templates, serverName: "  Newsroom  ")
        var deadline = Date().addingTimeInterval(5)
        while sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(sync.busy)
        XCTAssertEqual(sync.state.accounts.count, 1)
        XCTAssertEqual(sync.account?.displayName, "Newsroom")
        XCTAssertTrue(sync.state.bindings.isEmpty)
        XCTAssertNil(sync.receiveProposal)
        XCTAssertEqual(f.store.jobs, originalJobs)
        XCTAssertEqual(sync.suggestedCalendarID, f.calendar.id)
        sync.selectProtocol(.templates)
        XCTAssertEqual(sync.suggestedCalendarID, f.calendar.id,
            "Reopening job settings must not discard the calendar selected by the invitation")
        sync.renameAccount(account.id, name: "Sports desk")
        deadline = Date().addingTimeInterval(5)
        while sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let reopened = try f.repository.load()
        XCTAssertEqual(reopened.accounts.first?.displayName, "Sports desk")
        XCTAssertEqual(reopened.accounts.first?.credentialID, account.credentialID)
        XCTAssertEqual(reopened.accounts.first?.address, account.address)
        XCTAssertTrue(reopened.bindings.isEmpty)
    }

    func testJoinStringConnectsSelectedJobUsingTemplatesAndReviewsExistingProgramming() async throws {
        for hasProgramming in [false, true] {
            let f = try fixture()
            f.sync.stop()
            var state = try f.repository.load()
            state.bindings = []
            try f.repository.save(state)
            if !hasProgramming {
                XCTAssertTrue(f.store.saveMetadataAutomation(MetadataAutomation(), for: f.job.id))
            }
            let before = f.store.jobs.first?.metadataAutomation
            let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
                passwordWriter: { _, _ in XCTFail("Reuse this server's saved identity") }, passwordRemover: { _ in })
            let sync = MetadataCalendarCoordinator(repository: f.repository, keychain: keychain,
                transport: { body, _, _, _, _ in
                    if body.action == "acceptInvite" {
                        XCTAssertEqual(body.routingProtocol, .templates)
                        return .init(service: "aagedal-metadata-sync", protocolVersion: 3,
                            capabilities: ["metadata-templates-v1"])
                    }
                    return try await f.server.send(body)
                })
            sync.start(store: f.store, polling: false, observingChanges: false)
            defer { sync.stop() }
            let joinString = MetadataSyncInvitation.copyText(token: String(repeating: "b", count: 64),
                address: "https://fixture.invalid/", protocolVersion: .templates)
            sync.register(address: "", deviceName: "Joining Mac", setupKey: nil, invite: joinString,
                protocolVersion: .templates, connectingJobID: f.job.id)
            let deadline = Date().addingTimeInterval(5)
            while sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(sync.busy)
            if hasProgramming {
                XCTAssertEqual(sync.receiveProposal?.source.id, f.job.id, sync.message)
                XCTAssertEqual(f.store.jobs.first?.metadataAutomation, before)
                XCTAssertNil(sync.binding(for: f.job.id))
            } else {
                XCTAssertEqual(sync.binding(for: f.job.id)?.snapshot.id, f.calendar.id, sync.message)
                XCTAssertEqual(sync.binding(for: f.job.id)?.snapshot.compatibility, .templates)
                XCTAssertNil(sync.receiveProposal)
            }
        }
    }

    func testActivatedConflictResolvesAndPersistsWithoutLosingMarkers() async throws {
        let f = try fixture(localHeadline: .activated("Local {photographer}"))
        var remote = f.calendar.document
        remote.clips[0].fields.setHeadline(try .activated("Remote {photographer}"))
        remote.clips[0].fields.description = "Independent remote edit"
        await f.server.replaceRemote(remote)
        await f.sync.refresh(jobID: f.job.id)
        let binding = try XCTUnwrap(f.sync.binding(for: f.job.id))
        XCTAssertNotNil(binding.conflict)
        let review = try f.sync.conflictReview(binding)
        let plan = try review.plan()
        XCTAssertEqual(plan.conflicts.count, 1)
        f.sync.resolve(review, choices: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .local) }))
        let deadline = Date().addingTimeInterval(5)
        while f.sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(f.sync.busy)
        XCTAssertEqual(f.sync.activity(for: f.job.id).phase, .current, f.sync.message)
        let saved = try XCTUnwrap(f.repository.load().bindings.first)
        XCTAssertNil(saved.conflict)
        XCTAssertEqual(saved.snapshot.document.clips[0].fields.headline, "Local {photographer}")
        XCTAssertEqual(saved.snapshot.document.clips[0].fields.templateVersions["headline"], 1)
        XCTAssertEqual(saved.snapshot.document.clips[0].fields.description, "Independent remote edit")
        let requests = await f.server.captured()
        XCTAssertTrue(requests.contains { $0.action == "putCalendar" && $0.routingProtocol == .templates })
        // A fresh coordinator can reopen the persisted result and sync without another write.
        f.sync.stop()
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
            passwordWriter: { _, _ in }, passwordRemover: { _ in })
        let restarted = MetadataCalendarCoordinator(repository: f.repository, keychain: keychain,
            transport: { body, _, _, _, _ in try await f.server.send(body) })
        restarted.start(store: f.store, polling: false, observingChanges: false)
        defer { restarted.stop() }
        await restarted.refresh(jobID: f.job.id)
        XCTAssertEqual(restarted.activity(for: f.job.id).phase, .current)
        let after = await f.server.captured()
        XCTAssertEqual(after.filter { $0.action == "putCalendar" }.count, 1)
    }

    func testServerChangeDuringConflictReviewKeepsLocalEditAndRefreshesConflict() async throws {
        let f = try fixture(localHeadline: .activated("Local {photographer}"))
        var remote = f.calendar.document
        remote.clips[0].fields.setHeadline(try .activated("Remote {photographer}"))
        await f.server.replaceRemote(remote)
        await f.sync.refresh(jobID: f.job.id)
        let binding = try XCTUnwrap(f.sync.binding(for: f.job.id))
        let review = try f.sync.conflictReview(binding)
        let choices = Dictionary(uniqueKeysWithValues: try review.plan().conflicts.map { ($0.id, MetadataConflictChoice.local) })
        XCTAssertFalse(choices.isEmpty)

        remote.clips[0].fields.description = "New server edit"
        await f.server.replaceRemote(remote)
        f.sync.resolve(review, choices: choices)
        let deadline = Date().addingTimeInterval(5)
        while f.sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertFalse(f.sync.busy)
        XCTAssertEqual(f.sync.activity(for: f.job.id).phase, .conflict)
        XCTAssertTrue(f.sync.message.contains("server changed again"), f.sync.message)
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation?.clips.first?.fields.headline, "Local {photographer}")
        let saved = try XCTUnwrap(f.repository.load().bindings.first)
        XCTAssertEqual(saved.snapshot, f.calendar)
        XCTAssertEqual(saved.conflict?.revision, f.calendar.revision + 2)
        XCTAssertEqual(saved.conflict?.document.clips.first?.fields.description, "New server edit")
        let requests = await f.server.captured()
        XCTAssertEqual(requests.map(\.action), ["getCalendar", "getCalendar"])
    }

    func testOfflineTemplateBindingRetainsActiveLocalEditAndBaseline() async throws {
        let f = try fixture(localHeadline: .activated("Saved {gps:city}"))
        await f.server.setOffline()
        let bytes = try Data(contentsOf: f.repository.url)
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.captured()
        XCTAssertEqual(requests.map(\.routingProtocol), [.templates])
        XCTAssertEqual(requests.map(\.action), ["getCalendar"])
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation?.clips.first?.fields.headline, "Saved {gps:city}")
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation?.clips.first?.fields.templateVersions["headline"], 1)
        XCTAssertEqual(try f.repository.load().bindings.first?.snapshot, f.calendar)
        XCTAssertEqual(try Data(contentsOf: f.repository.url), bytes)
    }

    func testWrongNamespaceResponseNeverAppliesOrPublishesLocalChanges() async throws {
        let f = try fixture(localHeadline: .activated("Local {photographer}"))
        await f.server.setWrongNamespace()
        let original = try Data(contentsOf: f.repository.url)
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.captured()
        XCTAssertEqual(requests.map(\.action), ["getCalendar"])
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation?.clips.first?.fields.headline, "Local {photographer}")
        XCTAssertEqual(try Data(contentsOf: f.repository.url), original)
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility, .templates)
    }

    func testExplicitDeactivationSendsExactDeclarationAndKeepsTemplateNamespace() async throws {
        let f = try fixture(localHeadline: .literal("Literal {photographer}"))
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.captured()
        let put = try XCTUnwrap(requests.first { $0.action == "putCalendar" })
        XCTAssertEqual(put.routingProtocol, .templates)
        XCTAssertEqual(put.documentSchemaVersion, 3)
        XCTAssertEqual(put.expectedRevision, 1)
        XCTAssertEqual(put.templateDeactivations, [try .init(recordKind: .clip,
            recordID: f.calendar.document.clips[0].id, field: .headline)])
        XCTAssertTrue(try XCTUnwrap(put.document?.clips.first).fields.templateVersions.isEmpty)
        let saved = try XCTUnwrap(f.repository.load().bindings.first)
        XCTAssertEqual(saved.snapshot.compatibility, .templates)
        XCTAssertEqual(saved.snapshot.revision, 2)
        XCTAssertEqual(saved.snapshot.document.clips.first?.fields.headline, "Literal {photographer}")
    }

    func testCapabilityRefusalBeforeCreateRetainsPendingLocalBindingWithoutSendingSource() async throws {
        let f = try fixture(revision: 0, capabilityFailure: true)
        let original = try Data(contentsOf: f.repository.url)
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.capturedWire()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "getCapabilities")
        XCTAssertNil(body["document"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Aagedal-Protocol"), "3")
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation, f.job.metadataAutomation)
        XCTAssertEqual(try Data(contentsOf: f.repository.url), original)
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.revision, 0)
    }

    func testDiscoverySelectionDoesNotChangeExistingBindingNamespace() async throws {
        let f = try fixture()
        XCTAssertEqual(f.sync.discoveryProtocol, .templates)
        f.sync.selectProtocol(.legacy)
        await f.sync.refresh()
        let selectionDeadline = Date().addingTimeInterval(5)
        while f.sync.busy && Date() < selectionDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.sync.discoveryProtocol, .legacy)
        XCTAssertEqual(f.sync.calendars.first?.compatibility, .legacy)
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility, .templates)
        f.sync.selectProtocol(.templates)
        let deadline = Date().addingTimeInterval(5)
        while f.sync.calendars.first?.compatibility != .templates, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(f.sync.calendars.first?.compatibility, .templates)
        let requests = await f.server.captured()
        XCTAssertTrue(requests.contains { $0.action == "listCalendars" && $0.routingProtocol == .legacy })
        XCTAssertTrue(requests.contains { $0.action == "listCalendars" && $0.routingProtocol == .templates })
        XCTAssertTrue(requests.filter { $0.action == "getCalendar" }.allSatisfy { $0.routingProtocol == .templates })
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility, .templates)
    }

    func testLiteralTemplateCalendarNeverDowngradesWhileLegacyBindingStaysProtocol2() async throws {
        for protocolVersion in [MetadataCalendarProtocol.legacy, .templates] {
            let f = try fixture(protocolVersion: protocolVersion, activeBaseline: false, localHeadline: .literal("Changed literal"))
            await f.sync.refresh(jobID: f.job.id)
            let requests = await f.server.captured()
            XCTAssertEqual(requests.map(\.action), ["getCalendar", "putCalendar"])
            XCTAssertTrue(requests.allSatisfy { $0.routingProtocol == protocolVersion })
            XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility.protocolVersion, protocolVersion)
            if protocolVersion == .legacy {
                XCTAssertNil(requests.last?.capabilities)
                XCTAssertNil(requests.last?.documentSchemaVersion)
                XCTAssertNil(requests.last?.templateDeactivations)
            }
        }
    }
}

@MainActor
private final class NamespaceLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws { XCTFail("Fixture must not change launch at login") }
    func openSettings() { XCTFail("Fixture must not open system settings") }
}
