import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class PersistedTemplateActivationTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    private func profile() -> PhotographerProfile {
        PhotographerProfile(id: UUID(uuidString: "ABCDEFAB-1234-5678-9012-ABCDEFABCDEF")!, name: "Name {literal}",
            filenamePrefix: "EX", creator: "Creator {gps:city}", copyrightNotice: "Copyright {literal")
    }
    private func activeFields() throws -> ScheduledMetadataFields {
        var fields = ScheduledMetadataFields()
        fields.setHeadline(try .activated("{gps:city}"))
        fields.setDescription(try .activated("{photographer} — {date:YYYY-MM-DD}"))
        fields.setKeywords(try .activated([" {persons} ", "", "Oslo", "OSLO", "é", "e\u{301}", "{{literal}}", "Doe, Jane"]))
        return fields
    }
    private func decodedFields(marker: String, headline: String = "headline") throws -> ScheduledMetadataFields {
        let raw = "{\"headline\":\"\(headline)\",\"description\":\"description\",\"keywords\":[],\"templateVersions\":\(marker)}"
        return try JSONDecoder().decode(ScheduledMetadataFields.self, from: Data(raw.utf8))
    }
    private func assertRecordError(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertTrue($0 is MetadataTemplateRecordError, "Marker errors must not be eligible for literal backup fallback", file: file, line: line)
        }
    }

    func testLiteralRecordsRetainLegacyShapeBytesAndNeverActivateBraces() throws {
        struct LegacyFields: Encodable { let headline: String; let description: String; let keywords: [String] }
        struct LegacyProfile: Encodable {
            let id: UUID; let name: String; let filenamePrefix: String; let creator: String; let copyrightNotice: String
            let workHours: PhotographerWorkHours?; let workHourOverrides: [PhotographerWorkHoursOverride]?
        }
        let fields = ScheduledMetadataFields(headline: "{gps:city}", description: "unmatched {", keywords: [" {persons} ", "", "OSLO", "oslo"])
        let previous = LegacyFields(headline: fields.headline, description: fields.description, keywords: fields.keywords)
        XCTAssertEqual(try encoder().encode(fields), try encoder().encode(previous))
        let photographer = profile()
        let legacy = LegacyProfile(id: photographer.id, name: photographer.name, filenamePrefix: photographer.filenamePrefix,
            creator: photographer.creator, copyrightNotice: photographer.copyrightNotice, workHours: photographer.workHours,
            workHourOverrides: photographer.workHourOverrides)
        XCTAssertEqual(try encoder().encode(photographer), try encoder().encode(legacy))
        let decoded = try JSONDecoder().decode(ScheduledMetadataFields.self, from: encoder().encode(fields))
        XCTAssertFalse(decoded.hasActivatedTemplates)
        XCTAssertEqual(try decoded.validatedHeadline, .literal(fields.headline))
        XCTAssertEqual(try decoded.validatedDescription, .literal(fields.description))
        XCTAssertEqual(try decoded.validatedKeywords.source, fields.keywords)
        XCTAssertFalse(photographer.hasActivatedTemplates)
        XCTAssertEqual(try photographer.validatedCopyright, .literal(photographer.copyrightNotice))
    }

    func testSupportedActivationRoundTripsAndParticipatesInEqualityAndHashing() throws {
        let fields = try activeFields()
        let bytes = try encoder().encode(fields)
        let decoded = try JSONDecoder().decode(ScheduledMetadataFields.self, from: bytes)
        XCTAssertEqual(decoded, fields)
        XCTAssertTrue(decoded.hasActivatedTemplates)
        XCTAssertEqual(decoded.templateVersions, ["headline": 1, "description": 1, "keywords": 1])
        XCTAssertEqual(try decoded.validatedKeywords.source, fields.keywords)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["templateVersions"] as? [String: Int], fields.templateVersions)
        var photographer = profile()
        photographer.setCopyright(try .activated("© {date:YYYY-MM-DD} {photographer}"))
        let copy = try JSONDecoder().decode(PhotographerProfile.self, from: encoder().encode(photographer))
        XCTAssertEqual(copy, photographer)
        XCTAssertEqual(copy.copyrightTemplateVersion, 1)
        XCTAssertEqual(copy.creator, "Creator {gps:city}")
        let literal = ScheduledMetadataFields(headline: fields.headline, description: fields.description, keywords: fields.keywords)
        XCTAssertNotEqual(fields, literal)
        XCTAssertEqual(Set([fields, literal]).count, 2)
    }

    func testMalformedUnknownNullAndFutureFieldMarkersFailWithNonRecoverableRecordErrors() throws {
        for marker in ["null", "true", "[]", "1", "\"1\"", "{\"headline\":null}", "{\"headline\":true}",
                       "{\"headline\":\"1\"}", "{\"headline\":0}", "{\"headline\":2}", "{\"creator\":1}", "{\"Headline\":1}"] {
            assertRecordError { _ = try self.decodedFields(marker: marker) }
        }
        assertRecordError { _ = try self.decodedFields(marker: "{\"headline\":1}", headline: "{unknown}") }
        assertRecordError {
            _ = try JSONDecoder().decode(ScheduledMetadataFields.self,
                from: Data("{\"headline\":null,\"description\":\"\",\"keywords\":[],\"templateVersions\":{\"headline\":1}}".utf8))
        }
        let empty = try decodedFields(marker: "{}", headline: "unclosed {")
        XCTAssertFalse(empty.hasActivatedTemplates)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(empty)) as? [String: Any])
        XCTAssertNil(object["templateVersions"])
    }

    func testCopyrightMarkersAndMalformedMarkedBodiesNeverDecodeAsLiterals() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(profile())) as? [String: Any])
        let markers: [Any] = [NSNull(), true, "1", 0, 2, [], ["value": 1]]
        for marker in markers {
            var object = original
            object["copyrightTemplateVersion"] = marker
            assertRecordError { _ = try JSONDecoder().decode(PhotographerProfile.self, from: JSONSerialization.data(withJSONObject: object)) }
        }
        var invalid = original
        invalid["copyrightTemplateVersion"] = 1
        invalid["copyrightNotice"] = "{unknown}"
        assertRecordError { _ = try JSONDecoder().decode(PhotographerProfile.self, from: JSONSerialization.data(withJSONObject: invalid)) }
        invalid["copyrightNotice"] = "{photographer}"
        invalid["id"] = "invalid UUID"
        assertRecordError { _ = try JSONDecoder().decode(PhotographerProfile.self, from: JSONSerialization.data(withJSONObject: invalid)) }
    }

    func testValidatedEditsRetainPreviousPairsOnFailureAndExplicitLiteralConversionRemovesOnlyItsMarker() throws {
        var fields = try activeFields()
        let before = fields
        assertRecordError { try fields.replaceHeadlineSource("broken {") }
        assertRecordError { try fields.replaceDescriptionSource("{unsupported}") }
        assertRecordError { try fields.replaceKeywordsSource(["{persons}", "broken {"]) }
        XCTAssertEqual(fields, before)
        try fields.replaceHeadlineSource("In {gps:country}")
        XCTAssertEqual(fields.templateVersions["headline"], 1)
        fields.setHeadline(.literal("unclosed {"))
        XCTAssertNil(fields.templateVersions["headline"])
        XCTAssertEqual(fields.templateVersions["keywords"], 1)
        XCTAssertEqual(fields.description, before.description)
        var photographer = profile()
        photographer.setCopyright(try .activated("{photographer}"))
        let priorProfile = photographer
        assertRecordError { try photographer.replaceCopyrightSource("{unknown}") }
        XCTAssertEqual(photographer, priorProfile)
        photographer.setCopyright(.literal("unclosed {"))
        XCTAssertNil(photographer.copyrightTemplateVersion)
        XCTAssertEqual(photographer.copyrightNotice, "unclosed {")
    }

    func testDirectInvalidActiveDraftMutationsAndRawPairCopiesAreRejectedAtEncode() throws {
        var fields = try activeFields()
        fields.headline = "unclosed {"
        assertRecordError { _ = try self.encoder().encode(fields) }
        var copied = ScheduledMetadataFields()
        copied.copyingHeadline(from: fields)
        XCTAssertEqual(copied.headline, fields.headline)
        XCTAssertEqual(copied.templateVersions["headline"], 1)
        assertRecordError { _ = try self.encoder().encode(copied) }
        var photographer = profile()
        photographer.setCopyright(try .activated("{photographer}"))
        photographer.copyrightNotice = "{unknown}"
        var other = profile()
        other.copyingCopyright(from: photographer)
        XCTAssertEqual(other.copyrightTemplateVersion, 1)
        assertRecordError { _ = try self.encoder().encode(other) }
    }

    func testActiveKeywordSourceSurvivesNormalizationPresetApplicationAndTimelineCopies() throws {
        let fields = try activeFields()
        let preset = MetadataPreset(name: "  Source preset  ", fields: fields)
        let normalized = preset.normalized()
        XCTAssertEqual(normalized.name, "Source preset")
        XCTAssertEqual(normalized.fields.keywords, fields.keywords)
        XCTAssertEqual(normalized.fields.templateVersions, fields.templateVersions)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clip = MetadataScheduleClip(photographerID: profile().id, name: "Original", startsAt: start, endsAt: start.addingTimeInterval(60))
            .applying(normalized)
        let copies = MetadataTimelineEditing.copies(of: [clip], anchoredAt: start.addingTimeInterval(3600), on: nil)
        XCTAssertEqual(copies.first?.fields, fields)
        var copied = ScheduledMetadataFields()
        copied.copyingHeadline(from: fields)
        copied.copyingDescription(from: fields)
        copied.copyingKeywords(from: fields)
        XCTAssertEqual(copied, fields)
        let legacy = MetadataPreset(name: "Literal", fields: ScheduledMetadataFields(keywords: [" Oslo ", "OSLO", "", "Doe, Jane"]))
        XCTAssertEqual(legacy.normalized().fields.keywords, ["Oslo", "Doe, Jane"])
    }

    func testActivationAggregateFindsDisabledNestedCopiesAndLanguageBoundsRemainStrict() throws {
        var photographer = profile()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clip = try MetadataScheduleClip(photographerID: photographer.id, name: "Active clip", startsAt: start,
            endsAt: start.addingTimeInterval(60), fields: activeFields())
        XCTAssertTrue(MetadataAutomation(photographers: [photographer], photographerTracks: [], clips: [clip]).hasActivatedTemplates)
        photographer.setCopyright(try .activated("{photographer}"))
        XCTAssertTrue(MetadataAutomation(photographers: [photographer], photographerTracks: [], clips: []).hasActivatedTemplates)
        XCTAssertTrue(try MetadataPreset(name: "Active", fields: activeFields()).hasActivatedTemplates)
        var object: [String: Any] = ["headline": String(repeating: "x", count: MetadataTemplate.maximumSourceUTF8Bytes + 1),
            "description": "", "keywords": [], "templateVersions": ["headline": 1]]
        assertRecordError { _ = try JSONDecoder().decode(ScheduledMetadataFields.self, from: JSONSerialization.data(withJSONObject: object)) }
        object["headline"] = "literal"
        object["keywords"] = Array(repeating: "{persons}", count: MetadataTemplate.maximumKeywordEntries + 1)
        object["templateVersions"] = ["keywords": 1]
        assertRecordError { _ = try JSONDecoder().decode(ScheduledMetadataFields.self, from: JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "templateVersions")
        XCTAssertNoThrow(try JSONDecoder().decode(ScheduledMetadataFields.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
