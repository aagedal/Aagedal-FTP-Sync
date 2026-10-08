import Foundation
import Testing
@testable import MetadataTemplates

private func activationContext(city: String? = "Oslo") -> MetadataTemplateContext {
    MetadataTemplateContext(
        processingDate: Date(timeIntervalSince1970: 0), processingTimeZone: TimeZone(secondsFromGMT: 0)!,
        photographer: "Renée {gps:country}", city: city
    )
}

private func decodeValue<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Test(arguments: ["{photographer}", "{{gps:city}}", "unmatched {", "{unsupported}", "} {{ 🎞️"])
func legacyTextNeverActivatesFromBraces(source: String) throws {
    let literal = MetadataTemplateText.literal(source)
    let decoded = try JSONDecoder().decode(MetadataTemplateText.self, from: JSONEncoder().encode(literal))
    #expect(decoded == literal)
    #expect(decoded.templateVersion == nil)
    #expect(decoded.requiredVariables.isEmpty)
    #expect(decoded.resolve(using: activationContext()) == .resolved(source))
    #expect(try MetadataTemplateText(source: source, templateVersion: nil) == literal)
}

@Test func literalsBypassTemplateSafetyBoundsAndKeywordNormalization() throws {
    let source = [" {gps:city} ", "", "\n", "OSLO", "oslo", "unmatched {", "é", "e\u{301}"]
    let literal = MetadataTemplateKeywords.literal(source)
    let decoded = try JSONDecoder().decode(MetadataTemplateKeywords.self, from: JSONEncoder().encode(literal))
    #expect(decoded == literal)
    #expect(decoded.requiredVariables.isEmpty)
    #expect(decoded.resolve(using: activationContext()) == .resolved(source))
    #expect(try MetadataTemplateKeywords(source: source, templateVersion: nil) == literal)
    let longText = String(repeating: "x", count: MetadataTemplate.maximumSourceUTF8Bytes + 1)
    #expect(MetadataTemplateText.literal(longText).resolve(using: activationContext()) == .resolved(longText))
    let manyKeywords = Array(repeating: "x", count: MetadataTemplate.maximumKeywordEntries + 1)
    #expect(MetadataTemplateKeywords.literal(manyKeywords).resolve(using: activationContext()) == .resolved(manyKeywords))
}

@Test(arguments: ["null", "true", "false", "0", "-1", "2", "999999", "1.5", "\"1\"", "[]", "{}"])
func malformedOrUnsupportedActivationMarkersReject(marker: String) {
    #expect(throws: (any Error).self) {
        try decodeValue(MetadataTemplateText.self, "{\"source\":\"text\",\"templateVersion\":\(marker)}")
    }
    #expect(throws: (any Error).self) {
        try decodeValue(MetadataTemplateKeywords.self, "{\"source\":[\"text\"],\"templateVersion\":\(marker)}")
    }
}

@Test(arguments: [
    "{}", "null", "[]", "\"plain text\"", "{\"templateVersion\":1}",
    "{\"source\":null}", "{\"source\":true}", "{\"source\":42}",
    "{\"source\":\"text\",\"templateVersions\":1}",
    "{\"source\":[\"text\"],\"templateVersions\":1}",
]) func malformedCoreEnvelopesReject(json: String) {
    #expect(throws: (any Error).self) { try decodeValue(MetadataTemplateText.self, json) }
    #expect(throws: (any Error).self) { try decodeValue(MetadataTemplateKeywords.self, json) }
}

@Test func sourceShapeAndArrayEntriesAreStrict() {
    #expect(throws: (any Error).self) { try decodeValue(MetadataTemplateText.self, #"{"source":["text"]}"#) }
    for json in [#"{"source":"text"}"#, #"{"source":["text",null]}"#, #"{"source":["text",1]}"#] {
        #expect(throws: (any Error).self) { try decodeValue(MetadataTemplateKeywords.self, json) }
    }
}

@Test func activeSourceRoundTripDoesNotPersistResolvedSample() throws {
    let source = "e\u{301} / 東京 / {{gps:city}} / {photographer} / {date:YYYY-MM-DD}"
    let active = try MetadataTemplateText.activated(source)
    let data = try JSONEncoder().encode(active)
    let shape = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(shape.keys) == ["source", "templateVersion"])
    let decoded = try JSONDecoder().decode(MetadataTemplateText.self, from: data)
    #expect(decoded == active)
    #expect(Array(decoded.source.utf8) == Array(source.utf8))
    #expect(decoded.templateVersion == 1)
    #expect(decoded.requiredVariables == [.photographer, .processingDate])
    #expect(decoded.resolve(using: activationContext()) == .resolved("e\u{301} / 東京 / {gps:city} / Renée {gps:country} / 1970-01-01"))
    // Source equality alone cannot equate a literal and an activated record in a merge.
    #expect(active != MetadataTemplateText.literal(source))
}

