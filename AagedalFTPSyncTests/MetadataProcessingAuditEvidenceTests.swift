import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class MetadataProcessingAuditEvidenceTests: XCTestCase {
    private func result(capture: MetadataCaptureDate? = nil,
                        coordinates: EffectiveMetadataCoordinates.Resolution? = nil,
                        fields: [MetadataWritableField: MetadataProcessingFieldOutcome] = [.headline: .proposed]) -> MetadataProcessingResult {
        MetadataProcessingResult(
            changes: ResolvedMetadataChanges(headline: "PRIVATE-RESOLVED-HEADLINE", description: "", keywords: [],
                creator: "PRIVATE-CREATOR", copyright: "", gpsPosition: nil, existingFieldPolicy: .overwrite),
            context: MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: 123_456),
                processingTimeZone: TimeZone(identifier: "Europe/Oslo")!, captureDate: capture,
                photographer: "PRIVATE-PHOTOGRAPHER", city: "PRIVATE-CITY", country: "PRIVATE-COUNTRY", persons: ["PRIVATE-PERSON"]),
            fields: fields, coordinateResolution: coordinates)
    }

    private func entry(evidence: MetadataProcessingAuditEvidence? = nil) -> MetadataAuditEntry {
        MetadataAuditEntry(runID: UUID(), jobID: UUID(), occurredAt: Date(timeIntervalSince1970: 42),
            operation: .transfer, relativePath: "fixture.jpg", status: .applied,
            timestampPolicy: .sourceModification, scheduledAt: nil, processingEvidence: evidence)
    }

    func testLegacyEntryWithoutEvidenceDecodesAndReencodesWithOldShape() throws {
        let old = entry()
        let data = try JSONEncoder().encode(old)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["processingEvidence"])
        XCTAssertEqual(try JSONDecoder().decode(MetadataAuditEntry.self, from: data), old)
        let resolved = result()
        let literal = MetadataProcessingResult(changes: resolved.changes, context: nil, fields: resolved.fields)
        XCTAssertNil(MetadataProcessingAuditEvidence(result: literal))
    }

    func testFrozenContextAndExplicitOffsetRoundTripWithoutPrivateValues() throws {
        let capture = try XCTUnwrap(MetadataCaptureDate(date: Date(timeIntervalSince1970: 100), zoneSource: .explicitOffset(secondsFromGMT: -18_000)))
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(capture: capture)))
        XCTAssertEqual(evidence.processingDate, Date(timeIntervalSince1970: 123_456))
        XCTAssertEqual(evidence.processingTimeZoneIdentifier, "Europe/Oslo")
        XCTAssertEqual(evidence.captureAssumption?.source, .explicitOffset)
        XCTAssertEqual(evidence.captureAssumption?.secondsFromGMT, -18_000)
        XCTAssertTrue(evidence.resolutionComplete)
        let original = entry(evidence: evidence)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bytes = try encoder.encode(original)
        XCTAssertEqual(try decoder.decode(MetadataAuditEntry.self, from: bytes), original)
        XCTAssertFalse(try XCTUnwrap(String(data: bytes, encoding: .utf8)).contains("PRIVATE-"))
    }

    func testPersistedFallbackIsDistinguishedFromExplicitOffsetAndMissingCapture() throws {
        let capture = try XCTUnwrap(MetadataCaptureDate(date: Date(timeIntervalSince1970: 100), zoneSource: .persistedFallback(identifier: "America/New_York")))
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(capture: capture)))
        XCTAssertEqual(evidence.captureAssumption?.source, .persistedFallback)
        XCTAssertEqual(evidence.captureAssumption?.timeZoneIdentifier, "America/New_York")
        XCTAssertNil(evidence.captureAssumption?.secondsFromGMT)
        XCTAssertNil(MetadataProcessingAuditEvidence(result: result())?.captureAssumption)
    }

    func testOmissionsUseStableSpecificReasonsAndSortedDependencyNames() throws {
        let omissions: [MetadataWritableField: MetadataProcessingFieldOutcome] = [
            .headline: .omitted(.template(.missingValues([.persons, .city]))),
            .description: .omitted(.template(.invalidDate(.captureDate))),
            .keywords: .omitted(.template(.keywordEntryLimitExceeded(maxEntries: 1024))),
            .copyright: .omitted(.writerByteLimit(maximum: 128)),
            .creator: .omitted(.invalidXMLCharacter),
            .gpsPosition: .omitted(.template(.outputLimitExceeded(maxUTF8Bytes: 65_536)))
        ]
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(fields: omissions)))
        XCTAssertFalse(evidence.resolutionComplete)
        XCTAssertEqual(evidence.fields["headline"]?.variables, ["city", "persons"])
        XCTAssertEqual(evidence.fields["headline"]?.reason, .missingValues)
        XCTAssertEqual(evidence.fields["description"]?.reason, .invalidDate)
        XCTAssertEqual(evidence.fields["description"]?.variables, ["captureDate"])
        XCTAssertEqual(evidence.fields["keywords"]?.reason, .keywordEntryLimit)
        XCTAssertEqual(evidence.fields["keywords"]?.limit, 1024)
        XCTAssertEqual(evidence.fields["copyright"]?.reason, .writerByteLimit)
        XCTAssertEqual(evidence.fields["creator"]?.reason, .invalidXMLCharacter)
        XCTAssertEqual(evidence.fields["gpsPosition"]?.reason, .outputByteLimit)
        XCTAssertEqual(evidence.fields["gpsPosition"]?.limit, 65_536)
        XCTAssertTrue(evidence.fields.values.allSatisfy { $0.status == .omitted })
        XCTAssertEqual(try JSONDecoder().decode(MetadataProcessingAuditEvidence.self, from: JSONEncoder().encode(evidence)), evidence)
    }

    func testCoordinateEvidenceKeepsDecisionsWithoutNumericalLocations() throws {
        let resolution = EffectiveMetadataCoordinates.resolve(imageKind: .embedded,
            embeddedEXIF: .init(latitude: 63.1234567, longitude: 10.2345678),
            xmp: .init(latitude: 62.3456789, longitude: 11.4567890),
            scheduled: .init(latitude: .nan, longitude: 9), policy: .overwrite)
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(coordinates: resolution,
            fields: [.gpsPosition: .omitted(.invalidGPSPosition)])))
        let decision = try XCTUnwrap(evidence.coordinateDecision)
        XCTAssertEqual(decision.selectedSource, .embeddedEXIF)
        XCTAssertTrue(decision.existingConflict)
        XCTAssertEqual(decision.invalidSources, [.scheduled])
        XCTAssertEqual(decision.scheduledDisposition, .invalid)
        XCTAssertFalse(evidence.resolutionComplete)
        XCTAssertEqual(evidence.fields["gpsPosition"]?.reason, .invalidGPSPosition)
        let bytes = try JSONEncoder().encode(evidence)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for forbidden in ["latitude", "longitude", "63.1234567", "10.2345678", "62.3456789", "11.456789"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertEqual(try JSONDecoder().decode(MetadataProcessingAuditEvidence.self, from: bytes), evidence)
        let description = MetadataAuditEvidencePresentation.coordinateDecision(decision)
        XCTAssertTrue(description.contains("disagree"))
        XCTAssertTrue(description.contains("Invalid scheduled location"))
        XCTAssertEqual(MetadataAuditEvidencePresentation.fieldOutcome(try XCTUnwrap(evidence.fields["gpsPosition"])),
                       "Omitted; invalid scheduled GPS position")
    }

    func testPreviousEvidenceWithoutCoordinateDecisionReencodesUnchanged() throws {
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result()))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(evidence)
        XCTAssertFalse(try XCTUnwrap(String(data: bytes, encoding: .utf8)).contains("coordinateDecision"))
        let decoded = try JSONDecoder().decode(MetadataProcessingAuditEvidence.self, from: bytes)
        XCTAssertNil(decoded.coordinateDecision)
        XCTAssertEqual(try encoder.encode(decoded), bytes)
    }

    func testScheduledDispositionEvidenceMatchesPolicyDecisions() throws {
        for (existing, policy, expected) in [
            (Optional<EffectiveMetadataCoordinates.Candidate>.none, MetadataExistingFieldPolicy.fillEmpty, MetadataProcessingAuditEvidence.CoordinateDecision.ScheduledDisposition.filledEmpty),
            (Optional(.init(latitude: 1, longitude: 2)), .fillEmpty, .preservedExisting),
            (Optional(.init(latitude: 1, longitude: 2)), .overwrite, .overwroteExisting)
        ] {
            let resolution = EffectiveMetadataCoordinates.resolve(imageKind: .embedded, embeddedEXIF: existing,
                scheduled: .init(latitude: 3, longitude: 4), policy: policy)
            let decision = MetadataProcessingAuditEvidence.CoordinateDecision(resolution)
            XCTAssertEqual(decision.scheduledDisposition, expected)
            XCTAssertFalse(decision.existingConflict)
        }
    }

    func testGeocodingAuditRecordsLocaleProviderAndFieldOutcomesWithoutPlaceNames() throws {
        let base = result()
        let processing = MetadataProcessingResult(changes: .init(), context: base.context, fields: [:],
            geocoding: .lookup(.found(.init(city: "PRIVATE-CITY", country: "PRIVATE-COUNTRY", source: "PRIVATE-LOOKUP-TEXT", distanceMeters: 1234), OfflineMetadataGeocodingProvider.identity)),
            geocodingLocaleIdentifier: "nb", places: [.city: .preservedByPolicy, .country: .proposed])
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: processing))
        XCTAssertEqual(evidence.geocodingDecision?.localeIdentifier, "nb")
        XCTAssertEqual(evidence.geocodingDecision?.provider, "geonames-offline")
        XCTAssertEqual(evidence.geocodingDecision?.distanceMeters, 1234)
        XCTAssertEqual(evidence.placeFields?["city"]?.status, .preservedByPolicy)
        XCTAssertEqual(evidence.placeFields?["country"]?.status, .proposed)
        let bytes = try JSONEncoder().encode(evidence)
        XCTAssertFalse(try XCTUnwrap(String(data: bytes, encoding: .utf8)).contains("PRIVATE-"))
        XCTAssertEqual(try JSONDecoder().decode(MetadataProcessingAuditEvidence.self, from: bytes), evidence)
        XCTAssertTrue(MetadataAuditEvidencePresentation.geocodingDecision(try XCTUnwrap(evidence.geocodingDecision)).contains("field proposals"))
    }

    func testMissingPlaceLookupIsIncompleteWithSpecificAuditReason() throws {
        let base = result()
        let processing = MetadataProcessingResult(changes: .init(), context: base.context, fields: [:],
            geocoding: .missingCoordinates, geocodingLocaleIdentifier: "en", places: [.city: .unavailable])
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: processing))
        XCTAssertFalse(evidence.resolutionComplete)
        XCTAssertEqual(evidence.geocodingDecision?.status, .missingCoordinates)
        XCTAssertEqual(evidence.placeFields?["city"]?.reason, .missingValues)
        XCTAssertEqual(evidence.placeFields?["city"]?.variables, ["city"])
    }

    func testPolicyPreservationAndEmptyFieldsAreCompleteResolutionNotPublication() throws {
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(fields: [
            .headline: .preservedByPolicy, .description: .notRequested, .copyright: .proposed
        ])))
        XCTAssertTrue(evidence.resolutionComplete)
        XCTAssertEqual(evidence.fields["headline"]?.status, .preservedByPolicy)
        XCTAssertEqual(evidence.fields["description"]?.status, .notRequested)
        XCTAssertEqual(evidence.fields["copyright"]?.status, .proposed)
        XCTAssertTrue(evidence.fields.values.allSatisfy { $0.reason == nil && $0.variables.isEmpty && $0.limit == nil })
    }

    func testAuditPresentationUsesRecordedZoneAndDistinguishesCaptureAssumption() throws {
        let fallback = try XCTUnwrap(MetadataCaptureDate(date: Date(timeIntervalSince1970: 100),
            zoneSource: .persistedFallback(identifier: "America/New_York")))
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(capture: fallback)))
        XCTAssertEqual(MetadataAuditEvidencePresentation.processingTime(evidence),
                       "Processing time: 1970-01-02 11:17:36 (Europe/Oslo)")
        XCTAssertEqual(MetadataAuditEvidencePresentation.captureAssumption(evidence),
                       "Original capture had no offset; assumed saved job zone: America/New_York.")
        let explicit = try XCTUnwrap(MetadataCaptureDate(date: Date(timeIntervalSince1970: 100),
            zoneSource: .explicitOffset(secondsFromGMT: -18_000)))
        let explicitEvidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(capture: explicit)))
        XCTAssertTrue(MetadataAuditEvidencePresentation.captureAssumption(explicitEvidence).contains("recorded offset"))
        XCTAssertFalse(MetadataAuditEvidencePresentation.captureAssumption(explicitEvidence).contains("assumed"))
    }

    func testAuditPresentationCannotMistakeProposalForPublicationOrExposeResolvedText() throws {
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result(fields: [
            .headline: .proposed, .keywords: .omitted(.template(.missingValues([.persons, .city])))
        ])))
        let proposal = MetadataAuditEvidencePresentation.fieldOutcome(try XCTUnwrap(evidence.fields["headline"]))
        XCTAssertTrue(proposal.contains("not proof of a successful write"))
        let omitted = MetadataAuditEvidencePresentation.fieldOutcome(try XCTUnwrap(evidence.fields["keywords"]))
        XCTAssertEqual(omitted, "Omitted; missing city, people shown")
        XCTAssertFalse((proposal + omitted).contains("PRIVATE-"))
    }

    func testUnavailableRecordedZoneDisplaysExplicitUTCFallback() throws {
        let evidence = try XCTUnwrap(MetadataProcessingAuditEvidence(result: result()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        object["processingTimeZoneIdentifier"] = "Unknown/FutureZone"
        let restored = try JSONDecoder().decode(MetadataProcessingAuditEvidence.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(MetadataAuditEvidencePresentation.processingTime(restored),
            "Processing time: 1970-01-02 10:17:36 (UTC; recorded zone is unavailable: Unknown/FutureZone)")
    }
}
