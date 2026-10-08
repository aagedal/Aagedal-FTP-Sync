import Foundation
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

private final class MigrationSaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?
    func arm(_ save: Int) { lock.lock(); defer { lock.unlock() }; remaining = save }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard let count = remaining else { return }
        remaining = count > 1 ? count - 1 : nil
        if count == 1 { throw CocoaError(.fileWriteUnknown) }
    }
}

private actor MigrationCoordinatorServer {
    var source: SharedMetadataCalendar
    var destination: SharedMetadataCalendar?
    var requests: [MetadataCalendarRequest] = []
    var denyCapabilities = false
    var loseCreateResponse = false
    var failCreateBeforeCommit = false
    var rejectDestinationAuthentication = false
    var preparedBeforeCreate = false
    var capabilityHook: (@Sendable () async -> Void)?
    let repositoryURL: URL
    init(source: SharedMetadataCalendar, repositoryURL: URL) {
        self.source = source; self.repositoryURL = repositoryURL
    }
    func deny() { denyCapabilities = true }
    func onNextCapabilities(_ hook: @escaping @Sendable () async -> Void) { capabilityHook = hook }
    func loseNextCreate() { loseCreateResponse = true }
    func failNextCreateBeforeCommit() { failCreateBeforeCommit = true }
    func rejectRecoveryAuthentication() { rejectDestinationAuthentication = true }
    func changeSource() { source.revision += 1 }
    func captured() -> [MetadataCalendarRequest] { requests }
    func original() -> SharedMetadataCalendar { source }
    func observedPrepared() -> Bool { preparedBeforeCreate }
    func send(_ request: MetadataCalendarRequest) async throws -> MetadataCalendarResponse {
        requests.append(request)
        if request.action == "getCapabilities" {
            if let hook = capabilityHook { capabilityHook = nil; await hook() }
            return .init(service: "aagedal-metadata-sync", protocolVersion: 3,
                capabilities: denyCapabilities ? [] : ["metadata-templates-v1"],
                documentSchemaVersions: [1, 3], templateLanguageVersions: [1])
        }
        if request.action == "getCalendar", request.routingProtocol == .legacy {
            guard request.calendarID == source.id else { throw URLError(.badServerResponse) }
            return .init(service: "aagedal-metadata-sync", protocolVersion: 2, calendar: source)
        }
        if request.action == "getCalendar", request.routingProtocol == .templates {
            if rejectDestinationAuthentication {
                throw MetadataSyncFailure(message: "Authentication failed", diagnosticCode: "HTTP 401: unauthorized")
            }
            if destination == nil {
                throw MetadataSyncFailure(message: "Calendar unavailable", diagnosticCode: "HTTP 403: access_denied")
            }
        }
        if request.action == "createCalendar", request.routingProtocol == .templates {
            if failCreateBeforeCommit { failCreateBeforeCommit = false; throw URLError(.networkConnectionLost) }
            let data = try Data(contentsOf: repositoryURL)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let payload = object?["payload"] as? [String: Any]
            let journals = payload?["pendingMigrations"] as? [[String: Any]]
            preparedBeforeCreate = journals?.contains {
                ($0["destinationID"] as? String)?.lowercased() == request.calendarID?.uuidString.lowercased()
                    && ($0["phase"] as? String) == "prepared"
            } == true
            guard let id = request.calendarID, let document = request.document,
                  let name = request.name, let zone = request.timeZone else { throw URLError(.badServerResponse) }
            destination = .init(id: id, name: name, timeZone: zone, revision: 1, role: "owner",
                document: document, compatibility: .templates)
            if loseCreateResponse { loseCreateResponse = false; throw URLError(.networkConnectionLost) }
        }
        guard request.routingProtocol == .templates, let destination,
              request.calendarID == destination.id else { throw URLError(.badServerResponse) }
        return .init(service: "aagedal-metadata-sync", protocolVersion: 3, calendar: destination,
            capabilities: ["metadata-templates-v1"])
    }
}

