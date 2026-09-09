import Foundation
import Testing
@testable import MetadataTemplates

private let utc = TimeZone(secondsFromGMT: 0)!

private func instant(_ iso8601: String) -> Date {
    ISO8601DateFormatter().date(from: iso8601)!
}

private func context(
    processingDate: Date = instant("2026-09-09T22:30:00Z"),
    processingTimeZone: TimeZone = utc,
    captureDate: MetadataCaptureDate? = nil,
    photographer: String? = "Truls Aagedal",
    city: String? = "Oslo",
    country: String? = "Norway",
    persons: [String]? = nil
) -> MetadataTemplateContext {
    MetadataTemplateContext(
        processingDate: processingDate, processingTimeZone: processingTimeZone,
        captureDate: captureDate, photographer: photographer, city: city, country: country, persons: persons
    )
}

@Test func documentedCaptionAndDependencies() throws {
    let source = "{gps:city}, {gps:country}, {dateCaptured:YYYY-MM-DD}. Photo: {photographer}."
    let template = try MetadataTemplate.parse(source)
    #expect(template.source == source)
    #expect(template.requiredVariables == [.city, .country, .captureDate, .photographer])
    let capture = MetadataCaptureDate(
        date: instant("2026-09-09T12:00:00Z"), zoneSource: .explicitOffset(secondsFromGMT: 7200)
    )!
    #expect(template.resolve(using: context(captureDate: capture)) == .resolved("Oslo, Norway, 2026-09-09. Photo: Truls Aagedal."))
}

@Test func repeatedAdjacentAndSinglePassSubstitutions() throws {
    let template = try MetadataTemplate.parse("{photographer}{gps:city}/{photographer}/{persons}")
    let values = context(photographer: "Æ {gps:country}", city: "東京", persons: ["Renée {photographer}", "王, 五"])
    #expect(template.resolve(using: values) == .resolved("Æ {gps:country}東京/Æ {gps:country}/Renée {photographer}, 王, 五"))
}

@Test(arguments: [
    ("", ""), ("ordinary text", "ordinary text"),
    ("{{photographer}}", "{photographer}"),
    ("{{{photographer}}}", "{Truls Aagedal}"),
    ("{{}}", "{}"), ("}} {{", "} {"),
    ("{{{{x}}}}", "{{x}}"), ("é🎞️{{東京}}", "é🎞️{東京}"),
]) func literalAndEscapedBraces(pair: (String, String)) throws {
    #expect(try MetadataTemplate.parse(pair.0).resolve(using: context()) == .resolved(pair.1))
}

@Test(arguments: [
    ("{", MetadataTemplateParseError.unmatchedOpeningBrace(utf8Offset: 0)),
    ("é{photographer", .unmatchedOpeningBrace(utf8Offset: 2)),
    ("a}", .unmatchedClosingBrace(utf8Offset: 1)),
    ("{a{b}", .nestedOpeningBrace(utf8Offset: 2)),
    ("{}", .unknownToken("", utf8Offset: 0)),
    ("{filename}", .unknownToken("filename", utf8Offset: 0)),
    ("{field:copyright}", .unknownToken("field:copyright", utf8Offset: 0)),
    ("{Photographer}", .unknownToken("Photographer", utf8Offset: 0)),
    ("{ photographer}", .unknownToken(" photographer", utf8Offset: 0)),
    ("{gps}", .unknownToken("gps", utf8Offset: 0)),
    ("{gps:City}", .unknownToken("gps:City", utf8Offset: 0)),
    ("{date}", .unsupportedDateFormat("date", utf8Offset: 0)),
    ("{dateCaptured}", .unsupportedDateFormat("dateCaptured", utf8Offset: 0)),
    ("{date:dd.MM.yyyy}", .unsupportedDateFormat("date:dd.MM.yyyy", utf8Offset: 0)),
    ("{date:YYYY-MM-dd}", .unsupportedDateFormat("date:YYYY-MM-dd", utf8Offset: 0)),
    ("{dateCaptured:}", .unsupportedDateFormat("dateCaptured:", utf8Offset: 0)),
]) func rejectsUnsupportedSyntax(pair: (String, MetadataTemplateParseError)) {
    #expect(throws: pair.1) { try MetadataTemplate.parse(pair.0) }
}

