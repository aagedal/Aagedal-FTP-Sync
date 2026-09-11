import Darwin
import Foundation
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataCalendarMigrationStorageTests: XCTestCase {
    private struct Fixture {
        let repository: MetadataCalendarRepository
        let original: MetadataCalendarState
        let journal: MetadataCalendarMigrationJournal
        var pending: MetadataCalendarState {
            var state = original
            state.pendingMigrations = [journal]
            return state
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-migration-storage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let account = MetadataSyncAccount(id: UUID(), address: "https://migration.invalid/calendars", registered: true)
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "Literal {braces}")
        let document = SharedMetadataDocument(MetadataAutomation(photographers: [profile], photographerTracks: [], clips: []))
        let snapshot = SharedMetadataCalendar(id: UUID(), name: "Legacy calendar", timeZone: "Etc/UTC", revision: 7, role: "owner", document: document)
        let binding = MetadataCalendarBinding(accountID: account.id, jobID: UUID(), snapshot: snapshot)
        let original = MetadataCalendarState(accounts: [account], activeAccountID: account.id, bindings: [binding])
        let journal = try MetadataCalendarMigrationJournal(source: binding, destinationID: UUID(), serverAddress: account.address)
        let repository = MetadataCalendarRepository(storage: layout)
        // Establish the selected v3 envelope before exercising repository saves.
        try VersionedStoreCodec(format: .version3, store: .metadataCalendar)
            .encode(original, encoder: MetadataCalendarClient.encoder()).write(to: repository.url)
        return Fixture(repository: repository, original: original, journal: journal)
    }

    private func assertRejectedWithoutMutation(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ action: () throws -> Void
    ) throws {
        let before = try Data(contentsOf: fixture.repository.url)
        XCTAssertThrowsError(try action(), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fixture.repository.url), before, file: file, line: line)
    }

    func testExplicitBeginAndConfirmSurviveReloadWhileOrdinarySavesPreserveJournal() throws {
        let f = try fixture()
        try assertRejectedWithoutMutation(f) { try f.repository.save(f.pending) }
        try f.repository.save(f.pending, replacingMigrations: [])
        let restarted = MetadataCalendarRepository(url: f.repository.url,
            storage: AppStorageLayout(root: f.repository.url.deletingLastPathComponent(), storageFormat: .version3))
        var loaded = try restarted.load()
        XCTAssertEqual(loaded.pendingMigrations, [f.journal])
        XCTAssertEqual(loaded.bindings, f.original.bindings)
        loaded.activeAccountID = nil // Ordinary UI selection can change without altering intent.
        try restarted.save(loaded)
        XCTAssertEqual(try restarted.load().pendingMigrations, [f.journal])
        let confirmed = try f.journal.confirmCreated(f.journal.proposedSnapshot)
        loaded.pendingMigrations = [confirmed]
        try assertRejectedWithoutMutation(f) { try restarted.save(loaded) }
        try restarted.save(loaded, replacingMigrations: [f.journal])
        XCTAssertEqual(try restarted.load().pendingMigrations, [confirmed])
        XCTAssertEqual(try restarted.load().bindings, f.original.bindings, "Confirmation is not a rebind")
    }

    func testStaleOrdinaryAndExplicitSavesCannotDropOrReplaceJournal() throws {
        let f = try fixture()
        try f.repository.save(f.pending, replacingMigrations: [])
        try assertRejectedWithoutMutation(f) { try f.repository.save(f.original) }
        try assertRejectedWithoutMutation(f) { try f.repository.save(f.original, replacingMigrations: []) }
        try assertRejectedWithoutMutation(f) { try f.repository.save(f.original, replacingMigrations: [f.journal]) }
        var replacement = f.original
        replacement.pendingMigrations = [try MetadataCalendarMigrationJournal(source: f.journal.source,
            destinationID: UUID(), serverAddress: f.journal.serverAddress)]
        try assertRejectedWithoutMutation(f) { try f.repository.save(replacement, replacingMigrations: [f.journal]) }
        XCTAssertEqual(try f.repository.load().pendingMigrations, [f.journal])
    }

    func testBeginCannotUseStaleSourceBindingOrEndpointFromBeforeAnotherSave() throws {
        for changesEndpoint in [false, true] {
            let f = try fixture()
            var latest = f.original
            if changesEndpoint { latest.accounts[0].address = "https://changed.invalid/calendars" }
            else { latest.bindings[0].snapshot.revision += 1 }
            try f.repository.save(latest)
            try assertRejectedWithoutMutation(f) {
                try f.repository.save(f.pending, replacingMigrations: [])
            }
            XCTAssertTrue(try f.repository.load().pendingMigrations.isEmpty)
            XCTAssertEqual(try f.repository.load().bindings, latest.bindings)
        }
    }

    func testPhaseCannotSkipBeginOrMoveBackwards() throws {
        let f = try fixture()
        let confirmed = try f.journal.confirmCreated(f.journal.proposedSnapshot)
        var state = f.original
        state.pendingMigrations = [confirmed]
        try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: []) }
        try f.repository.save(f.pending, replacingMigrations: [])
        try f.repository.save(state, replacingMigrations: [f.journal])
        try assertRejectedWithoutMutation(f) { try f.repository.save(f.pending, replacingMigrations: [confirmed]) }
        try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: [f.journal]) }
        XCTAssertEqual(try f.repository.load().pendingMigrations, [confirmed])
    }

    func testPendingIntentFreezesSourceBindingAndAccountEvenWithReplacementJournal() throws {
        let f = try fixture()
        try f.repository.save(f.pending, replacingMigrations: [])
        for mutation in 0..<4 {
            var state = f.pending
            switch mutation {
            case 0: state.bindings.removeAll()
            case 1: state.bindings[0].snapshot.revision += 1
            case 2: state.accounts.removeAll()
            default: state.accounts[0].address = "https://other.invalid/calendars"
            }
            try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: [f.journal]) }
        }
        var replaced = f.pending
        replaced.bindings[0].snapshot.revision += 1
        replaced.pendingMigrations = [try MetadataCalendarMigrationJournal(source: replaced.bindings[0],
            destinationID: f.journal.destinationID, serverAddress: f.journal.serverAddress)]
        try assertRejectedWithoutMutation(f) { try f.repository.save(replaced, replacingMigrations: [f.journal]) }
        replaced = f.pending
        replaced.accounts[0].address = "https://other.invalid/calendars"
        replaced.pendingMigrations = [try MetadataCalendarMigrationJournal(source: f.journal.source,
            destinationID: f.journal.destinationID, serverAddress: replaced.accounts[0].address)]
        try assertRejectedWithoutMutation(f) { try f.repository.save(replaced, replacingMigrations: [f.journal]) }
    }

    func testConfirmedReceiptDoesNotAdmitLiveV3BindingOrCommittedPhase() throws {
        let f = try fixture()
        let confirmed = try f.journal.confirmCreated(f.journal.proposedSnapshot)
        var state = f.pending
        try f.repository.save(state, replacingMigrations: [])
        state.pendingMigrations = [confirmed]
        try f.repository.save(state, replacingMigrations: [f.journal])
        var rebound = f.journal.source
        rebound.snapshot = f.journal.proposedSnapshot
        state.bindings = [rebound]
        state.pendingMigrations = [try confirmed.markBindingCommitted(rebound)]
        try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: [confirmed]) }
        state.pendingMigrations = []
        try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: [confirmed]) }
    }

    func testLegacyJournalPresenceIncludingEmptyOrNullRejectsBeforeMalformedSibling() throws {
        let f = try fixture()
        let legacyURL = f.repository.url.deletingLastPathComponent().appendingPathComponent("legacy-calendar.json")
        let legacy = MetadataCalendarRepository(url: legacyURL)
        let journal = try JSONSerialization.jsonObject(with: MetadataCalendarClient.encoder().encode(f.journal))
        let markers: [Any] = [[], NSNull(), [journal]]
        for marker in markers {
            let bytes = try JSONSerialization.data(withJSONObject: ["accounts": "malformed earlier sibling",
                "bindings": [], "pendingMigrations": marker], options: [.sortedKeys])
            try bytes.write(to: legacyURL)
            XCTAssertThrowsError(try legacy.load()) { error in
                XCTAssertEqual(error as? VersionedStoreCodec.HeaderError, .requiresVersion3Storage)
            }
            XCTAssertThrowsError(try legacy.save(f.original))
            XCTAssertEqual(try Data(contentsOf: legacyURL), bytes)
        }
        XCTAssertThrowsError(try legacy.save(f.pending, replacingMigrations: []))
    }

    func testMalformedEarlierSiblingCannotHideJournalFromStaleSaveRecovery() throws {
        let f = try fixture()
        let encoded = try VersionedStoreCodec(format: .version3, store: .metadataCalendar)
            .encode(f.pending, encoder: MetadataCalendarClient.encoder())
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let markers: [Any] = [try XCTUnwrap((valid["payload"] as? [String: Any])?["pendingMigrations"]), [], NSNull(), "invalid journal"]
        for marker in markers {
            var envelope = valid
            var payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
            payload["accounts"] = "malformed earlier sibling"
            payload["pendingMigrations"] = marker
            envelope["payload"] = payload
            let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            try bytes.write(to: f.repository.url)
            XCTAssertThrowsError(try f.repository.load())
            try assertRejectedWithoutMutation(f) { try f.repository.save(f.original) }
            try assertRejectedWithoutMutation(f) { try f.repository.save(f.original, replacingMigrations: []) }
        }
    }

    func testOrdinaryLegacyRoundTripPreservesKeyShapeAndCreatesNoMigrationLock() throws {
        let f = try fixture()
        let url = f.repository.url.deletingLastPathComponent().appendingPathComponent("ordinary-legacy.json")
        let legacy = MetadataCalendarRepository(url: url)
        let original = try MetadataCalendarClient.encoder().encode(f.original)
        try original.write(to: url)
        try legacy.save(legacy.load())
        let saved = try Data(contentsOf: url)
        let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? NSDictionary)
        XCTAssertEqual(savedObject, originalObject)
        XCTAssertEqual(Set(savedObject.allKeys.compactMap { $0 as? String }),
            ["accounts", "activeAccountID", "bindings"])
        XCTAssertNil(savedObject["pendingMigrations"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".migration-lock"))
        XCTAssertEqual(try legacy.load().bindings, f.original.bindings)
    }

    func testDuplicateDestinationOrSourceJobCannotEnterJournalState() throws {
        let f = try fixture()
        var state = f.pending
        state.pendingMigrations.append(f.journal)
        try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: []) }
        // Different destinations still cannot claim the same source job.
        state.pendingMigrations = [f.journal, try MetadataCalendarMigrationJournal(source: f.journal.source,
            destinationID: UUID(), serverAddress: f.journal.serverAddress)]
        try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: []) }
        // Distinct source jobs cannot reserve the same destination either.
        var secondBinding = f.journal.source
        secondBinding.jobID = UUID()
        secondBinding.snapshot.id = UUID()
        state.bindings.append(secondBinding)
        state.pendingMigrations = [f.journal, try MetadataCalendarMigrationJournal(source: secondBinding,
            destinationID: f.journal.destinationID, serverAddress: f.journal.serverAddress)]
        XCTAssertThrowsError(try state.validateMigrationJournals())
        try assertRejectedWithoutMutation(f) { try f.repository.save(state, replacingMigrations: []) }
    }

    func testConcurrentProcessLockFailsImmediatelyWithoutReplacingStore() throws {
        let f = try fixture()
        let lock = open(f.repository.url.path + ".migration-lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lock, 0)
        guard lock >= 0 else { return }
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(lock, LOCK_UN) }
        let before = try Data(contentsOf: f.repository.url)
        let started = Date()
        XCTAssertThrowsError(try f.repository.save(f.pending, replacingMigrations: [])) { error in
            XCTAssertEqual((error as? MetadataSyncFailure)?.diagnosticCode, "migration_store_busy")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "Contention must not block the caller")
        XCTAssertEqual(try Data(contentsOf: f.repository.url), before)
    }
}
