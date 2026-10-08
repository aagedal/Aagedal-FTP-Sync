import Foundation
import XCTest
@testable import AagedalFTPSync

final class VersionedCalendarStorageTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("versioned-calendar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func fixture() -> MetadataCalendarState {
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid", registered: true)
        let photographer = PhotographerProfile(name: "Example", filenamePrefix: "EX", creator: "Example", copyrightNotice: "© {photographer}")
        let date = Date(timeIntervalSince1970: 1_800_000_000.123)
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Fixture", startsAt: date, endsAt: date.addingTimeInterval(600),
            fields: ScheduledMetadataFields(headline: "Literal {date:YYYY-MM-DD}", description: "{{braces}}"))
        let automation = MetadataAutomation(photographers: [photographer], clips: [clip])
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: 7, role: "editor", document: SharedMetadataDocument(automation))
        var source = SyncJob(name: "Source")
        source.metadataAutomation = automation
        var duplicate = source
        duplicate.id = UUID()
        let binding = MetadataCalendarBinding(accountID: account.id, jobID: source.id, snapshot: calendar)
        let proposal = MetadataCalendarReceiveProposal(accountID: account.id, source: source, duplicate: duplicate, calendar: calendar)
        return MetadataCalendarState(accounts: [account], activeAccountID: account.id, bindings: [binding], pendingReceive: proposal)
    }
    private func seed(_ state: MetadataCalendarState, at url: URL) throws {
        try VersionedStoreCodec(format: .version3, store: .metadataCalendar)
            .encode(state, encoder: MetadataCalendarClient.encoder()).write(to: url)
    }

    func testV3StatePreservesReceiptBindingsDatesAndLiteralSource() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let repository = MetadataCalendarRepository(storage: layout)
        let state = fixture()
        try seed(state, at: repository.url)
        try repository.save(state)
        let loaded = try repository.load()
        // Nested write-policy Sets do not promise JSON array order. Compare
        // decoded values so their harmless encoding order cannot fail this test.
        XCTAssertEqual(loaded.accounts.map(\.id), state.accounts.map(\.id))
        XCTAssertEqual(loaded.accounts.map(\.address), state.accounts.map(\.address))
        XCTAssertEqual(loaded.accounts.map(\.registered), state.accounts.map(\.registered))
        XCTAssertEqual(loaded.activeAccountID, state.activeAccountID)
        XCTAssertEqual(loaded.bindings, state.bindings)
        XCTAssertEqual(loaded.pendingReceive?.id, state.pendingReceive?.id)
        XCTAssertEqual(loaded.pendingReceive?.accountID, state.pendingReceive?.accountID)
        XCTAssertEqual(loaded.pendingReceive?.source, state.pendingReceive?.source)
        XCTAssertEqual(loaded.pendingReceive?.duplicate, state.pendingReceive?.duplicate)
        XCTAssertEqual(loaded.pendingReceive?.calendar, state.pendingReceive?.calendar)
        XCTAssertEqual(loaded.pendingReceive?.source.metadataAutomation?.clips.first?.fields.headline, "Literal {date:YYYY-MM-DD}")
        let data = try Data(contentsOf: repository.url)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["store"] as? String, "metadataCalendar")
        XCTAssertThrowsError(try MetadataCalendarClient.decoder().decode(MetadataCalendarState.self, from: data))
    }

    func testLegacyCalendarAndEventsStillUseOriginalPayloadCodecs() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = fixture()
        let repository = MetadataCalendarRepository(url: root.appendingPathComponent("legacy.json"))
        try repository.save(state)
        let bytes = try Data(contentsOf: repository.url)
        let legacy = try MetadataCalendarClient.decoder().decode(MetadataCalendarState.self, from: bytes)
        XCTAssertEqual(legacy.bindings, state.bindings)
        XCTAssertEqual(legacy.pendingReceive?.source, state.pendingReceive?.source)
        XCTAssertEqual(legacy.activeAccountID, state.activeAccountID)
        XCTAssertNil((try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["schemaVersion"])
        let event = MetadataSyncEvent(date: Date(timeIntervalSince1970: 100.125), operation: "Fixture", detail: "Complete")
        let events = MetadataSyncEventRepository(url: repository.eventsURL)
        try events.save([event])
        let decoded = try JSONDecoder().decode([MetadataSyncEvent].self, from: Data(contentsOf: events.url))
        XCTAssertEqual(decoded.first?.date, event.date)
        XCTAssertEqual(events.load().first?.id, event.id)
    }

    func testV3MissingStoresCannotLoadAsEmptyOrBeRecreatedBySave() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MetadataCalendarRepository(storage: AppStorageLayout(root: root, storageFormat: .version3))
        let events = MetadataSyncEventRepository(url: repository.eventsURL, storageFormat: .version3)
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.save(fixture()))
        XCTAssertThrowsError(try events.loadResult())
        XCTAssertThrowsError(try events.save([]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testFutureWrongStoreAndUnidentifiedStateCannotBeReadOrOverwritten() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppStorageLayout(root: root, storageFormat: .version3)
        let repository = MetadataCalendarRepository(storage: layout)
        let events = MetadataSyncEventRepository(url: repository.eventsURL, storageFormat: .version3)
        for value in [
            "{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":4,\"store\":\"metadataCalendar\",\"payload\":null}",
            "{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":3,\"store\":\"jobs\",\"payload\":[]}",
            "[]", "broken"
        ] {
            let data = Data(value.utf8)
            try data.write(to: repository.url)
            try data.write(to: events.url)
            XCTAssertThrowsError(try repository.load())
            XCTAssertThrowsError(try repository.save(fixture()))
            XCTAssertThrowsError(try events.loadResult())
            XCTAssertThrowsError(try events.save([]))
            XCTAssertEqual(try Data(contentsOf: repository.url), data)
            XCTAssertEqual(try Data(contentsOf: events.url), data)
        }
    }

    func testV3EventsRetainBoundAndReferenceDatePrecision() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.json")
        let codec = VersionedStoreCodec(format: .version3, store: .metadataSyncEvents)
        try codec.encode([MetadataSyncEvent](), encoder: JSONEncoder()).write(to: url)
        let events = (0..<205).map { MetadataSyncEvent(date: Date(timeIntervalSince1970: Double($0) + 0.125), operation: "Fixture \($0)", detail: "Complete") }
        let repository = MetadataSyncEventRepository(url: url, storageFormat: .version3)
        try repository.save(events)
        let result = try repository.loadResult()
        XCTAssertEqual(result.count, 200)
        XCTAssertEqual(result.first?.id, events[5].id)
        XCTAssertEqual(result.last?.date, events.last?.date)
    }

    @MainActor
    func testV3CoordinatorReportsIncompatibleDiagnosticHistoryWithoutReplacingIt() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MetadataCalendarRepository(storage: AppStorageLayout(root: root, storageFormat: .version3))
        try seed(MetadataCalendarState(), at: repository.url)
        let bytes = Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":4,\"store\":\"metadataSyncEvents\",\"payload\":[]}".utf8)
        try bytes.write(to: repository.eventsURL)
        let coordinator = MetadataCalendarCoordinator(repository: repository)
        XCTAssertFalse(coordinator.eventStorageError.isEmpty)
        XCTAssertTrue(coordinator.events.isEmpty)
        XCTAssertEqual(try Data(contentsOf: repository.eventsURL), bytes)
    }
}
