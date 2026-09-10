import Foundation
import XCTest
@testable import AagedalFTPSync

final class Version3JSONStoreConversionTests: XCTestCase {
    private let jobsName = "jobs-v2.json"
    private let calendarName = "metadata-sync-v1.json"

    private func encode<T: Encodable>(_ value: T, calendar: Bool = false, iso: Bool = false) throws -> Data {
        let encoder = calendar ? MetadataCalendarClient.encoder() : JSONEncoder()
        if iso { encoder.dateEncodingStrategy = .iso8601 }
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, store: VersionedStoreCodec.Store, name: String,
                                       result: Version3JSONStoreConversion.Result, calendar: Bool = false, iso: Bool = false) throws -> T {
        let decoder = calendar ? MetadataCalendarClient.decoder() : JSONDecoder()
        if iso { decoder.dateDecodingStrategy = .iso8601 }
        return try VersionedStoreCodec(format: .version3, store: store).decode(type, from: XCTUnwrap(result.stores[name]), decoder: decoder)
    }

    private func fixture() -> (SyncJob, ServerProfile, MetadataCalendarState) {
        let profile = ServerProfile(name: "Fixture", kind: .ftp, host: "fixture.invalid", username: "test", credentialID: "profile-credential")
        var job = SyncJob(name: "Literal {gps:city}")
        job.left = profile.endpoint()
        let photographer = PhotographerProfile(name: "Nested snapshot", filenamePrefix: "NS", creator: "{photographer}", copyrightNotice: "unclosed {literal")
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Clip", startsAt: Date(timeIntervalSince1970: 1_700_000_000.125),
                                       endsAt: Date(timeIntervalSince1970: 1_700_000_060.125),
                                       fields: ScheduledMetadataFields(headline: "{gps:city}", description: "{not-activated}", keywords: ["Doe, Jane", "{{literal}}", "{persons}"]))
        job.metadataAutomation = MetadataAutomation(photographers: [photographer], photographerTracks: [], clips: [clip])
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid", registered: true)
        let snapshot = SharedMetadataCalendar(id: UUID(), name: "Snapshot", timeZone: "Etc/UTC", revision: 1, role: "editor",
                                             document: SharedMetadataDocument(job.metadataAutomation!))
        let state = MetadataCalendarState(accounts: [account], activeAccountID: account.id,
                                          bindings: [MetadataCalendarBinding(accountID: account.id, jobID: job.id, snapshot: snapshot)])
        return (job, profile, state)
    }

    func testAbsentSourcesProduceCompleteExplicitVersionedStoreSet() throws {
        let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [:])
        XCTAssertEqual(Set(result.stores.keys), Version3JSONStoreConversion.primaryFilenames)
        XCTAssertEqual(result.stores.count, 9)
        XCTAssertEqual(result.summary.initializedAbsentStores, Version3JSONStoreConversion.primaryFilenames)
        XCTAssertTrue(result.summary.selectedSourceSHA256.isEmpty)
        XCTAssertTrue(result.retainedCredentialIDs.isEmpty)
        XCTAssertTrue(result.summary.recordCounts.values.allSatisfy { $0 == 0 })
        let jobs = try decode([SyncJob].self, store: .jobs, name: jobsName, result: result, iso: true)
        XCTAssertTrue(jobs.isEmpty)
        let calendar = try decode(MetadataCalendarState.self, store: .metadataCalendar, name: calendarName, result: result, calendar: true)
        XCTAssertTrue(calendar.accounts.isEmpty)
        XCTAssertNil(calendar.pendingReceive)
    }

    func testConversionPreservesAllSelectedPayloadBytesLiteralFieldsAndIndependentSnapshots() throws {
        let (job, profile, calendar) = fixture()
        var globalPhotographer = try XCTUnwrap(job.metadataAutomation?.photographers.first)
        globalPhotographer.name = "Global newer name"
        globalPhotographer.creator = "Different global creator"
        let preset = MetadataPreset(name: "{unknown}", fields: ScheduledMetadataFields(headline: "{{{gps:city}}}", keywords: ["Doe, Jane"]))
        let failure = SyncFailureRecord(jobID: job.id, occurredAt: Date(timeIntervalSince1970: 1_700_000_000), message: "fixture")
        let audit = MetadataAuditEntry(runID: UUID(), jobID: job.id, occurredAt: failure.occurredAt, operation: .transfer,
            relativePath: "photo.jpg", status: .skipped, timestampPolicy: .sourceModification, scheduledAt: nil)
        let manifest = DownloadManifestRepository.Record(jobID: job.id,
            destination: DownloadManifestRepository.DestinationIdentity(endpoint: Endpoint(kind: .local, localPath: "/fixture/photos")), relativePath: "photo.jpg")
        let event = MetadataSyncEvent(date: Date(timeIntervalSince1970: 1_700_000_000.25), jobID: job.id, operation: "Fixture", detail: "Preserved")
        var input = [
            jobsName: try encode([job], iso: true),
            "server-profiles-v1.json": try encode([profile]),
            "photographers-v1.json": try encode([globalPhotographer]),
            "metadata-presets-v1.json": try encode([preset], iso: true),
            calendarName: try encode(calendar, calendar: true),
            "metadata-sync-events-v1.json": try encode([event]),
            "metadata-audit-v1.json": try encode([audit], iso: true),
            "sync-errors-v1.json": try encode([failure], iso: true),
            "download-manifest-v1.json": try encode([manifest])
        ]
        // An unknown old-payload property is retained; conversion does not claim to interpret it.
        var rawJobs = try XCTUnwrap(JSONSerialization.jsonObject(with: input[jobsName]!) as? [[String: Any]])
        rawJobs[0]["legacyExtension"] = ["literal": "{preserve-me}"]
        input[jobsName] = try JSONSerialization.data(withJSONObject: rawJobs, options: [.sortedKeys])
        let originalInput = input
        let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input)
        XCTAssertEqual(input, originalInput)
        for (name, bytes) in input {
            let output = try XCTUnwrap(result.stores[name])
            XCTAssertEqual(Data(output.suffix(bytes.count + 1)), bytes + Data("}".utf8), name)
            XCTAssertEqual(result.summary.selectedSourceSHA256[name]?.count, 64)
            XCTAssertEqual(result.summary.recordCounts[name], 1)
        }
        let converted = try decode([SyncJob].self, store: .jobs, name: jobsName, result: result, iso: true)
        XCTAssertEqual(converted.first?.metadataAutomation?.photographers.first?.name, "Nested snapshot")
        XCTAssertEqual(converted.first?.metadataAutomation?.clips.first?.fields.keywords, ["Doe, Jane", "{{literal}}", "{persons}"])
        let convertedCalendar = try decode(MetadataCalendarState.self, store: .metadataCalendar, name: calendarName, result: result, calendar: true)
        XCTAssertEqual(convertedCalendar.bindings.first?.snapshot, calendar.bindings.first?.snapshot)
        XCTAssertTrue(result.retainedCredentialIDs.contains(profile.credentialID))
        XCTAssertTrue(result.retainedCredentialIDs.contains(calendar.accounts[0].credentialID))
    }

    func testMalformedPresentUnknownBackupAndOverBudgetSourcesNeverFallback() throws {
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: Data("not JSON".utf8)]))
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName + ".backup": Data("[]".utf8)])) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .unsupportedSource(self.jobsName + ".backup"))
        }
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: Data("[]".utf8)], maximumInputBytes: 1)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .inputLimitExceeded)
        }
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: Data("{}".utf8)]))
    }

    func testMissingHardReferencesAndDuplicateLiveIdentitiesAreRejected() throws {
        let (job, profile, state) = fixture()
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: encode([job], iso: true)])) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .invalidReference("job server profile"))
        }
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: encode([job, job], iso: true),
            "server-profiles-v1.json": encode([profile])]))
        var invalidAccount = state
        invalidAccount.activeAccountID = UUID()
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [calendarName: encode(invalidAccount, calendar: true)]))
        invalidAccount = state
        invalidAccount.bindings[0].accountID = UUID()
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [calendarName: encode(invalidAccount, calendar: true)]))
    }

    func testHistoricalAndDetachedBindingReferencesAreReportedAndRetained() throws {
        let (_, _, state) = fixture()
        let deletedID = state.bindings[0].jobID
        let audit = MetadataAuditEntry(runID: UUID(), jobID: deletedID, operation: .transfer, relativePath: "old.jpg",
                                      status: .skipped, timestampPolicy: .sourceModification, scheduledAt: nil)
        let failure = SyncFailureRecord(jobID: deletedID, message: "Past failure")
        let event = MetadataSyncEvent(jobID: deletedID, operation: "Old event", detail: "History")
        let record = DownloadManifestRepository.Record(jobID: deletedID,
            destination: DownloadManifestRepository.DestinationIdentity(endpoint: Endpoint(kind: .local, localPath: "/fixture/photos")), relativePath: "old.jpg")
        let input = [calendarName: try encode(state, calendar: true), "metadata-audit-v1.json": try encode([audit], iso: true),
                     "sync-errors-v1.json": try encode([failure], iso: true), "metadata-sync-events-v1.json": try encode([event]),
                     "download-manifest-v1.json": try encode([record])]
        let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input)
        XCTAssertEqual(result.summary.calendarBindingJobIDsWithoutCurrentJob, [deletedID])
        XCTAssertTrue(result.summary.historicalJobIDsWithoutCurrentJob.values.allSatisfy { $0 == [deletedID] })
        for (name, bytes) in input { XCTAssertEqual(Data(result.stores[name]!.suffix(bytes.count + 1)), bytes + Data("}".utf8)) }
    }

    func testPendingReceiptAcceptsBothAtomicJobPhasesAndRejectsMismatchedInstalledCopy() throws {
        let (source, profile, initialCalendar) = fixture()
        var duplicate = source
        duplicate.id = UUID()
        duplicate.name = "Received copy"
        duplicate.isEnabled = false
        duplicate.startsOnAppLaunch = false
        var calendar = initialCalendar
        calendar.bindings = []
        calendar.pendingReceive = MetadataCalendarReceiveProposal(accountID: calendar.accounts[0].id, source: source,
                                                                  duplicate: duplicate, calendar: initialCalendar.bindings[0].snapshot)
        var input = [jobsName: try encode([source], iso: true), "server-profiles-v1.json": try encode([profile]), calendarName: try encode(calendar, calendar: true)]
        let before = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input)
        XCTAssertEqual(before.summary.pendingReceiptPhase, .beforeInstallation)
        var paused = source
        paused.isEnabled = false
        paused.startsOnAppLaunch = false
        input[jobsName] = try encode([paused, duplicate], iso: true)
        let installed = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input)
        XCTAssertEqual(installed.summary.pendingReceiptPhase, .jobsInstalled)
        duplicate.name = "Different job colliding with received ID"
        input[jobsName] = try encode([paused, duplicate], iso: true)
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .invalidPendingReceipt)
        }
    }

    func testPendingSnapshotCredentialIDsAreRetainedEvenWhenProjectionUsesProfile() throws {
        let (source, profile, initialCalendar) = fixture()
        var duplicate = source
        duplicate.id = UUID()
        duplicate.isEnabled = false
        duplicate.startsOnAppLaunch = false
        duplicate.left.credentialID = "retained-projection-id"
        var calendar = initialCalendar
        calendar.bindings = []
        calendar.pendingReceive = MetadataCalendarReceiveProposal(accountID: calendar.accounts[0].id, source: source,
                                                                  duplicate: duplicate, calendar: initialCalendar.bindings[0].snapshot)
        let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: encode([source], iso: true),
            "server-profiles-v1.json": encode([profile]), calendarName: encode(calendar, calendar: true)])
        XCTAssertTrue(result.retainedCredentialIDs.contains("retained-projection-id"))
        XCTAssertTrue(result.retainedCredentialIDs.contains(profile.credentialID))
    }

    func testUnboundedImplicitTracksAreRejectedBeforeLegacyModelInference() throws {
        let (job, profile, _) = fixture()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encode([job], iso: true)) as? [[String: Any]])
        var automation = try XCTUnwrap(raw[0]["metadataAutomation"] as? [String: Any])
        automation.removeValue(forKey: "photographerTracks")
        var clips = try XCTUnwrap(automation["clips"] as? [[String: Any]])
        clips[0]["startsAt"] = "0001-01-01T00:00:00Z"
        clips[0]["endsAt"] = "9999-12-31T00:00:00Z"
        automation["clips"] = clips
        raw[0]["metadataAutomation"] = automation
        let data = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: data, "server-profiles-v1.json": encode([profile])])) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .explicitPhotographerTracksRequired(self.jobsName))
        }
    }

    func testNonUTF8AndBOMSourcesCannotProduceUnreadableWrappedStores() throws {
        let inputs = [Data([0xEF, 0xBB, 0xBF]) + Data("[]".utf8),
                      try XCTUnwrap("[]".data(using: .utf16)), try XCTUnwrap("[]".data(using: .utf32))]
        for bytes in inputs {
            XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: bytes])) {
                XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .unsupportedJSONEncoding(self.jobsName))
            }
        }
    }

    func testDuplicateTrackKeysUseSameSelectionForPreflightAndPayloadModels() throws {
        struct Probe: Decodable { let photographerTracks: [String]? }
        let (job, profile, _) = fixture()
        let text = try XCTUnwrap(String(data: encode([job], iso: true), encoding: .utf8))
        for keys in [#""photographerTracks":null,"photographerTracks":[]"#,
                     #""photographerTracks":[],"photographerTracks":null"#] {
            let selected = try JSONDecoder().decode(Probe.self, from: Data(("{" + keys + "}").utf8))
            let replaced = text.replacingOccurrences(of: #""photographerTracks":[]"#, with: keys)
            XCTAssertNotEqual(replaced, text)
            let input = [jobsName: Data(replaced.utf8), "server-profiles-v1.json": try encode([profile])]
            if selected.photographerTracks == nil {
                XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input)) {
                    XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .explicitPhotographerTracksRequired(self.jobsName))
                }
            } else {
                let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input)
                XCTAssertEqual(Data(result.stores[jobsName]!.suffix(input[jobsName]!.count + 1)), input[jobsName]! + Data("}".utf8))
            }
        }
    }
}
