import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataCalendarNamespaceStorageTests: XCTestCase {
    private struct Fixture {
        let repository: MetadataCalendarRepository
        let state: MetadataCalendarState
        let layout: AppStorageLayout
    }
    private enum Failure: Error { case injected }

    private func document(active: Bool) throws -> SharedMetadataDocument {
        var profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Creator", copyrightNotice: "Literal {braces}")
        var fields = ScheduledMetadataFields(headline: "Literal {gps:city}", description: "Unmatched {", keywords: [" one ", "one"])
        if active {
            profile.setCopyright(try .activated("{gps:country}"))
            fields.setHeadline(try .activated("{gps:city}"))
            fields.setKeywords(try .activated(["  {gps:city}  ", "one", "one"]))
        }
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Clip", startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: Date(timeIntervalSince1970: 1_800_000_600), fields: fields)
        return SharedMetadataDocument(.init(photographers: [profile], photographerTracks: [], clips: [clip]))
    }

    private func fixture(format: AppStorageFormat = .version3) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: format)
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid/calendar/", registered: true)
        let snapshot = SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: 7, role: "owner", document: try document(active: false))
        let state = MetadataCalendarState(accounts: [account], activeAccountID: account.id,
            bindings: [.init(accountID: account.id, jobID: UUID(), snapshot: snapshot)])
        let repository = MetadataCalendarRepository(storage: layout)
        try VersionedStoreCodec(format: format, store: .metadataCalendar).encode(state, encoder: MetadataCalendarClient.encoder()).write(to: repository.url)
        return .init(repository: repository, state: state, layout: layout)
    }

    private func assertUnchanged(_ f: Fixture, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try Data(contentsOf: f.repository.url)
        XCTAssertThrowsError(try operation(), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: f.repository.url), bytes, file: file, line: line)
    }

    func testV3StoresPreserveActiveBindingsConflictsAndReceiveCopiesWhileLegacyRefuses() throws {
        for format in [AppStorageFormat.version3, .legacy] {
            let f = try fixture(format: format)
            var state = f.state
            var calendar = state.bindings[0].snapshot
            calendar.id = UUID(); calendar.compatibility = .templates; calendar.document = try document(active: true)
            state.bindings[0].snapshot = calendar
            var conflict = calendar; conflict.revision += 1
            state.bindings[0].conflict = conflict
            var source = SyncJob(name: "Source"); source.metadataAutomation = calendar.document.automation
            var duplicate = source; duplicate.id = UUID()
            state.pendingReceive = .init(accountID: state.accounts[0].id, source: source, duplicate: duplicate, calendar: calendar)
            if format == .legacy { try assertUnchanged(f) { try f.repository.save(state) }; continue }
            try f.repository.save(state)
            let loaded = try f.repository.load()
            XCTAssertEqual(loaded.bindings, state.bindings)
            XCTAssertEqual(loaded.pendingReceive?.calendar, calendar)
            XCTAssertEqual(loaded.pendingReceive?.source.metadataAutomation, source.metadataAutomation)
            XCTAssertEqual(loaded.pendingReceive?.duplicate.metadataAutomation, duplicate.metadataAutomation)
            XCTAssertEqual(loaded.bindings[0].snapshot.document.clips[0].fields.keywords, ["  {gps:city}  ", "one", "one"])
            // Protocol 2 still refuses active sources inside the v3 local store.
            state.bindings[0].snapshot.compatibility = .legacy
            try assertUnchanged(f) { try f.repository.save(state) }
        }
    }

    func testRemoteIdentityCannotChangeNamespaceIncludingLiteralSnapshotsAndProposals() throws {
        let f = try fixture()
        var state = f.state
        state.bindings[0].snapshot.compatibility = .templates
        try assertUnchanged(f) { try f.repository.save(state) }
        state.bindings[0].snapshot.id = UUID()
        try f.repository.save(state)
        var downgraded = state; downgraded.bindings[0].snapshot.compatibility = .legacy
        try assertUnchanged(f) { try f.repository.save(downgraded) }
        var source = SyncJob(name: "Source"); source.metadataAutomation = state.bindings[0].snapshot.document.automation
        var duplicate = source; duplicate.id = UUID()
        var proposalOnly = state; proposalOnly.bindings = []
        proposalOnly.pendingReceive = .init(accountID: state.accounts[0].id, source: source, duplicate: duplicate, calendar: downgraded.bindings[0].snapshot)
        try assertUnchanged(f) { try f.repository.save(proposalOnly) }
    }

    func testConflictsRequireMatchingIdentityNamespaceZoneScopeAndNondecreasingRevision() throws {
        let f = try fixture()
        var state = f.state
        state.bindings[0].snapshot.id = UUID(); state.bindings[0].snapshot.compatibility = .templates
        try f.repository.save(state)
        for side in 0..<5 {
            var candidate = state, conflict = state.bindings[0].snapshot
            switch side {
            case 0: conflict.id = UUID()
            case 1: conflict.compatibility = .legacy
            case 2: conflict.timeZone = "Europe/Oslo"
            case 3: conflict.rangeStart = Date(timeIntervalSince1970: 1_800_000_000); conflict.rangeEnd = Date(timeIntervalSince1970: 1_800_000_600)
            default: conflict.revision -= 1
            }
            candidate.bindings[0].conflict = conflict
            try assertUnchanged(f) { try f.repository.save(candidate) }
        }
    }

    func testDirectCreateIntentPersistsOnlyRevisionZeroOwnerWithoutRemoteScope() throws {
        let f = try fixture()
        var state = f.state
        state.bindings[0].snapshot.id = UUID(); state.bindings[0].snapshot.compatibility = .templates
        state.bindings[0].snapshot.revision = 0; state.bindings[0].snapshot.document = try document(active: true)
        try f.repository.save(state)
        XCTAssertEqual(try f.repository.load().bindings[0].snapshot.revision, 0)
        for side in 0..<3 {
            var invalid = state
            switch side {
            case 0: invalid.bindings[0].snapshot.role = "reader"
            case 1: invalid.bindings[0].snapshot.revision = -1
            default:
                invalid.bindings[0].snapshot.rangeStart = Date(timeIntervalSince1970: 1_800_000_000)
                invalid.bindings[0].snapshot.rangeEnd = Date(timeIntervalSince1970: 1_800_000_600)
            }
            try assertUnchanged(f) { try f.repository.save(invalid) }
        }
    }

    func testConfirmedMigrationRebindIsAtomicAndOrdinarySavesCannotAdvanceReceipt() throws {
        let f = try fixture()
        let prepared = try MetadataCalendarMigrationJournal(source: f.state.bindings[0], destinationID: UUID(), serverAddress: f.state.accounts[0].address)
        var pending = f.state; pending.pendingMigrations = [prepared]
        try f.repository.save(pending, replacingMigrations: [])
        let confirmed = try prepared.confirmCreated(prepared.proposedSnapshot)
        pending.pendingMigrations = [confirmed]
        try f.repository.save(pending, replacingMigrations: [prepared])
        var rebound = pending; rebound.bindings[0].snapshot = prepared.proposedSnapshot
        let committed = try confirmed.markBindingCommitted(rebound.bindings[0])
        rebound.pendingMigrations = [committed]
        try assertUnchanged(f) { try f.repository.save(rebound) }
        let failing = MetadataCalendarRepository(storage: f.layout, beforeSave: { throw Failure.injected })
        try assertUnchanged(f) { try failing.save(rebound, replacingMigrations: [confirmed]) }
        XCTAssertEqual(try f.repository.load().bindings, f.state.bindings)
        try f.repository.save(rebound, replacingMigrations: [confirmed])
        let loaded = try f.repository.load()
        XCTAssertEqual(loaded.bindings, rebound.bindings)
        XCTAssertEqual(loaded.pendingMigrations, [committed])
        XCTAssertEqual(loaded.pendingMigrations[0].source, f.state.bindings[0])
        try assertUnchanged(f) { try f.repository.save(pending, replacingMigrations: [committed]) }
    }

    func testCommittedBindingAdvancesWhileReceiptAndOriginalLiteralBaselineStayUnchanged() throws {
        let f = try fixture()
        let prepared = try MetadataCalendarMigrationJournal(source: f.state.bindings[0], destinationID: UUID(), serverAddress: f.state.accounts[0].address)
        var state = f.state; state.pendingMigrations = [prepared]
        try f.repository.save(state, replacingMigrations: [])
        let confirmed = try prepared.confirmCreated(prepared.proposedSnapshot)
        state.pendingMigrations = [confirmed]
        try f.repository.save(state, replacingMigrations: [prepared])
        state.bindings[0].snapshot = prepared.proposedSnapshot
        let committed = try confirmed.markBindingCommitted(state.bindings[0])
        state.pendingMigrations = [committed]
        try f.repository.save(state, replacingMigrations: [confirmed])
        state.bindings[0].snapshot.revision = 2
        state.bindings[0].snapshot.document = try document(active: true)
        try f.repository.save(state)
        let loaded = try f.repository.load()
        XCTAssertEqual(loaded.bindings[0].snapshot, state.bindings[0].snapshot)
        XCTAssertEqual(loaded.pendingMigrations, [committed])
        XCTAssertEqual(loaded.pendingMigrations[0].source.snapshot.document, f.state.bindings[0].snapshot.document)
        var stale = state; stale.bindings[0].snapshot = prepared.proposedSnapshot
        try assertUnchanged(f) { try f.repository.save(stale) }
        stale = state; stale.bindings[0].snapshot.document = prepared.proposedSnapshot.document
        try assertUnchanged(f) { try f.repository.save(stale) }
        for side in 0..<4 {
            var invalid = state
            switch side {
            case 0: invalid.pendingMigrations = []
            case 1: invalid.bindings[0].snapshot.compatibility = .legacy
            case 2: invalid.bindings[0].accountID = UUID()
            default: invalid.bindings[0].snapshot.id = UUID()
            }
            try assertUnchanged(f) { try f.repository.save(invalid) }
        }
    }

    func testMigrationCannotSkipConfirmationOrCommitDifferentInitialRevision() throws {
        let f = try fixture()
        let prepared = try MetadataCalendarMigrationJournal(source: f.state.bindings[0], destinationID: UUID(), serverAddress: f.state.accounts[0].address)
        var state = f.state; state.pendingMigrations = [prepared]
        try f.repository.save(state, replacingMigrations: [])
        let confirmed = try prepared.confirmCreated(prepared.proposedSnapshot)
        var rebound = state; rebound.bindings[0].snapshot = prepared.proposedSnapshot
        let committed = try confirmed.markBindingCommitted(rebound.bindings[0])
        rebound.pendingMigrations = [committed]
        try assertUnchanged(f) { try f.repository.save(rebound, replacingMigrations: [prepared]) }
        state.pendingMigrations = [confirmed]
        try f.repository.save(state, replacingMigrations: [prepared])
        rebound.bindings[0].snapshot.revision = 2
        try assertUnchanged(f) { try f.repository.save(rebound, replacingMigrations: [confirmed]) }
    }

    func testLocalSubmillisecondDatesArePreservedUntilSharedDocumentBoundary() throws {
        var local = try document(active: true).automation
        let localStart = Date(timeIntervalSince1970: 1_800_000_000.0004)
        let localEnd = Date(timeIntervalSince1970: 1_800_000_600.0004)
        local.clips[0].startsAt = localStart
        local.clips[0].endsAt = localEnd
        XCTAssertNoThrow(try MetadataCalendarNamespaceGate.validate(local, for: .templates))
        XCTAssertEqual(local.clips[0].startsAt, localStart)
        XCTAssertEqual(local.clips[0].endsAt, localEnd)

        let shared = SharedMetadataDocument(local)
        XCTAssertEqual(shared.clips[0].startsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(shared.clips[0].endsAt, Date(timeIntervalSince1970: 1_800_000_600))
        var snapshot = SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: 1,
            role: "owner", document: shared, compatibility: .templates)
        XCTAssertNoThrow(try MetadataCalendarNamespaceGate.validate(snapshot))
        snapshot.document.clips[0].startsAt = localStart
        XCTAssertThrowsError(try MetadataCalendarNamespaceGate.validate(snapshot), "Stored/wire snapshots still require canonical milliseconds")

        for invalidDate in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -.infinity),
                            Date(timeIntervalSince1970: -0.0004), Date(timeIntervalSince1970: 4_102_444_800.0004)] {
            var invalid = local; invalid.clips[0].startsAt = invalidDate
            XCTAssertThrowsError(try MetadataCalendarNamespaceGate.validate(invalid, for: .templates))
        }
    }
}
