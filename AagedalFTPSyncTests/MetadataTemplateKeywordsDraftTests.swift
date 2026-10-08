import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class MetadataTemplateKeywordsDraftTests: XCTestCase {
    func testLiteralDraftKeepsCommasWhitespaceDuplicatesAndBracesExactly() throws {
        let sources = ["Paris, France", "  {gps:city}  ", "one", "one", "{broken"]
        let value = MetadataTemplateKeywords.literal(sources)
        let draft = MetadataTemplateKeywordsDraft(value)
        XCTAssertFalse(draft.resolvesVariables)
        XCTAssertEqual(try draft.validatedValue(), value)
        XCTAssertNil(draft.validationMessage)
    }

    func testActiveWholeListRoundTripNeverNormalizesSource() throws {
        let sources = ["  {gps:city}  ", "Paris, France", "one", "one"]
        let value = try MetadataTemplateKeywords.activated(sources)
        let draft = MetadataTemplateKeywordsDraft(value)
        XCTAssertTrue(draft.resolvesVariables)
        XCTAssertEqual(try draft.validatedValue(), value)
        XCTAssertEqual(try draft.validatedValue().source, sources)
    }

    func testInvalidRowPreventsAtomicApplyAndCancelLeavesParentUnchanged() throws {
        let original = try MetadataTemplateKeywords.activated(["{photographer}", "retained"])
        var parent = original
        var draft = MetadataTemplateKeywordsDraft(parent)
        draft.entries[0].source = "{unsupported}"
        XCTAssertNotNil(draft.validationMessage)
        do {
            let validated = try draft.validatedValue()
            parent = validated
            XCTFail("Invalid whole-list draft must not apply")
        } catch {}
        XCTAssertEqual(parent, original)
        // Dismissing discards this independent draft; it never changed the typed parent.
        draft.entries.removeAll()
        XCTAssertEqual(parent, original)
    }

    func testActivationAndLiteralConversionAreExplicitWholeListOperations() throws {
        let sources = ["{dateCaptured:YYYY-MM-DD}", "{gps:city}"]
        var draft = MetadataTemplateKeywordsDraft(.literal(sources))
        XCTAssertNil(try draft.validatedValue().templateVersion)
        draft.resolvesVariables = true
        XCTAssertEqual(try draft.validatedValue().templateVersion, 1)
        draft.resolvesVariables = false
        XCTAssertEqual(try draft.validatedValue(), .literal(sources))
    }

    func testPresetClipCopyPreservesActiveKeywordArrayAndSourceMarkers() throws {
        let sources = ["one,two", "  {photographer} ", "one,two"]
        var fields = ScheduledMetadataFields(headline: "Literal headline")
        fields.setKeywords(try .activated(sources))
        fields.setDescription(try .activated("  {photographer}  "))
        let preset = MetadataPreset(name: "Fixture", fields: fields)
        let clip = MetadataScheduleClip(photographerID: UUID(), name: "Clip", startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 60))
        let copied = clip.applying(preset)
        let keywordDraft = MetadataTemplateKeywordsDraft(try copied.fields.validatedKeywords)
        XCTAssertEqual(try keywordDraft.validatedValue().source, sources)
        XCTAssertEqual(copied.fields.description, "  {photographer}  ")
        XCTAssertEqual(copied.fields.templateVersions, ["description": 1, "keywords": 1])
    }
}
