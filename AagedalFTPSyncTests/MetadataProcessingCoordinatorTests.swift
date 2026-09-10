import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class MetadataProcessingCoordinatorTests: XCTestCase {
    private let allFields = Set(MetadataWritableField.allCases)
    private var context: MetadataTemplateContext {
        MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: 0),
            processingTimeZone: TimeZone(secondsFromGMT: 0)!, photographer: "Unrelated sample")
    }
    private func assignment(name: String = "Creator {gps:city}") -> MetadataAssignment {
        let photographer = PhotographerProfile(name: name, filenamePrefix: "TEST", creator: "", copyrightNotice: "Legacy {date:YYYY-MM-DD}")
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Test", startsAt: .distantPast, endsAt: .distantFuture,
            fields: ScheduledMetadataFields(headline: " {{literal}} ", description: " {unknown} ", keywords: [" Café ", "cafe", "One, Two"]))
        return MetadataAssignment(photographer: photographer, clip: clip, existingFieldPolicy: .overwrite)
    }

    func testLiteralPreparationExactlyPreservesCompatibilityAdapter() {
        let source = assignment()
        let result = MetadataProcessingCoordinator.prepareLiteral(source)
        XCTAssertEqual(result.changes, .literal(source))
        XCTAssertNil(result.context)
        XCTAssertTrue(result.resolutionComplete)
        let throughResolver = MetadataProcessingCoordinator.resolve(MetadataProcessingRequest(assignment: source), context: context, writableFields: allFields)
        XCTAssertEqual(throughResolver.changes, result.changes)
        let overridden = MetadataProcessingRequest(assignment: source,
            keywords: .literal([" Café ", "cafe", "", "One, Two"]))
        XCTAssertEqual(MetadataProcessingCoordinator.resolve(overridden, context: context,
            writableFields: allFields).changes.keywords, result.changes.keywords)
    }

    func testFrozenDatesAndCanonicalPhotographerResolveOnceWithoutMutatingSource() throws {
        let source = assignment()
        let request = MetadataProcessingRequest(assignment: source,
            description: try .activated("{date:YYYY-MM-DD}. Photo: {photographer}."),
            copyright: try .activated("© {photographer}"))
        let first = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: allFields)
        let second = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: allFields)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.changes.description, "1970-01-01. Photo: Creator {gps:city}.")
        XCTAssertEqual(first.changes.copyright, "© Creator {gps:city}")
        XCTAssertEqual(first.context?.photographer, source.photographer.photographerName)
        XCTAssertEqual(request.description.source, "{date:YYYY-MM-DD}. Photo: {photographer}.")
        XCTAssertTrue(first.resolutionComplete)
    }

    func testMissingDependencyOmitsWholeFieldAndKeywordListButKeepsOtherFields() throws {
        let request = MetadataProcessingRequest(assignment: assignment(),
            headline: try .activated("{date:YYYY-MM-DD}"),
            description: try .activated("Photo in {gps:city}"),
            keywords: try .activated(["Keep?", "{persons}"]))
        let result = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: allFields)
        XCTAssertEqual(result.changes.headline, "1970-01-01")
        XCTAssertEqual(result.changes.description, "")
        XCTAssertEqual(result.changes.keywords, [])
        XCTAssertEqual(result.fields[.description], .omitted(.template(.missingValues([.city]))))
        XCTAssertEqual(result.fields[.keywords], .omitted(.template(.missingValues([.persons]))))
        XCTAssertFalse(result.resolutionComplete)
    }

    func testPreservedFieldsDeclareNoDependenciesAndDoNotCountAsIncomplete() throws {
        let request = MetadataProcessingRequest(assignment: assignment(),
            description: try .activated("{gps:city}, {gps:country}"),
            keywords: try .activated(["{persons}"]))
        let writable = allFields.subtracting([.description, .keywords])
        XCTAssertEqual(request.requiredVariables(for: writable), [])
        XCTAssertEqual(request.requiredVariables(for: allFields), [.city, .country, .persons])
        let result = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: writable)
        XCTAssertEqual(result.fields[.description], .preservedByPolicy)
        XCTAssertEqual(result.fields[.keywords], .preservedByPolicy)
        XCTAssertTrue(result.resolutionComplete)
        XCTAssertEqual(result.changes.description, "")
    }

    func testActivatedLimitsUseUTF8BytesAndPreserveCompleteKeywordList() throws {
        let request = MetadataProcessingRequest(assignment: assignment(),
            headline: try .activated(String(repeating: "é", count: 129)),
            description: try .activated(String(repeating: "a", count: 2000)),
            keywords: try .activated(["valid", String(repeating: "é", count: 33)]),
            copyright: try .activated(String(repeating: "a", count: 129)))
        let result = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: allFields)
        XCTAssertEqual(result.fields[.headline], .omitted(.writerByteLimit(maximum: 256)))
        XCTAssertEqual(result.fields[.keywords], .omitted(.writerByteLimit(maximum: 64)))
        XCTAssertEqual(result.fields[.copyright], .omitted(.writerByteLimit(maximum: 128)))
        XCTAssertEqual(result.changes.description.utf8.count, 2000)
        XCTAssertEqual(result.changes.keywords, [])
        XCTAssertFalse(result.resolutionComplete)
    }

    func testLegacyOverSpecAndMalformedBracesRetainWriterBehavior() {
        let value = String(repeating: "é", count: 300) + "{malformed"
        let request = MetadataProcessingRequest(assignment: assignment(), headline: .literal(value))
        let result = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: allFields)
        XCTAssertEqual(result.changes.headline, value)
        XCTAssertTrue(result.resolutionComplete)
    }

    func testActivatedInvalidXMLCharactersAreOmitted() throws {
        let request = MetadataProcessingRequest(assignment: assignment(),
            headline: try .activated("before\u{0}after"), keywords: try .activated(["ok", "\u{1}bad"]))
        let result = MetadataProcessingCoordinator.resolve(request, context: context, writableFields: allFields)
        XCTAssertEqual(result.fields[.headline], .omitted(.invalidXMLCharacter))
        XCTAssertEqual(result.fields[.keywords], .omitted(.invalidXMLCharacter))
        XCTAssertEqual(result.changes.headline, "")
        XCTAssertEqual(result.changes.keywords, [])
    }

    func testCaptureOffsetAndKeywordEntryBoundariesSurviveResolution() throws {
        let captured = try XCTUnwrap(MetadataCaptureDate(date: Date(timeIntervalSince1970: 0), zoneSource: .explicitOffset(secondsFromGMT: -3600)))
        let supplied = MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: 0), processingTimeZone: TimeZone(secondsFromGMT: 0)!, captureDate: captured, persons: ["One", "Two"])
        let request = MetadataProcessingRequest(assignment: assignment(), headline: try .activated("{dateCaptured:YYYY-MM-DD}"), keywords: try .activated(["{persons}", " one, two "]))
        let result = MetadataProcessingCoordinator.resolve(request, context: supplied, writableFields: allFields)
        XCTAssertEqual(result.changes.headline, "1969-12-31")
        XCTAssertEqual(result.changes.keywords, ["One, Two"])
        XCTAssertEqual(result.context?.captureDate?.zoneSource, .explicitOffset(secondsFromGMT: -3600))
    }
}