@MainActor
final class MetadataCalendarMigrationCoordinatorTests: XCTestCase {
    private struct Fixture {
        let store: AppStore
        let sync: MetadataCalendarCoordinator
        let repository: MetadataCalendarRepository
        let keychain: KeychainStore
        let server: MigrationCoordinatorServer
        let source: MetadataCalendarBinding
        let fault: MigrationSaveFault
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root, storageFormat: .version3)
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "Literal")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Fixture",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_600),
            fields: .init(headline: "Literal {photographer}"))
        var job = SyncJob(name: "Migration fixture", left: .init(kind: .local, localPath: root.appendingPathComponent("in").path, bookmark: Data([1])),
            right: .init(kind: .local, localPath: root.appendingPathComponent("out").path, bookmark: Data([2])), isEnabled: false,
            metadataAutomation: .init(photographers: [profile], photographerTracks: [], clips: [clip]))
        job.startsOnAppLaunch = false
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [storage.jobs.lastPathComponent: encoder.encode([job])])
        for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: 1,
            role: "owner", document: SharedMetadataDocument(try XCTUnwrap(job.metadataAutomation)))
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid/", registered: true)
        let source = MetadataCalendarBinding(accountID: account.id, jobID: job.id, snapshot: calendar)
        let fault = MigrationSaveFault()
        let repository = MetadataCalendarRepository(storage: storage, beforeSave: { try fault.check() })
        try repository.save(.init(accounts: [account], activeAccountID: account.id, bindings: [source]))
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
            passwordWriter: { _, _ in XCTFail("Migration must retain credentials") },
            passwordRemover: { _ in XCTFail("Migration must retain credentials") })
        let store = try AppStore.makePausedForValidatedStorage(storage, retainedCredentialIDs: [],
            allowsCredentialGarbageCollection: false, keychain: keychain, launchAtLoginCoordinator: MigrationLaunchStub())
        let server = MigrationCoordinatorServer(source: calendar, repositoryURL: repository.url)
        let sync = coordinator(repository: repository, keychain: keychain, store: store, server: server)
        return .init(store: store, sync: sync, repository: repository, keychain: keychain, server: server, source: source, fault: fault)
    }
    private func coordinator(repository: MetadataCalendarRepository, keychain: KeychainStore, store: AppStore,
                             server: MigrationCoordinatorServer) -> MetadataCalendarCoordinator {
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain,
            transport: { body, _, _, _, _ in try await server.send(body) })
        sync.start(store: store, polling: false, observingChanges: false)
        addTeardownBlock { await MainActor.run { sync.stop() } }
        return sync
    }
    private func finish(_ sync: MetadataCalendarCoordinator) async throws {
        let deadline = Date().addingTimeInterval(5)
        while sync.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(sync.busy, "Migration operation failed to finish")
    }
    private func prepare(_ f: Fixture) async throws -> MetadataCalendarMigrationJournal {
        f.sync.prepareMigration(f.source)
        try await finish(f.sync)
        return try XCTUnwrap(f.sync.migrationProposal)
    }

    func testPreparationRequiresSeparateConfirmationAndDoesNotPersistIntent() async throws {
        let f = try fixture()
        let original = try Data(contentsOf: f.repository.url)
        let journal = try await prepare(f)
        XCTAssertNotEqual(journal.destinationID, f.source.id)
        XCTAssertEqual(journal.source, f.source)
        XCTAssertEqual(try Data(contentsOf: f.repository.url), original)
        XCTAssertEqual(try f.repository.load().pendingMigrations, [])
        let requests = await f.server.captured()
        XCTAssertEqual(requests.map(\.action), ["getCapabilities", "getCalendar"])
        XCTAssertEqual(requests.map(\.routingProtocol), [.templates, .legacy])
        XCTAssertTrue(requests.allSatisfy { $0.document == nil })
    }

    func testConfirmationPersistsIntentBeforeCreateAndRebindsWithoutChangingLegacy() async throws {
        let f = try fixture()
        let journal = try await prepare(f)
        f.sync.confirmMigration(journal); try await finish(f.sync)
        let state = try f.repository.load()
        XCTAssertEqual(state.pendingMigrations.first?.phase, .bindingCommitted)
        XCTAssertEqual(state.bindings.first?.snapshot, journal.proposedSnapshot)
        XCTAssertEqual(state.bindings.first?.jobID, f.source.jobID)
        let prepared = await f.server.observedPrepared()
        XCTAssertTrue(prepared, "Durable prepared intent must precede document transmission")
        let source = await f.server.original()
        XCTAssertEqual(source, f.source.snapshot)
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation.map(SharedMetadataDocument.init), f.source.snapshot.document)
        let requests = await f.server.captured()
        XCTAssertEqual(requests.filter { $0.action == "createCalendar" }.count, 1)
        XCTAssertFalse(requests.contains { $0.action == "putCalendar" || $0.action == "deleteCalendar" })
    }

    func testLostCreateResponseRestartsByFetchingSameIdentityWithoutDuplicateCreate() async throws {
        let f = try fixture()
        let journal = try await prepare(f)
        await f.server.loseNextCreate()
        f.sync.confirmMigration(journal); try await finish(f.sync)
        XCTAssertEqual(try f.repository.load().pendingMigrations.first?.phase, .prepared)
        // After explicit durable confirmation, the new calendar is a frozen fork.
        await f.server.changeSource()
        f.sync.stop()
        let resumed = coordinator(repository: f.repository, keychain: f.keychain, store: f.store, server: f.server)
        resumed.retryMigration(journal.destinationID); try await finish(resumed)
        XCTAssertEqual(try f.repository.load().pendingMigrations.first?.phase, .bindingCommitted)
        XCTAssertEqual(try f.repository.load().bindings.first?.snapshot, journal.proposedSnapshot)
        let advancedSource = await f.server.original()
        XCTAssertEqual(advancedSource.revision, f.source.snapshot.revision + 1)
        let requests = await f.server.captured()
        XCTAssertEqual(requests.filter { $0.action == "createCalendar" }.map(\.calendarID), [journal.destinationID])
        XCTAssertTrue(requests.contains { $0.action == "getCalendar" && $0.routingProtocol == .templates && $0.calendarID == journal.destinationID })
    }

    func testCreateFailureBeforeCommitRetriesExactReservedIdentityAfterSpecificAccessDenied() async throws {
        let f = try fixture()
        let journal = try await prepare(f)
        await f.server.failNextCreateBeforeCommit()
        f.sync.confirmMigration(journal); try await finish(f.sync)
        XCTAssertEqual(try f.repository.load().pendingMigrations.first?.phase, .prepared)
        f.sync.retryMigration(journal.destinationID); try await finish(f.sync)
        let state = try f.repository.load()
        XCTAssertEqual(state.pendingMigrations.first?.phase, .bindingCommitted)
        XCTAssertEqual(state.bindings.first?.snapshot, journal.proposedSnapshot)
        let requests = await f.server.captured()
        XCTAssertEqual(requests.filter { $0.action == "createCalendar" }.map(\.calendarID),
                       [journal.destinationID, journal.destinationID])
        XCTAssertEqual(requests.filter { $0.action == "getCalendar" && $0.routingProtocol == .templates }.map(\.calendarID),
                       [journal.destinationID])
    }

    func testRecoveryAuthenticationAndCapabilityFailuresNeverFallThroughToCreate() async throws {
        for capabilityFailure in [false, true] {
            let f = try fixture()
            let journal = try await prepare(f)
            await f.server.failNextCreateBeforeCommit()
            f.sync.confirmMigration(journal); try await finish(f.sync)
            let before = try Data(contentsOf: f.repository.url)
            if capabilityFailure { await f.server.deny() }
            else { await f.server.rejectRecoveryAuthentication() }
            f.sync.retryMigration(journal.destinationID); try await finish(f.sync)
            XCTAssertEqual(try Data(contentsOf: f.repository.url), before)
            XCTAssertEqual(try f.repository.load().pendingMigrations.first?.phase, .prepared)
            let requests = await f.server.captured()
            XCTAssertEqual(requests.filter { $0.action == "createCalendar" }.count, 1)
            let destinationReads = requests.filter { $0.action == "getCalendar" && $0.routingProtocol == .templates }
            XCTAssertEqual(destinationReads.count, capabilityFailure ? 0 : 1)
        }
    }

    func testStaleProposalCannotOverwriteExternallySavedEndpointOrBinding() async throws {
        for changedEndpoint in [false, true] {
            let f = try fixture()
            let journal = try await prepare(f)
            var external = try f.repository.load()
            if changedEndpoint { external.accounts[0].address = "https://replacement.invalid/" }
            else { external.bindings[0].snapshot.revision += 1 }
            try f.repository.save(external)
            let saved = try Data(contentsOf: f.repository.url)
            f.sync.confirmMigration(journal); try await finish(f.sync)
            XCTAssertEqual(try Data(contentsOf: f.repository.url), saved)
            XCTAssertTrue(try f.repository.load().pendingMigrations.isEmpty)
            let requests = await f.server.captured()
            XCTAssertFalse(requests.contains { $0.action == "createCalendar" })
        }
    }

    func testPersistenceFailuresRetainEachRecoverablePhaseAndNeverDuplicateCreation() async throws {
        for save in 1...3 {
            let f = try fixture()
            let journal = try await prepare(f)
            f.fault.arm(save)
            f.sync.confirmMigration(journal); try await finish(f.sync)
            let state = try f.repository.load()
            XCTAssertEqual(state.bindings, [f.source])
            let requests = await f.server.captured()
            if save == 1 {
                XCTAssertTrue(state.pendingMigrations.isEmpty)
                XCTAssertFalse(requests.contains { $0.action == "createCalendar" })
            } else {
                XCTAssertEqual(state.pendingMigrations.first?.phase, save == 2 ? .prepared : .serverConfirmed)
                f.sync.retryMigration(journal.destinationID); try await finish(f.sync)
                XCTAssertEqual(try f.repository.load().pendingMigrations.first?.phase, .bindingCommitted)
                let after = await f.server.captured()
                XCTAssertEqual(after.filter { $0.action == "createCalendar" }.count, 1)
            }
        }
    }

    func testOpenDraftAndChangedLocalSourcePreventConfirmation() async throws {
        for draft in [true, false] {
            let f = try fixture()
            let journal = try await prepare(f)
            if draft { f.store.metadataDraftsBeingEdited.insert(f.source.jobID) }
            else {
                var automation = try XCTUnwrap(f.store.jobs.first?.metadataAutomation)
                automation.clips[0].fields.headline = "Unsynced edit"
                XCTAssertTrue(f.store.saveMetadataAutomation(automation, for: f.source.jobID))
            }
            f.sync.confirmMigration(journal); try await finish(f.sync)
            XCTAssertTrue(try f.repository.load().pendingMigrations.isEmpty)
            let requests = await f.server.captured()
            XCTAssertFalse(requests.contains { $0.action == "createCalendar" })
        }
    }

    func testLocalEditDuringCapabilityCheckPreventsCreateAndKeepsPreparedIntent() async throws {
        let f = try fixture()
        let journal = try await prepare(f)
        let store = f.store
        let jobID = f.source.jobID
        await f.server.onNextCapabilities {
            await MainActor.run { _ = store.metadataDraftsBeingEdited.insert(jobID) }
        }
        f.sync.confirmMigration(journal); try await finish(f.sync)
        XCTAssertEqual(try f.repository.load().pendingMigrations.first?.phase, .prepared)
        XCTAssertEqual(try f.repository.load().bindings, [f.source])
        let requests = await f.server.captured()
        XCTAssertFalse(requests.contains { $0.action == "createCalendar" })
        f.sync.retryMigration(journal.destinationID); try await finish(f.sync)
        XCTAssertEqual(try f.repository.load().pendingMigrations.first?.phase, .prepared)
    }

    func testAbandonAfterUncertainCreateRetainsSourceAndJournalWithoutNetwork() async throws {
        let f = try fixture()
        let journal = try await prepare(f)
        await f.server.loseNextCreate()
        f.sync.confirmMigration(journal); try await finish(f.sync)
        let before = await f.server.captured().count
        f.sync.cancelMigration(journal.destinationID); try await finish(f.sync)
        let state = try f.repository.load()
        XCTAssertEqual(state.pendingMigrations.first?.phase, .abandoned)
        XCTAssertEqual(state.pendingMigrations.first?.source, f.source)
        XCTAssertEqual(state.pendingMigrations.first?.destinationID, journal.destinationID)
        XCTAssertEqual(state.bindings, [f.source])
        let after = await f.server.captured().count
        XCTAssertEqual(after, before)
    }

    func testRemoteChangeDuringReviewRefusesBeforeIntentAndCapabilitiesRefusalSendsNoDocument() async throws {
        let f = try fixture()
        let journal = try await prepare(f)
        await f.server.changeSource()
        f.sync.confirmMigration(journal); try await finish(f.sync)
        XCTAssertTrue(try f.repository.load().pendingMigrations.isEmpty)
        let requests = await f.server.captured()
        XCTAssertFalse(requests.contains { $0.document != nil })
        let denied = try fixture()
        await denied.server.deny()
        denied.sync.prepareMigration(denied.source); try await finish(denied.sync)
        XCTAssertNil(denied.sync.migrationProposal)
        XCTAssertTrue(try denied.repository.load().pendingMigrations.isEmpty)
        let deniedRequests = await denied.server.captured()
        XCTAssertEqual(deniedRequests.map(\.action), ["getCapabilities"])
    }
}

@MainActor
private final class MigrationLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws { XCTFail("Fixture must not change launch at login") }
    func openSettings() { XCTFail("Fixture must not open settings") }
}