@Test func missingValuesPreserveWholeFieldAndReportAllDependencies() throws {
    let template = try MetadataTemplate.parse("Photo {photographer} in {gps:city}, {gps:country} on {dateCaptured:YYYY-MM-DD}; {persons}")
    let value = context(photographer: " \n", city: nil, country: "", persons: ["", " \n"])
    #expect(template.resolve(using: value) == .preserveExisting(.missingValues([.photographer, .city, .country, .captureDate, .persons])))
    #expect(try MetadataTemplate.parse("{date:YYYY-MM-DD}").resolve(using: value) == .resolved("2026-09-09"))
}

@Test func sourceBoundCountsUTF8AndAcceptsExactLimit() throws {
    let maximum = MetadataTemplate.maximumSourceUTF8Bytes
    let exact = String(repeating: "é", count: maximum / 2)
    #expect(try MetadataTemplate.parse(exact).resolve(using: context()) == .resolved(exact))
    #expect(throws: MetadataTemplateParseError.sourceLimitExceeded(maxUTF8Bytes: maximum)) {
        try MetadataTemplate.parse(exact + "a")
    }
}

@Test func outputBoundCountsUTF8AcrossRepeatedTokens() throws {
    let maximum = MetadataTemplate.maximumOutputUTF8Bytes
    let half = String(repeating: "é", count: maximum / 4)
    let values = context(photographer: half)
    #expect(try MetadataTemplate.parse("{photographer}{photographer}").resolve(using: values) == .resolved(half + half))
    #expect(try MetadataTemplate.parse("{photographer}{photographer}a").resolve(using: values) == .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: maximum)))
    #expect(try MetadataTemplate.parse("{photographer}").resolve(using: context(photographer: String(repeating: "a", count: maximum + 1))) == .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: maximum)))
}

@Test func personsBoundIncludesSeparators() throws {
    let maximum = MetadataTemplate.maximumOutputUTF8Bytes
    let template = try MetadataTemplate.parse("{persons}")
    let name = String(repeating: "a", count: maximum)
    #expect(template.resolve(using: context(persons: [name])) == .resolved(name))
    #expect(template.resolve(using: context(persons: [name, "b"])) == .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: maximum)))
    #expect(template.resolve(using: context(persons: ["", " \n", "A", "B"])) == .resolved("A, B"))
}

@Test(arguments: [
    "2019-12-30", "2020-01-01", "2020-12-31", "2021-01-01", "2024-02-29", "2026-09-09",
]) func calendarYearAndLeapDayUseBothAliases(day: String) throws {
    let date = instant(day + "T12:00:00Z")
    let capture = MetadataCaptureDate(date: date, zoneSource: .explicitOffset(secondsFromGMT: 0))!
    let values = context(processingDate: date, captureDate: capture)
    let template = try MetadataTemplate.parse("{date:YYYY-MM-DD}/{date:yyyy-MM-dd}/{dateCaptured:YYYY-MM-DD}/{dateCaptured:yyyy-MM-dd}")
    #expect(template.resolve(using: values) == .resolved(Array(repeating: day, count: 4).joined(separator: "/")))
}

@Test func explicitCaptureOffsetAndProcessingZoneAreIndependent() throws {
    let date = instant("2026-09-09T22:30:00Z")
    let capture = MetadataCaptureDate(date: date, zoneSource: .explicitOffset(secondsFromGMT: 3 * 3600))!
    let values = context(processingDate: date, processingTimeZone: TimeZone(secondsFromGMT: -5 * 3600)!, captureDate: capture)
    #expect(capture.zoneSource == .explicitOffset(secondsFromGMT: 10_800))
    #expect(try MetadataTemplate.parse("{date:YYYY-MM-DD}/{dateCaptured:YYYY-MM-DD}").resolve(using: values) == .resolved("2026-09-09/2026-09-10"))
}

