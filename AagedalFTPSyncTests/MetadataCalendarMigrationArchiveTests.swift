import Foundation
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataCalendarMigrationArchiveTests: XCTestCase {
    private struct Fixture {
        let layout: AppStorageLayout
        let repository: MetadataCalendarRepository
        let original: MetadataCalendarState
        let prepared: MetadataCalendarMigrationJournal
    }
    private enum Failure: Error { case injected }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-archive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid/calendar/", registered: true)
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Creator", copyrightNotice: "Literal {unchanged}")
        let snapshot = SharedMetadataCalendar(id: UUID(), name: "Legacy", timeZone: "Etc/UTC", revision: 7, role: "owner",
            document: SharedMetadataDocument(.init(photographers: [profile], photographerTracks: [], clips: [])))
        let binding = MetadataCalendarBinding(accountID: account.id, jobID: UUID(), snapshot: snapshot)
        let original = MetadataCalendarState(accounts: [account], activeAccountID: account.id, bindings: [binding])
        let repository = MetadataCalendarRepository(storage: layout)
        try VersionedStoreCodec(format: .version3, store: .metadataCalendar)
            .encode(original, encoder: MetadataCalendarClient.encoder()).write(to: repository.url)
        let prepared = try MetadataCalendarMigrationJournal(source: binding, destinationID: UUID(), serverAddress: account.address)
        return .init(layout: layout, repository: repository, original: original, prepared: prepared)
    }

    private func committed(_ f: Fixture) throws -> MetadataCalendarState {
        var state = f.original; state.pendingMigrations = [f.prepared]
        try f.repository.save(state, replacingMigrations: [])
        let confirmed = try f.prepared.confirmCreated(f.prepared.proposedSnapshot)
        state.pendingMigrations = [confirmed]
        try f.repository.save(state, replacingMigrations: [f.prepared])
        state.bindings[0].snapshot = f.prepared.proposedSnapshot
        state.pendingMigrations = [try confirmed.markBindingCommitted(state.bindings[0])]
        try f.repository.save(state, replacingMigrations: [confirmed])
        return state
    }

    private func assertUnchanged(_ f: Fixture, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try Data(contentsOf: f.repository.url)
        XCTAssertThrowsError(try operation(), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: f.repository.url), bytes, file: file, line: line)
    }

    func testArchiveModelTransitionsAreMonotonicAndPreserveProvenance() throws {
        let f = try fixture(), prepared = f.prepared
        let confirmed = try prepared.confirmCreated(prepared.proposedSnapshot)
        var binding = prepared.source; binding.snapshot = prepared.proposedSnapshot
        let receipt = try confirmed.markBindingCommitted(binding)
        let detached = try receipt.markBindingDetached()
        let unconfirmedAbandonment = try prepared.abandon(), confirmedAbandonment = try confirmed.abandon()
        XCTAssertTrue(prepared.isPending); XCTAssertTrue(confirmed.isPending)
        XCTAssertFalse(receipt.isPending); XCTAssertFalse(receipt.isArchived)
        for archived in [detached, unconfirmedAbandonment, confirmedAbandonment] {
            XCTAssertTrue(archived.isArchived); XCTAssertFalse(archived.isPending)
            XCTAssertEqual(archived.source, prepared.source)
            XCTAssertEqual(archived.serverAddress, prepared.serverAddress)
            XCTAssertEqual(archived.destinationID, prepared.destinationID)
            XCTAssertEqual(archived.recoveryAction, .retainProvenance)
            let data = try MetadataCalendarClient.encoder().encode(archived)
            XCTAssertEqual(try MetadataCalendarClient.decoder().decode(MetadataCalendarMigrationJournal.self, from: data), archived)
            XCTAssertThrowsError(try archived.confirmCreated(prepared.proposedSnapshot))
            XCTAssertThrowsError(try archived.markBindingCommitted(binding))
        }
        XCTAssertEqual(detached.confirmedSnapshot, confirmed.confirmedSnapshot)
        XCTAssertNil(unconfirmedAbandonment.confirmedSnapshot)
        XCTAssertEqual(confirmedAbandonment.confirmedSnapshot, confirmed.confirmedSnapshot)
        XCTAssertEqual(try detached.markBindingDetached(), detached)
        XCTAssertEqual(try confirmedAbandonment.abandon(), confirmedAbandonment)
        XCTAssertThrowsError(try prepared.markBindingDetached())
        XCTAssertThrowsError(try confirmed.markBindingDetached())
        XCTAssertThrowsError(try receipt.abandon())
        XCTAssertThrowsError(try detached.abandon())
        XCTAssertThrowsError(try confirmedAbandonment.markBindingDetached())
    }

    func testDetachRequiresAtomicBindingRemovalAndExplicitReceiptTransition() throws {
        let f = try fixture(), live = try committed(f)
        let detached = try live.pendingMigrations[0].markBindingDetached()
        var withoutBinding = live; withoutBinding.bindings = []
        try assertUnchanged(f) { try f.repository.save(withoutBinding) }
        var withoutArchive = live; withoutArchive.pendingMigrations = [detached]
        try assertUnchanged(f) { try f.repository.save(withoutArchive, replacingMigrations: live.pendingMigrations) }
        var archived = withoutBinding; archived.pendingMigrations = [detached]
        try assertUnchanged(f) { try f.repository.save(archived) }
        let failing = MetadataCalendarRepository(storage: f.layout, beforeSave: { throw Failure.injected })
        try assertUnchanged(f) { try failing.save(archived, replacingMigrations: live.pendingMigrations) }
        XCTAssertEqual(try f.repository.load().bindings, live.bindings)
        try f.repository.save(archived, replacingMigrations: live.pendingMigrations)
        XCTAssertTrue(try f.repository.load().bindings.isEmpty)
        XCTAssertEqual(try f.repository.load().pendingMigrations, [detached])
    }

    func testDetachedArchiveAllowsAccountRemovalAndNewJobRejoinButBlocksStaleResurrection() throws {
        let f = try fixture(), live = try committed(f)
        var archived = live; archived.bindings = []
        archived.pendingMigrations = [try live.pendingMigrations[0].markBindingDetached()]
        try f.repository.save(archived, replacingMigrations: live.pendingMigrations)
        archived.accounts = []; archived.activeAccountID = nil
        try f.repository.save(archived)
        XCTAssertEqual(try f.repository.load().pendingMigrations, archived.pendingMigrations)
        try assertUnchanged(f) { try f.repository.save(live) }
        var resurrected = live; resurrected.pendingMigrations = archived.pendingMigrations
        try assertUnchanged(f) { try f.repository.save(resurrected) }
        try assertUnchanged(f) { try f.repository.save(live, replacingMigrations: archived.pendingMigrations) }
        var dropped = archived; dropped.pendingMigrations = []
        try assertUnchanged(f) { try f.repository.save(dropped, replacingMigrations: archived.pendingMigrations) }
        var rejoined = archived; rejoined.accounts = f.original.accounts
        var freshBinding = live.bindings[0]; freshBinding.jobID = UUID()
        rejoined.bindings = [freshBinding]
        try f.repository.save(rejoined)
        XCTAssertEqual(try f.repository.load().bindings, [freshBinding])
        XCTAssertEqual(try f.repository.load().pendingMigrations[0].source, f.prepared.source)
    }

    func testArchivedJobMayRelinkClassicAndStartAnotherMigrationWithFreshDestination() throws {
        let f = try fixture(), live = try committed(f)
        var archived = live; archived.bindings = []
        archived.pendingMigrations = [try live.pendingMigrations[0].markBindingDetached()]
        try f.repository.save(archived, replacingMigrations: live.pendingMigrations)
        archived.bindings = f.original.bindings
        try f.repository.save(archived)
        let next = try MetadataCalendarMigrationJournal(source: f.prepared.source, destinationID: UUID(), serverAddress: f.prepared.serverAddress)
        var nextState = archived; nextState.pendingMigrations.append(next)
        try f.repository.save(nextState, replacingMigrations: archived.pendingMigrations)
        XCTAssertEqual(try f.repository.load().pendingMigrations.count, 2)
        XCTAssertEqual(try f.repository.load().pendingMigrations.filter(\.isPending), [next])
        var collision = archived; collision.pendingMigrations.append(f.prepared)
        try assertUnchanged(f) { try f.repository.save(collision, replacingMigrations: nextState.pendingMigrations) }
    }

    func testAbandonmentRetainsClassicBindingAndOptionalConfirmationThenAllowsAccountRemoval() throws {
        for withConfirmation in [false, true] {
            let f = try fixture()
            var pending = f.original; pending.pendingMigrations = [f.prepared]
            try f.repository.save(pending, replacingMigrations: [])
            if withConfirmation {
                pending.pendingMigrations = [try f.prepared.confirmCreated(f.prepared.proposedSnapshot)]
                try f.repository.save(pending, replacingMigrations: [f.prepared])
            }
            let abandoned = try pending.pendingMigrations[0].abandon()
            var archived = pending; archived.pendingMigrations = [abandoned]
            try assertUnchanged(f) { try f.repository.save(archived) }
            var removedTooSoon = archived; removedTooSoon.bindings = []
            try assertUnchanged(f) { try f.repository.save(removedTooSoon, replacingMigrations: pending.pendingMigrations) }
            try f.repository.save(archived, replacingMigrations: pending.pendingMigrations)
            XCTAssertEqual(try f.repository.load().bindings, f.original.bindings)
            XCTAssertEqual(try f.repository.load().pendingMigrations[0].confirmedSnapshot != nil, withConfirmation)
            archived.bindings = []; archived.accounts = []; archived.activeAccountID = nil
            try f.repository.save(archived)
            XCTAssertEqual(try f.repository.load().pendingMigrations, [abandoned])
            try assertUnchanged(f) { try f.repository.save(pending, replacingMigrations: [abandoned]) }
        }
    }

    func testAbandonedTargetCanBeReceivedIntoNewJobButNeverOriginalJob() throws {
        let f = try fixture()
        var state = f.original; state.pendingMigrations = [f.prepared]
        try f.repository.save(state, replacingMigrations: [])
        state.pendingMigrations = [try f.prepared.abandon()]
        try f.repository.save(state, replacingMigrations: [f.prepared])
        var source = SyncJob(name: "Source"); source.id = f.prepared.source.jobID
        var duplicate = source; duplicate.id = UUID()
        state.pendingReceive = .init(accountID: f.prepared.source.accountID, source: source, duplicate: duplicate, calendar: f.prepared.proposedSnapshot)
        try f.repository.save(state)
        XCTAssertEqual(try f.repository.load().pendingReceive?.duplicate.id, duplicate.id)
        var invalid = state; invalid.pendingReceive?.duplicate.id = source.id
        try assertUnchanged(f) { try f.repository.save(invalid) }
        invalid = state; invalid.pendingReceive = nil
        invalid.bindings[0].snapshot = f.prepared.proposedSnapshot
        try assertUnchanged(f) { try f.repository.save(invalid) }
    }
}
