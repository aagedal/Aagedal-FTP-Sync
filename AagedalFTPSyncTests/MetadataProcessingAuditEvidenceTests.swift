import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class MetadataProcessingAuditEvidenceTests: XCTestCase {
    private func result(capture: MetadataCaptureDate? = nil,
                        fields: [MetadataWritableField: MetadataProcessingFieldOutcome] = [.headline: .proposed]) -> MetadataProcessingResult {
        MetadataProcessingResult(
            changes: ResolvedMetadataChanges(headline: "PRIVATE-RESOLVED-HEADLINE", description: "", keywords: [],
                creator: "PRIVATE-CREATOR", copyright: "", gpsPosition: nil, existingFieldPolicy: .overwrite),
            context: MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: 123_456),
                processingTimeZone: TimeZone(identifier: "Europe/Oslo")!, captureDate: capture,
                photographer: "PRIVATE-PHOTOGRAPHER", city: "PRIVATE-CITY", country: "PRIVATE-COUNTRY", persons: ["PRIVATE-PERSON"]),
            fields: fields)
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
}