@Test func persistedFallbackAndFrozenContextRemainStable() throws {
    let capture = MetadataCaptureDate(date: instant("2026-07-01T22:30:00Z"), zoneSource: .persistedFallback(identifier: "Europe/Oslo"))!
    #expect(capture.zoneSource == .persistedFallback(identifier: "Europe/Oslo"))
    let values = context(captureDate: capture)
    let template = try MetadataTemplate.parse("{date:YYYY-MM-DD}/{dateCaptured:YYYY-MM-DD}")
    let first = template.resolve(using: values)
    #expect(first == .resolved("2026-09-09/2026-07-02"))
    for _ in 0..<50 { #expect(template.resolve(using: values) == first) }
}

@Test func zoneValidationAndMissingCaptureNeverUseToday() throws {
    let date = instant("2026-09-09T12:00:00Z")
    #expect(MetadataCaptureDate(date: date, zoneSource: .persistedFallback(identifier: "invalid/zone")) == nil)
    #expect(MetadataCaptureDate(date: date, zoneSource: .explicitOffset(secondsFromGMT: 15 * 3600)) == nil)
    #expect(MetadataCaptureDate(date: date, zoneSource: .explicitOffset(secondsFromGMT: 1)) == nil)
    #expect(try MetadataTemplate.parse("{dateCaptured:YYYY-MM-DD}").resolve(using: context()) == .preserveExisting(.missingValues([.captureDate])))
}

@Test(arguments: [Double.infinity, -Double.infinity, Double.nan, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude])
func invalidDatesAreUnavailable(value: Double) throws {
    let date = Date(timeIntervalSinceReferenceDate: value)
    #expect(try MetadataTemplate.parse("{date:YYYY-MM-DD}").resolve(using: context(processingDate: date)) == .preserveExisting(.invalidDate(.processingDate)))
    let capture = MetadataCaptureDate(date: date, zoneSource: .explicitOffset(secondsFromGMT: 0))!
    #expect(try MetadataTemplate.parse("{dateCaptured:YYYY-MM-DD}").resolve(using: context(captureDate: capture)) == .preserveExisting(.invalidDate(.captureDate)))
    // Invalid unused context does not suppress a literal field.
    #expect(try MetadataTemplate.parse("literal").resolve(using: context(processingDate: date)) == .resolved("literal"))
}

@Test func unsupportedCalendarYearsAreUnavailable() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    for year in [0, 10_000] {
        let date = calendar.date(from: DateComponents(year: year, month: 6, day: 15))!
        #expect(try MetadataTemplate.parse("{date:YYYY-MM-DD}").resolve(using: context(processingDate: date)) == .preserveExisting(.invalidDate(.processingDate)))
    }
}

@Test func processingZoneIsSnapshotted() {
    let supplied = TimeZone.autoupdatingCurrent
    let value = context(processingTimeZone: supplied)
    #expect(value.processingTimeZone == TimeZone(identifier: supplied.identifier))
}

@Test func keywordsStayEntriesAndNormalizeAfterExpansion() throws {
    let templates = try [" {gps:city} ", "OSLO", "Renée", "renee", "{persons}", "", " \n", "{photographer}"].map(MetadataTemplate.parse)
    let values = context(photographer: "{gps:city}", persons: ["One", "Two"])
    #expect(MetadataTemplate.resolveKeywords(templates, using: values) == .resolved(["Oslo", "Renée", "One, Two", "{gps:city}"]))
}

@Test func keywordsPreserveEntireListIfAnyEntryMissing() throws {
    let templates = try ["Sports", "{gps:city}", "{persons}", "{gps:country}"].map(MetadataTemplate.parse)
    #expect(MetadataTemplate.resolveKeywords(templates, using: context(city: nil, persons: nil)) == .preserveExisting(.missingValues([.city, .persons])))
}

@Test func keywordCountAndAggregateOutputAreBounded() throws {
    let literal = try MetadataTemplate.parse("a")
    #expect(MetadataTemplate.resolveKeywords(Array(repeating: literal, count: MetadataTemplate.maximumKeywordEntries + 1), using: context()) == .preserveExisting(.keywordEntryLimitExceeded(maxEntries: MetadataTemplate.maximumKeywordEntries)))
    let large = try MetadataTemplate.parse("{photographer}")
    let extra = try MetadataTemplate.parse("b")
    let values = context(photographer: String(repeating: "a", count: MetadataTemplate.maximumOutputUTF8Bytes))
    #expect(MetadataTemplate.resolveKeywords([large, extra], using: values) == .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: MetadataTemplate.maximumOutputUTF8Bytes)))
}

@Test func dependenciesIgnoreEscapedTokensAndDeduplicate() throws {
    let template = try MetadataTemplate.parse("{{gps:city}} {date:YYYY-MM-DD}{date:yyyy-MM-dd}{photographer}")
    #expect(template.requiredVariables == [.processingDate, .photographer])
}