@Test func literalEncodingOmitsMarkerRatherThanWritingNull() throws {
    let data = try JSONEncoder().encode(MetadataTemplateText.literal("{photographer}"))
    let shape = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(shape.keys) == ["source"])
    let keywordsData = try JSONEncoder().encode(MetadataTemplateKeywords.literal(["{photographer}"]))
    let keywordsShape = try #require(JSONSerialization.jsonObject(with: keywordsData) as? [String: Any])
    #expect(Set(keywordsShape.keys) == ["source"])
}

@Test func activatedFieldsKeepExistingMetadataWhenDependencyIsMissing() throws {
    let text = try MetadataTemplateText.activated("Photo in {gps:city} by {photographer}")
    #expect(text.resolve(using: activationContext(city: nil)) == .preserveExisting(.missingValues([.city])))
    let source = ["Sports", "{gps:city}", "{photographer}", " OSLO ", ""]
    let keywords = try MetadataTemplateKeywords.activated(source)
    #expect(keywords.requiredVariables == [.city, .photographer])
    #expect(keywords.resolve(using: activationContext(city: nil)) == .preserveExisting(.missingValues([.city])))
    #expect(keywords.resolve(using: activationContext()) == .resolved(["Sports", "Oslo", "Renée {gps:country}"]))
    let decoded = try JSONDecoder().decode(MetadataTemplateKeywords.self, from: JSONEncoder().encode(keywords))
    #expect(decoded == keywords)
    #expect(decoded.source == source)
    #expect(decoded.templateVersion == 1)
    #expect(decoded != MetadataTemplateKeywords.literal(source))
}

@Test func invalidReplacementCannotPartiallyChangeCommittedPair() throws {
    var text = try MetadataTemplateText.activated("Photo: {photographer}")
    let previous = text
    #expect(throws: MetadataTemplateParseError.unmatchedOpeningBrace(utf8Offset: 0)) {
        text = try MetadataTemplateText.activated("{")
    }
    #expect(text == previous)
    var keywords = try MetadataTemplateKeywords.activated(["{gps:city}"])
    let previousKeywords = keywords
    #expect(throws: MetadataTemplateParseError.unknownToken("unknown", utf8Offset: 0)) {
        keywords = try MetadataTemplateKeywords.activated(["valid replacement", "{unknown}"])
    }
    #expect(keywords == previousKeywords)
    #expect(throws: MetadataTemplateActivationError.unsupportedVersion(2)) {
        text = try MetadataTemplateText(source: "replacement", templateVersion: 2)
    }
    #expect(text == previous)
    #expect(throws: (any Error).self) {
        text = try decodeValue(MetadataTemplateText.self, #"{"source":"replacement","templateVersion":null}"#)
    }
    #expect(text == previous)
}

@Test func activatedDecodingValidatesSyntaxAndKeywordBounds() throws {
    #expect(throws: MetadataTemplateParseError.unknownToken("unknown", utf8Offset: 0)) {
        try decodeValue(MetadataTemplateText.self, #"{"source":"{unknown}","templateVersion":1}"#)
    }
    #expect(throws: MetadataTemplateParseError.unmatchedOpeningBrace(utf8Offset: 0)) {
        try decodeValue(MetadataTemplateKeywords.self, #"{"source":["literal","{"],"templateVersion":1}"#)
    }
    let many = Array(repeating: "x", count: MetadataTemplate.maximumKeywordEntries + 1)
    #expect(throws: MetadataTemplateActivationError.keywordEntryLimitExceeded(maxEntries: MetadataTemplate.maximumKeywordEntries)) {
        try MetadataTemplateKeywords.activated(many)
    }
    let long = String(repeating: "x", count: MetadataTemplate.maximumSourceUTF8Bytes + 1)
    #expect(throws: MetadataTemplateParseError.sourceLimitExceeded(maxUTF8Bytes: MetadataTemplate.maximumSourceUTF8Bytes)) {
        try MetadataTemplateText.activated(long)
    }
}
