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

    private func fixedCalendar(_ identifier: Calendar.Identifier = .gregorian, zone: String = "Etc/UTC") -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func payload(_ name: String, _ result: Version3JSONStoreConversion.Result) throws -> String {
        let text = try XCTUnwrap(String(data: XCTUnwrap(result.stores[name]), encoding: .utf8))
        let marker = try XCTUnwrap(text.range(of: "\"payload\":"))
        return String(text[marker.upperBound..<text.index(before: text.endIndex)])
    }

    private func implicit(_ data: Data, null: Bool = true) throws -> Data {
        // Fixture values have explicit empty tracks. JSONEncoder does not emit whitespace.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let replacement = null ? "\"photographerTracks\":null" : "\"fixturePreserved\":\"{literal} 😺\""
        let changed = text.replacingOccurrences(of: "\"photographerTracks\":[]", with: replacement)
        XCTAssertNotEqual(text, changed)
        return Data(changed.utf8)
    }

    func testFrozenCalendarPatchesOnlyMissingOrNullMemberAndIsDeterministic() throws {
        let (job, profile, _) = fixture()
        for useNull in [false, true] {
            let bytes = try implicit(encode([job], iso: true), null: useNull)
            let input = [jobsName: bytes, "server-profiles-v1.json": try encode([profile])]
            let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: fixedCalendar())
            let repeated = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: fixedCalendar())
            XCTAssertEqual(result.stores[jobsName], repeated.stores[jobsName])
            let jobs = try decode([SyncJob].self, store: .jobs, name: jobsName, result: result, iso: true)
            let tracks = try XCTUnwrap(jobs.first?.metadataAutomation?.photographerTracks)
            XCTAssertEqual(tracks.count, 1)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encodedTracks = try XCTUnwrap(String(data: encoder.encode(tracks), encoding: .utf8))
            let patched = try payload(jobsName, result)
            let reversed = useNull
                ? patched.replacingOccurrences(of: encodedTracks, with: "null")
                : patched.replacingOccurrences(of: ",\"photographerTracks\":" + encodedTracks, with: "")
            XCTAssertEqual(Data(reversed.utf8), bytes, "All original bytes survive outside the explicit track patch")
            XCTAssertEqual(result.summary.selectedSourceSHA256, repeated.summary.selectedSourceSHA256)
            XCTAssertEqual(result.summary.trackInference?.calendarIdentifier, "gregorian")
            XCTAssertEqual(result.summary.trackInference?.timeZoneIdentifier, "Etc/UTC")
            XCTAssertEqual(result.summary.trackInference?.adaptedObjects, 1)
            XCTAssertEqual(result.summary.trackInference?.inferredTracks, 1)
            XCTAssertEqual(result.summary.trackInference?.dayIterations, 1)
        }
    }

    func testFrozenCalendarRespectsDSTExclusiveMidnightAndClipOrderDeduplication() throws {
        let (original, profile, _) = fixture()
        var job = original
        var automation = try XCTUnwrap(job.metadataAutomation)
        let date = ISO8601DateFormatter()
        for (start, end, month, days) in [
            ("2026-03-28T23:00:00Z", "2026-03-30T22:00:00Z", 3, [29, 30]),
            ("2026-10-24T22:00:00Z", "2026-10-26T23:00:00Z", 10, [25, 26])
        ] {
            var clip = automation.clips[0]
            clip.startsAt = try XCTUnwrap(date.date(from: start))
            clip.endsAt = try XCTUnwrap(date.date(from: end))
            var overlap = clip
            overlap.id = UUID()
            automation.clips = [clip, overlap]
            job.metadataAutomation = automation
            let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [
                jobsName: implicit(encode([job], iso: true)), "server-profiles-v1.json": encode([profile])
            ], implicitTrackCalendar: fixedCalendar(zone: "Europe/Oslo"))
            let jobs = try decode([SyncJob].self, store: .jobs, name: jobsName, result: result, iso: true)
            let tracks = try XCTUnwrap(jobs.first?.metadataAutomation?.photographerTracks)
            XCTAssertEqual(tracks.map(\.date.day), days)
            XCTAssertEqual(tracks.map(\.date.month), [month, month])
            XCTAssertEqual(tracks.map(\.photographerID), [clip.photographerID, clip.photographerID])
            XCTAssertEqual(result.summary.trackInference?.dayIterations, 4)
            XCTAssertEqual(result.summary.trackInference?.inferredTracks, 2)
        }
    }

    func testCallerCalendarIdentifierIsHonoredInsteadOfAssumingGregorian() throws {
        let (job, profile, _) = fixture()
        let input = [jobsName: try implicit(encode([job], iso: true)), "server-profiles-v1.json": try encode([profile])]
        let gregorian = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: fixedCalendar())
        let buddhist = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: fixedCalendar(.buddhist))
        let first = try decode([SyncJob].self, store: .jobs, name: jobsName, result: gregorian, iso: true)
        let second = try decode([SyncJob].self, store: .jobs, name: jobsName, result: buddhist, iso: true)
        XCTAssertEqual(first[0].metadataAutomation?.photographerTracks.first?.date.year, 2023)
        XCTAssertEqual(second[0].metadataAutomation?.photographerTracks.first?.date.year, 2566)
        XCTAssertEqual(buddhist.summary.trackInference?.calendarIdentifier, "buddhist")
    }

    func testBindingConflictAndEveryPendingReceiptCopyAreAdaptedWithOwnDatePolicy() throws {
        let (source, profile, initial) = fixture()
        var state = initial
        state.bindings[0].conflict = state.bindings[0].snapshot
        var input = [jobsName: try implicit(encode([source], iso: true)), "server-profiles-v1.json": try encode([profile]),
                     calendarName: try implicit(encode(state, calendar: true))]
        let bindingResult = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: fixedCalendar())
        let bindingState = try decode(MetadataCalendarState.self, store: .metadataCalendar, name: calendarName, result: bindingResult, calendar: true)
        XCTAssertEqual(bindingResult.summary.trackInference?.adaptedObjects, 3)
        XCTAssertEqual(bindingState.bindings[0].snapshot.document.photographerTracks.count, 1)
        XCTAssertEqual(bindingState.bindings[0].conflict?.document.photographerTracks.count, 1)
        XCTAssertEqual(bindingState.bindings[0].snapshot.document.clips[0].startsAt, initial.bindings[0].snapshot.document.clips[0].startsAt)
        var duplicate = source
        duplicate.id = UUID()
        duplicate.isEnabled = false
        duplicate.startsOnAppLaunch = false
        state.bindings = []
        state.pendingReceive = MetadataCalendarReceiveProposal(accountID: state.accounts[0].id, source: source,
            duplicate: duplicate, calendar: initial.bindings[0].snapshot)
        input[calendarName] = try implicit(encode(state, calendar: true), null: false)
        let pendingResult = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: fixedCalendar())
        let pendingState = try decode(MetadataCalendarState.self, store: .metadataCalendar, name: calendarName, result: pendingResult, calendar: true)
        let pending = try XCTUnwrap(pendingState.pendingReceive)
        XCTAssertEqual(pendingResult.summary.trackInference?.adaptedObjects, 4)
        XCTAssertEqual(pendingResult.summary.pendingReceiptPhase, .beforeInstallation)
        XCTAssertEqual(pending.source.metadataAutomation?.photographerTracks.count, 1)
        XCTAssertEqual(pending.duplicate.metadataAutomation?.photographerTracks.count, 1)
        XCTAssertEqual(pending.calendar.document.photographerTracks.count, 1)
    }

    func testInferenceBudgetIsAggregateAcrossStoresAndInvalidIntervalsFailClosed() throws {
        let (source, profile, state) = fixture()
        let input = [jobsName: try implicit(encode([source], iso: true)), "server-profiles-v1.json": try encode([profile]),
                     calendarName: try implicit(encode(state, calendar: true))]
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input,
            implicitTrackCalendar: fixedCalendar(), maximumInferredDayIterations: 1)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .trackInferenceLimitExceeded)
        }
        let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input,
            implicitTrackCalendar: fixedCalendar(), maximumInferredDayIterations: 2)
        XCTAssertEqual(result.summary.trackInference?.dayIterations, 2)
        for budget in [0, 50_001] {
            XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input,
                implicitTrackCalendar: fixedCalendar(), maximumInferredDayIterations: budget)) {
                XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .invalidTrackInferenceOptions)
            }
        }
        var invalid = source
        let invalidStart = try XCTUnwrap(invalid.metadataAutomation?.clips.first?.startsAt)
        invalid.metadataAutomation?.clips[0].endsAt = invalidStart
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: implicit(encode([invalid], iso: true)),
            "server-profiles-v1.json": encode([profile])], implicitTrackCalendar: fixedCalendar())) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .invalidRecord("implicit track date range"))
        }
        invalid.metadataAutomation?.clips[0].endsAt = Date(timeIntervalSince1970: 253_402_300_800)
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: implicit(encode([invalid], iso: true)),
            "server-profiles-v1.json": encode([profile])], implicitTrackCalendar: fixedCalendar()))
    }

    func testUnknownClipShapedExtensionsRemainOpaqueWithOrWithoutCalendar() throws {
        let (job, profile, _) = fixture()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encode([job], iso: true)) as? [[String: Any]])
        let automation = try XCTUnwrap(raw[0]["metadataAutomation"] as? [String: Any])
        raw[0]["legacyExtension"] = ["clips": try XCTUnwrap(automation["clips"]), "literal": "{unknown} 😺"]
        let bytes = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        let input = [jobsName: bytes, "server-profiles-v1.json": try encode([profile])]
        for calendar in [nil, fixedCalendar()] as [Calendar?] {
            let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: calendar)
            XCTAssertEqual(Data(try payload(jobsName, result).utf8), bytes)
            XCTAssertEqual(result.summary.trackInference?.adaptedObjects ?? 0, 0)
        }
    }

    func testFrozenAdapterRejectsAmbiguousKnownTrackKeysBeforePatching() throws {
        let (job, profile, _) = fixture()
        let text = try XCTUnwrap(String(data: encode([job], iso: true), encoding: .utf8))
        let changed = text.replacingOccurrences(of: "\"photographerTracks\":[]", with: "\"photographerTracks\":null,\"photographerTracks\":[]")
        XCTAssertNotEqual(text, changed)
        XCTAssertThrowsError(try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: Data(changed.utf8),
            "server-profiles-v1.json": encode([profile])], implicitTrackCalendar: fixedCalendar())) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .ambiguousTrackInference(self.jobsName))
        }
    }

    func testExplicitPayloadsAcrossAllNineStoresRemainUnchangedWithCalendarOption() throws {
        let empty = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [:])
        var input: [String: Data] = [:]
        for name in Version3JSONStoreConversion.primaryFilenames {
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(empty.stores[name])) as? [String: Any])
            input[name] = try JSONSerialization.data(withJSONObject: XCTUnwrap(envelope["payload"]), options: [.sortedKeys])
        }
        let result = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: input, implicitTrackCalendar: fixedCalendar())
        XCTAssertEqual(result.stores.count, 9)
        XCTAssertEqual(result.summary.trackInference?.adaptedObjects, 0)
        for (name, bytes) in input { XCTAssertEqual(Data(try payload(name, result).utf8), bytes, name) }
    }

    private func currentEnvelope(_ bytes: Data, store: VersionedStoreCodec.Store) -> Data {
        Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":3,\"store\":\"\(store.rawValue)\",\"payload\":".utf8) + bytes + Data("}".utf8)
    }

    func testCurrentValidationAcceptsCompleteSetPreservesInputAndReportsCurrentCredentials() throws {
        let (job, profile, state) = fixture()
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: encode([job], iso: true),
            "server-profiles-v1.json": encode([profile]), calendarName: encode(state, calendar: true)])
        var current = converted.stores
        current["source-signatures.sqlite"] = Data("caller-owned opaque bytes".utf8)
        let original = current
        let result = try Version3JSONStoreConversion.validateCurrentStores(current)
        XCTAssertEqual(current, original)
        XCTAssertEqual(result.summary.recordCounts, converted.summary.recordCounts)
        XCTAssertEqual(result.retainedCredentialIDs, converted.retainedCredentialIDs)
        XCTAssertEqual(Set(result.summary.selectedSourceSHA256.keys), Version3JSONStoreConversion.primaryFilenames)
        XCTAssertTrue(result.summary.initializedAbsentStores.isEmpty)
        XCTAssertNil(result.summary.trackInference)
        // Current provenance hashes envelopes; conversion provenance hashes legacy payloads.
        XCTAssertNotEqual(result.summary.selectedSourceSHA256[jobsName], converted.summary.selectedSourceSHA256[jobsName])
    }

    func testCurrentValidationRequiresEveryStoreAndStrictHeadersWithinTotalBound() throws {
        let current = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [:]).stores
        for name in Version3JSONStoreConversion.primaryFilenames {
            var missing = current
            missing.removeValue(forKey: name)
            XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(missing)) {
                XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .missingCurrentStore(name))
            }
        }
        for invalid in [
            #"{"format":"AagedalFTPSync.store","schemaVersion":4,"store":"jobs","payload":[]}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":null,"store":"jobs","payload":[]}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":3,"store":"photographers","payload":[]}"#,
            #"{"format":"wrong","schemaVersion":3,"store":"jobs","payload":[]}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":3,"store":"jobs","payload":[],"payload":[]}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":3,"store":"jobs"}"#,
            "[]", "malformed"
        ] {
            var changed = current
            changed[jobsName] = Data(invalid.utf8)
            XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(changed))
        }
        let total = current.values.reduce(0) { $0 + $1.count }
        XCTAssertNoThrow(try Version3JSONStoreConversion.validateCurrentStores(current, maximumInputBytes: total))
        XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(current, maximumInputBytes: total - 1)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .inputLimitExceeded)
        }
    }

    func testCurrentValidationRejectsNonemptyImplicitTracksBeforeModelDecodeAndAllowsEmptyDefaults() throws {
        let (job, profile, state) = fixture()
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: encode([job], iso: true),
            "server-profiles-v1.json": encode([profile]), calendarName: encode(state, calendar: true)])
        var rawJobs = try XCTUnwrap(JSONSerialization.jsonObject(with: encode([job], iso: true)) as? [[String: Any]])
        var automation = try XCTUnwrap(rawJobs[0]["metadataAutomation"] as? [String: Any])
        automation.removeValue(forKey: "photographerTracks")
        var clips = try XCTUnwrap(automation["clips"] as? [[String: Any]])
        clips[0]["startsAt"] = "0001-01-01T00:00:00Z"
        clips[0]["endsAt"] = "9999-12-31T00:00:00Z"
        for values in [clips, []] {
            automation["clips"] = values
            rawJobs[0]["metadataAutomation"] = automation
            var current = converted.stores
            current[jobsName] = currentEnvelope(try JSONSerialization.data(withJSONObject: rawJobs), store: .jobs)
            if values.isEmpty {
                XCTAssertNoThrow(try Version3JSONStoreConversion.validateCurrentStores(current))
            } else {
                XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(current)) {
                    XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .explicitPhotographerTracksRequired(self.jobsName))
                }
            }
        }
        var current = converted.stores
        current[calendarName] = currentEnvelope(try implicit(encode(state, calendar: true)), store: .metadataCalendar)
        XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(current)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .explicitPhotographerTracksRequired(self.calendarName))
        }
    }

    func testCurrentValidationChecksLiveCrossReferencesAndDuplicateIdentities() throws {
        let (job, profile, state) = fixture()
        let current = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: encode([job], iso: true),
            "server-profiles-v1.json": encode([profile]), calendarName: encode(state, calendar: true)]).stores
        var changed = current
        changed["server-profiles-v1.json"] = currentEnvelope(Data("[]".utf8), store: .serverProfiles)
        XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(changed)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .invalidReference("job server profile"))
        }
        changed = current
        changed[jobsName] = currentEnvelope(try encode([job, job], iso: true), store: .jobs)
        XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(changed)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .duplicateIdentity("jobs"))
        }
        changed = current
        var brokenCalendar = state
        brokenCalendar.bindings[0].accountID = UUID()
        changed[calendarName] = currentEnvelope(try encode(brokenCalendar, calendar: true), store: .metadataCalendar)
        XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(changed))
    }

    func testCurrentValidationRetainsHistoricalAndDetachedReferences() throws {
        let (_, _, state) = fixture()
        let deletedID = state.bindings[0].jobID
        let failure = SyncFailureRecord(jobID: deletedID, message: "{historical literal}")
        let event = MetadataSyncEvent(jobID: deletedID, operation: "Old event", detail: "{retained}")
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [calendarName: encode(state, calendar: true),
            "sync-errors-v1.json": encode([failure], iso: true), "metadata-sync-events-v1.json": encode([event])])
        let current = try Version3JSONStoreConversion.validateCurrentStores(converted.stores)
        XCTAssertEqual(current.summary.calendarBindingJobIDsWithoutCurrentJob, [deletedID])
        XCTAssertEqual(current.summary.historicalJobIDsWithoutCurrentJob, converted.summary.historicalJobIDsWithoutCurrentJob)
    }

    func testCurrentValidationChecksPendingReceiptPhaseAndInstalledIdentity() throws {
        let (source, profile, initial) = fixture()
        var duplicate = source
        duplicate.id = UUID()
        duplicate.isEnabled = false
        duplicate.startsOnAppLaunch = false
        var state = initial
        state.bindings = []
        state.pendingReceive = MetadataCalendarReceiveProposal(accountID: state.accounts[0].id, source: source,
            duplicate: duplicate, calendar: initial.bindings[0].snapshot)
        var current = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [jobsName: encode([source], iso: true),
            "server-profiles-v1.json": encode([profile]), calendarName: encode(state, calendar: true)]).stores
        XCTAssertEqual(try Version3JSONStoreConversion.validateCurrentStores(current).summary.pendingReceiptPhase, .beforeInstallation)
        var paused = source
        paused.isEnabled = false
        paused.startsOnAppLaunch = false
        current[jobsName] = currentEnvelope(try encode([paused, duplicate], iso: true), store: .jobs)
        XCTAssertEqual(try Version3JSONStoreConversion.validateCurrentStores(current).summary.pendingReceiptPhase, .jobsInstalled)
        duplicate.name = "Unexpected installed copy"
        current[jobsName] = currentEnvelope(try encode([paused, duplicate], iso: true), store: .jobs)
        XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(current)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .invalidPendingReceipt)
        }
    }

    func testCurrentValidationRejectsCalendarDatesThatWouldTrapOnLaterSave() throws {
        let (_, _, state) = fixture()
        var current = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [calendarName: encode(state, calendar: true)]).stores
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(state, calendar: true)) as? [String: Any])
        var bindings = try XCTUnwrap(object["bindings"] as? [[String: Any]])
        var snapshot = try XCTUnwrap(bindings[0]["snapshot"] as? [String: Any])
        var document = try XCTUnwrap(snapshot["document"] as? [String: Any])
        var clips = try XCTUnwrap(document["clips"] as? [[String: Any]])
        clips[0]["startsAt"] = 1e50
        document["clips"] = clips
        snapshot["document"] = document
        bindings[0]["snapshot"] = snapshot
        object["bindings"] = bindings
        current[calendarName] = currentEnvelope(try JSONSerialization.data(withJSONObject: object), store: .metadataCalendar)
        XCTAssertThrowsError(try Version3JSONStoreConversion.validateCurrentStores(current)) {
            XCTAssertEqual($0 as? Version3JSONStoreConversion.ConversionError, .invalidRecord("calendar date"))
        }
    }
}
