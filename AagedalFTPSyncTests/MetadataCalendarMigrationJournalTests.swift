import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class MetadataCalendarMigrationJournalTests: XCTestCase {
    private func binding() -> MetadataCalendarBinding {
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Creator", copyrightNotice: "Literal {unknown}")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Clip", startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: Date(timeIntervalSince1970: 1_800_000_600),
            fields: ScheduledMetadataFields(headline: "Literal {gps:city}", description: "Unmatched {", keywords: [" one ", "one"]))
        let document = SharedMetadataDocument(MetadataAutomation(photographers: [profile], photographerTracks: [], clips: [clip]))
        return MetadataCalendarBinding(accountID: UUID(), jobID: UUID(),
            snapshot: .init(id: UUID(), name: "Legacy", timeZone: "Europe/Oslo", revision: 19, role: "owner", document: document))
    }

    private func journal(_ source: MetadataCalendarBinding? = nil) throws -> MetadataCalendarMigrationJournal {
        try .init(source: source ?? binding(), destinationID: UUID(), serverAddress: "HTTPS://Fixture.Invalid/calendar/index.php")
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; value.dateEncodingStrategy = .millisecondsSince1970; return value
    }
    private var decoder: JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value
    }

    func testPreparedRoundtripPinsSourceEndpointAndDestinationWithoutRewritingLiteralBytes() throws {
        let source = binding(), targetID = UUID()
        let prepared = try MetadataCalendarMigrationJournal(source: source, destinationID: targetID,
            serverAddress: "HTTPS://Fixture.Invalid/calendar/index.php")
        XCTAssertEqual(prepared.serverAddress, "https://fixture.invalid/calendar/")
        XCTAssertEqual(prepared.source, source)
        XCTAssertEqual(prepared.destinationID, targetID)
        XCTAssertNotEqual(prepared.destinationID, prepared.source.id)
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertEqual(prepared.recoveryAction, .fetchDestination)
        XCTAssertNil(prepared.confirmedSnapshot)
        XCTAssertEqual(prepared.proposedSnapshot.document, source.snapshot.document)
        XCTAssertEqual(prepared.proposedSnapshot.compatibility, .templates)
        XCTAssertEqual(prepared.proposedSnapshot.role, "owner")
        XCTAssertEqual(prepared.proposedSnapshot.revision, 1)
        let bytes = try encoder.encode(prepared)
        let restored = try decoder.decode(MetadataCalendarMigrationJournal.self, from: bytes)
        XCTAssertEqual(restored, prepared)
        XCTAssertEqual(try encoder.encode(restored.source), try encoder.encode(source))
        XCTAssertEqual(restored.proposedSnapshot.document.clips[0].fields.keywords, [" one ", "one"])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("confirmedSnapshot"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("credential"))
    }

    func testConfirmationAndRebindAreMonotonicAndKeepLegacyProvenance() throws {
        var source = binding()
        source.publicationRange = .init(start: source.snapshot.document.clips[0].startsAt, end: source.snapshot.document.clips[0].endsAt)
        let prepared = try journal(source)
        let confirmed = try prepared.confirmCreated(prepared.proposedSnapshot)
        XCTAssertEqual(confirmed.phase, .serverConfirmed)
        XCTAssertEqual(confirmed.recoveryAction, .reconcileBinding)
        XCTAssertEqual(try confirmed.confirmCreated(prepared.proposedSnapshot), confirmed)
        var destination = source; destination.snapshot = prepared.proposedSnapshot
        let committed = try confirmed.markBindingCommitted(destination)
        XCTAssertEqual(committed.phase, .bindingCommitted)
        XCTAssertEqual(committed.recoveryAction, .retainProvenance)
        XCTAssertEqual(committed.source, source)
        XCTAssertEqual(committed.destinationID, prepared.destinationID)
        XCTAssertEqual(try committed.markBindingCommitted(destination), committed)
        XCTAssertThrowsError(try prepared.markBindingCommitted(destination))
        XCTAssertThrowsError(try committed.confirmCreated(prepared.proposedSnapshot))
        for receipt in [confirmed, committed] {
            XCTAssertEqual(try decoder.decode(MetadataCalendarMigrationJournal.self, from: encoder.encode(receipt)), receipt)
        }
    }

    func testUncertainRecoveryNeverAcceptsChangedIdentityContentPermissionsOrRevision() throws {
        let prepared = try journal()
        for side in 0..<7 {
            var response = prepared.proposedSnapshot
            switch side {
            case 0: response.id = UUID()
            case 1: response.compatibility = .legacy
            case 2: response.revision = 2
            case 3: response.role = "editor"
            case 4: response.document.clips[0].fields.headline = "Changed"
            case 5: response.timeZone = "Etc/UTC"
            default: response.rangeStart = Date(timeIntervalSince1970: 1_800_000_000)
            }
            XCTAssertThrowsError(try prepared.confirmCreated(response))
            XCTAssertEqual(prepared.phase, .prepared)
            XCTAssertEqual(prepared.recoveryAction, .fetchDestination)
        }
    }

    func testRebindMustMatchSourceJobAccountScopeAndConfirmedSnapshot() throws {
        var source = binding()
        source.publicationRange = .init(start: source.snapshot.document.clips[0].startsAt, end: source.snapshot.document.clips[0].endsAt)
        let prepared = try journal(source), confirmed = try prepared.confirmCreated(prepared.proposedSnapshot)
        for side in 0..<5 {
            var destination = source; destination.snapshot = prepared.proposedSnapshot
            switch side {
            case 0: destination.accountID = UUID()
            case 1: destination.jobID = UUID()
            case 2: destination.snapshot = source.snapshot
            case 3: destination.conflict = prepared.proposedSnapshot
            default: destination.publicationRange = nil
            }
            XCTAssertThrowsError(try confirmed.markBindingCommitted(destination))
        }
    }

    func testNewIntentRejectsNonlegacyActiveConflictedScopedAndInvalidSources() throws {
        for side in 0..<9 {
            var source = binding()
            switch side {
            case 0: source.snapshot.compatibility = .templates
            case 1: source.snapshot.document.clips[0].fields.setHeadline(try .activated("{gps:city}"))
            case 2: source.snapshot.document.photographers[0].setCopyright(try .activated("{gps:city}"))
            case 3: source.conflict = source.snapshot
            case 4: source.snapshot.role = "editor"
            case 5: source.snapshot.rangeStart = Date(timeIntervalSince1970: 1_800_000_000)
            case 6: source.snapshot.revision = 0
            case 7: source.snapshot.document.clips[0].endsAt = Date(timeIntervalSince1970: .infinity)
            default: source.snapshot.document.clips.append(source.snapshot.document.clips[0])
            }
            XCTAssertThrowsError(try journal(source))
        }
        let source = binding()
        XCTAssertThrowsError(try MetadataCalendarMigrationJournal(source: source, destinationID: source.id, serverAddress: "fixture.invalid"))
        XCTAssertThrowsError(try MetadataCalendarMigrationJournal(source: source, destinationID: UUID(), serverAddress: "https://user:secret@fixture.invalid"))
    }

    func testStrictDecoderRejectsMissingNullUnknownFutureAndInconsistentReceipt() throws {
        let prepared = try journal()
        let good = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(prepared)) as? [String: Any])
        for key in good.keys {
            var missing = good; missing.removeValue(forKey: key)
            var null = good; null[key] = NSNull()
            for object in [missing, null] { try assertInvalid(object) }
        }
        for (key, replacement) in [("schemaVersion", 2 as Any), ("schemaVersion", true as Any), ("unknown", 1 as Any),
            ("destinationID", "not-a-uuid" as Any), ("destinationID", prepared.source.id.uuidString as Any),
            ("serverAddress", "Fixture.Invalid/calendar" as Any), ("phase", "unknown" as Any),
            ("phase", "serverConfirmed" as Any), ("phase", "bindingCommitted" as Any), ("confirmedSnapshot", NSNull() as Any)] {
            var object = good; object[key] = replacement; try assertInvalid(object)
        }
        var object = good
        object["confirmedSnapshot"] = try JSONSerialization.jsonObject(with: encoder.encode(prepared.proposedSnapshot))
        try assertInvalid(object) // Prepared must not silently acquire confirmation.
        object["phase"] = "serverConfirmed"
        XCTAssertNoThrow(try decoder.decode(MetadataCalendarMigrationJournal.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    private func assertInvalid(_ object: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try decoder.decode(MetadataCalendarMigrationJournal.self, from: bytes)) { error in
            XCTAssertEqual(error as? MetadataTemplateRecordError, .invalidSource)
            XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error))
        }
    }
}
