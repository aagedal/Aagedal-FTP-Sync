import Foundation
import MetadataTemplates
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataCalendarActivationTests: XCTestCase {
    private func document() -> SharedMetadataDocument {
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "{gps:city}")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Clip", startsAt: start,
            endsAt: start.addingTimeInterval(600), fields: ScheduledMetadataFields(headline: "{gps:city}", description: "Base", keywords: ["one", "two"]))
        return SharedMetadataDocument(MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [clip]))
    }

    private func activate(_ original: SharedMetadataDocument) throws -> SharedMetadataDocument {
        var result = original
        result.photographers[0].setCopyright(try .activated("{gps:city}"))
        result.clips[0].fields.setHeadline(try .activated("{gps:city}"))
        result.clips[0].fields.setDescription(try .activated("Description {gps:city}"))
        result.clips[0].fields.setKeywords(try .activated(["  {gps:city}  ", "one", "one"]))
        return result
    }

    private func calendar(_ doc: SharedMetadataDocument) -> SharedMetadataCalendar {
        SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: 1, role: "owner", document: doc)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-activation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testDetachedSharedCopiesAndApplicationPreserveExactAtomicPairs() throws {
        let active = try activate(document())
        let copied = try SharedMetadataDocument(active.automation).validated()
        XCTAssertEqual(copied, active)
        XCTAssertEqual(copied.photographers[0].copyrightTemplateVersion, 1)
        XCTAssertEqual(copied.clips[0].fields.keywords, ["  {gps:city}  ", "one", "one"])
        let applied = try copied.applying(to: document().automation, replacing: document(), range: nil, timeZone: "Etc/UTC")
        XCTAssertEqual(SharedMetadataDocument(applied), active)
        let bytes = try MetadataCalendarClient.encoder().encode(copied)
        XCTAssertEqual(try MetadataCalendarClient.decoder().decode(SharedMetadataDocument.self, from: bytes), active)
    }

    func testActivationAndConcurrentSourceEditRemainExplicitConflicts() throws {
        let base = document()
        var local = base, remote = base
        local.photographers[0].setCopyright(try .activated(base.photographers[0].copyrightNotice))
        local.clips[0].fields.setHeadline(try .activated(base.clips[0].fields.headline))
        local.clips[0].fields.setKeywords(try .activated(base.clips[0].fields.keywords))
        remote.photographers[0].copyrightNotice = "Server copyright"
        remote.clips[0].fields.headline = "Server headline"
        remote.clips[0].fields.keywords = ["server", "ordered"]
        let plan = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote)
        XCTAssertEqual(plan.conflicts.count, 2, "Photographer and clip each collect their pair conflicts")
        XCTAssertThrowsError(try plan.resolved())
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, MetadataConflictChoice.server) })
        let selected = try MetadataCalendarMerge.plan(base: base, local: local, remote: remote, choices: choices).resolved()
        XCTAssertEqual(selected.photographers[0].copyrightNotice, "Server copyright")
        XCTAssertNil(selected.photographers[0].copyrightTemplateVersion)
        XCTAssertEqual(selected.clips[0].fields.headline, "Server headline")
        XCTAssertEqual(selected.clips[0].fields.keywords, ["server", "ordered"])
        XCTAssertTrue(selected.clips[0].fields.templateVersions.isEmpty)
    }

    func testIndependentFieldEditsKeepWholeActiveKeywordList() throws {
        let base = document()
        var local = base, remote = base
        local.clips[0].fields.setKeywords(try .activated(["  {gps:city}", "one", "one"]))
        remote.clips[0].fields.description = "Remote description"
        let merged = try SharedMetadataDocument.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.clips[0].fields.keywords, local.clips[0].fields.keywords)
        XCTAssertEqual(merged.clips[0].fields.templateVersions["keywords"], 1)
        XCTAssertEqual(merged.clips[0].fields.description, "Remote description")
    }

    func testProtocolTwoIncomingResponseAndOutboundRequestRejectActivation() async throws {
        let active = try activate(document())
        let calendar = calendar(active)
        let encoded = try MetadataCalendarClient.encoder().encode(calendar)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let bytes = try JSONSerialization.data(withJSONObject: ["service": "aagedal-metadata-sync", "protocolVersion": 2, "calendar": object])
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(bytes, statusCode: 200, calendarID: calendar.id))
        do {
            _ = try await MetadataCalendarClient().send(.init(action: "putCalendar", document: active),
                address: "not a server", deviceID: UUID(), key: "invalid")
            XCTFail("Active document must be rejected before key/address/network")
        } catch let error as MetadataSyncFailure {
            XCTAssertEqual(error.diagnosticCode, "template_protocol_required")
        }
        XCTAssertNoThrow(try LegacyMetadataCalendarGate.validate(document()))
    }

    func testStaleLiteralSaveCannotReplaceActiveVersionThreeCache() throws {
        let root = try root()
        let storage = AppStorageLayout(root: root, storageFormat: .version3)
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid", registered: true)
        let original = MetadataCalendarState(accounts: [account], activeAccountID: account.id)
        var unsupported = original
        unsupported.pendingReceive = MetadataCalendarReceiveProposal(accountID: account.id,
            source: SyncJob(name: "Source"), duplicate: SyncJob(name: "Duplicate"), calendar: calendar(try activate(document())))
        let codec = VersionedStoreCodec(format: .version3, store: .metadataCalendar)
        let bytes = try codec.encode(unsupported, encoder: MetadataCalendarClient.encoder())
        try bytes.write(to: storage.metadataCalendar)
        let repository = MetadataCalendarRepository(storage: storage)
        XCTAssertThrowsError(try repository.save(original))
        XCTAssertEqual(try Data(contentsOf: storage.metadataCalendar), bytes)
    }

    func testCacheAndBothReceiveReceiptSidesRejectActiveStateWithoutOverwritingBytes() throws {
        let root = try root()
        let repository = MetadataCalendarRepository(url: root.appendingPathComponent("calendar.json"))
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid", registered: true)
        var source = SyncJob(name: "Source"); source.metadataAutomation = document().automation
        var duplicate = source; duplicate.id = UUID()
        let literalCalendar = calendar(document())
        let original = MetadataCalendarState(accounts: [account], activeAccountID: account.id)
        try repository.save(original)
        let originalBytes = try Data(contentsOf: repository.url)
        for side in 0..<4 {
            var state = original
            var proposal = MetadataCalendarReceiveProposal(accountID: account.id, source: source, duplicate: duplicate, calendar: literalCalendar)
            if side == 0 { proposal.source.metadataAutomation = try activate(document()).automation }
            if side == 1 { proposal.duplicate.metadataAutomation = try activate(document()).automation }
            if side == 2 { proposal.calendar.document = try activate(document()) }
            if side < 3 { state.pendingReceive = proposal }
            else {
                var binding = MetadataCalendarBinding(accountID: account.id, jobID: source.id, snapshot: literalCalendar)
                binding.conflict = calendar(try activate(document()))
                state.bindings = [binding]
            }
            XCTAssertThrowsError(try repository.save(state))
            XCTAssertEqual(try Data(contentsOf: repository.url), originalBytes)
            // Simulate a cached file from an incompatible writer, bypassing repository save.
            try MetadataCalendarClient.encoder().encode(state).write(to: repository.url)
            XCTAssertThrowsError(try repository.load())
            try originalBytes.write(to: repository.url)
        }
    }

    func testLinkedActivationBlocksDiscoveryAndGetBeforeCredentialsOrTransport() async throws {
        let root = try root()
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        var job = SyncJob(name: "Linked"); job.metadataAutomation = document().automation
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [layout.jobs.lastPathComponent: encoder.encode([job])])
        for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
        let literalCalendar = calendar(SharedMetadataDocument(job.metadataAutomation!))
        job.metadataAutomation = try activate(SharedMetadataDocument(job.metadataAutomation!)).automation
        try JobRepository(storage: layout).save([job])
        let keychain = KeychainStore(passwordReader: { _ in XCTFail("Active linked calendar must not read credentials"); return nil },
            passwordWriter: { _, _ in XCTFail("No credentials should be written") }, passwordRemover: { _ in XCTFail("No credentials should be removed") })
        let store = try AppStore.makePausedForValidatedStorage(layout, retainedCredentialIDs: [], allowsCredentialGarbageCollection: false,
            keychain: keychain, launchAtLoginCoordinator: ActivationCalendarLaunchStub())
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid", registered: true)
        let repository = MetadataCalendarRepository(storage: layout)
        try repository.save(MetadataCalendarState(accounts: [account], activeAccountID: account.id,
            bindings: [.init(accountID: account.id, jobID: job.id, snapshot: literalCalendar)]))
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain, transport: { _, _, _, _, _ in
            XCTFail("Active linked calendar must not reach transport")
            throw URLError(.cancelled)
        })
        sync.start(store: store, polling: false, observingChanges: false)
        await sync.refresh()
        await sync.refresh(jobID: job.id)
        XCTAssertTrue(sync.message.contains("Activated metadata templates"))
        XCTAssertTrue(sync.bindingMessages[literalCalendar.id]?.contains("Activated metadata templates") == true)
        XCTAssertEqual(sync.state.bindings[0].snapshot, literalCalendar)
        XCTAssertEqual(store.jobs[0].metadataAutomation, job.metadataAutomation)
        sync.stop()
    }
}

@MainActor
private final class ActivationCalendarLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws {}
    func openSettings() {}
}
