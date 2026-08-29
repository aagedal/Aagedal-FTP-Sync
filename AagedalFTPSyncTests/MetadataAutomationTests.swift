import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataAutomationTests: XCTestCase {
    func testAssignmentMatchesFilenamePrefixCaseInsensitivelyWithinClip() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "jad",
            creator: "Jane Doe",
            copyrightNotice: "© Example News"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Political conference",
            startsAt: timestamp.addingTimeInterval(-3_600),
            endsAt: timestamp.addingTimeInterval(3_600),
            fields: ScheduledMetadataFields(headline: "Conference", description: "Delegates meet.", keywords: ["politics"])
        )
        let automation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [clip]
        )

        let assignment = automation.assignment(for: "incoming/JAD_0123.JPG", scheduledAt: timestamp)

        XCTAssertEqual(assignment?.photographer.id, photographer.id)
        XCTAssertEqual(assignment?.clip.id, clip.id)
    }

    func testAssignmentUsesHalfOpenTimeRange() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3_600)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "© Example News"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Conference",
            startsAt: start,
            endsAt: end
        )
        let automation = MetadataAutomation(isEnabled: true, photographers: [photographer], clips: [clip])

        XCTAssertNotNil(automation.assignment(for: "JAD0001.jpg", scheduledAt: start))
        XCTAssertNil(automation.assignment(for: "JAD0001.jpg", scheduledAt: end))
    }

    func testAssignmentChoosesTheMostSpecificMatchingPrefix() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let broad = PhotographerProfile(
            name: "Broad",
            filenamePrefix: "A",
            creator: "Broad",
            copyrightNotice: ""
        )
        let specific = PhotographerProfile(
            name: "Specific",
            filenamePrefix: "ABC",
            creator: "Specific",
            copyrightNotice: ""
        )
        let clips = [broad, specific].map {
            MetadataScheduleClip(
                photographerID: $0.id,
                name: $0.name,
                startsAt: timestamp.addingTimeInterval(-60),
                endsAt: timestamp.addingTimeInterval(60)
            )
        }
        let automation = MetadataAutomation(isEnabled: true, photographers: [broad, specific], clips: clips)

        XCTAssertEqual(
            automation.assignment(for: "ABC_001.jpg", scheduledAt: timestamp)?.photographer.id,
            specific.id
        )
    }

    func testOldAutomationJSONDefaultsToSourceModificationTime() throws {
        let data = Data(#"{"isEnabled":true,"photographers":[],"clips":[]}"#.utf8)

        let automation = try JSONDecoder().decode(MetadataAutomation.self, from: data)

        XCTAssertEqual(automation.timestampPolicy, .sourceModification)
        XCTAssertEqual(automation.existingFieldPolicy, .overwrite)
    }

    func testNewAutomationUsesConfirmedProductDefaults() {
        let automation = MetadataAutomation()

        XCTAssertEqual(automation.timestampPolicy, .sourceModification)
        XCTAssertEqual(automation.existingFieldPolicy, .fillEmpty)
    }

    func testExifDateParserUsesEmbeddedOffsetAndLocalFallback() throws {
        let oslo = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let offsetDate = try XCTUnwrap(MetadataWriter.parseExifDate(
            "2026:08:29 14:30:45.25+02:00",
            localTimeZone: utc
        ))
        let localDate = try XCTUnwrap(MetadataWriter.parseExifDate(
            "2026:08:29 14:30:45.25",
            localTimeZone: oslo
        ))

        XCTAssertEqual(offsetDate.timeIntervalSince1970, localDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(MetadataWriter.parseExifDate("not-an-exif-date", localTimeZone: utc))
    }

    func testValidationRejectsDuplicatePrefixesAndOverlappingClips() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = PhotographerProfile(name: "Jane", filenamePrefix: "JAD", creator: "", copyrightNotice: "")
        let second = PhotographerProfile(name: "John", filenamePrefix: "jad", creator: "", copyrightNotice: "")
        var automation = MetadataAutomation(isEnabled: true, photographers: [first, second])

        XCTAssertEqual(
            automation.validationMessage,
            "The filename prefix JAD is assigned to more than one photographer."
        )

        automation.photographers = [first]
        automation.clips = [
            MetadataScheduleClip(
                photographerID: first.id,
                name: "First",
                startsAt: timestamp,
                endsAt: timestamp.addingTimeInterval(3_600)
            ),
            MetadataScheduleClip(
                photographerID: first.id,
                name: "Second",
                startsAt: timestamp.addingTimeInterval(1_800),
                endsAt: timestamp.addingTimeInterval(5_400)
            ),
        ]

        XCTAssertEqual(automation.validationMessage, "Jane has overlapping metadata clips.")
    }

    func testKeywordsAreTrimmedAndDeduplicated() {
        let fields = ScheduledMetadataFields(
            keywords: [" politics ", "Oslo", "POLITICS", "", "oslo "]
        )

        XCTAssertEqual(fields.normalizedKeywords, ["politics", "Oslo"])
    }

    func testTimelineMoveSnapsStartAndPreservesDuration() {
        let calendar = utcCalendar
        let start = date(2026, 8, 29, 9, 7, calendar: calendar)
        let clip = MetadataScheduleClip(
            photographerID: UUID(),
            name: "Morning",
            startsAt: start,
            endsAt: start.addingTimeInterval(3_600)
        )

        let moved = MetadataTimelineEditing.moving(
            clip,
            by: 11 * 60,
            snapMinutes: 15,
            calendar: calendar
        )

        XCTAssertEqual(moved.startsAt, date(2026, 8, 29, 9, 15, calendar: calendar))
        XCTAssertEqual(moved.endsAt.timeIntervalSince(moved.startsAt), 3_600)
    }

    func testTimelineCreationUsesDraggedRangeAndSnapInterval() {
        let calendar = utcCalendar
        let day = date(2026, 8, 29, 12, 0, calendar: calendar)

        let interval = MetadataTimelineEditing.creationInterval(
            on: day,
            from: Double(9 * 60 + 7) / Double(24 * 60),
            to: Double(11 * 60 + 22) / Double(24 * 60),
            snapMinutes: 15,
            calendar: calendar
        )

        XCTAssertEqual(interval.start, date(2026, 8, 29, 9, 0, calendar: calendar))
        XCTAssertEqual(interval.end, date(2026, 8, 29, 11, 15, calendar: calendar))
    }

    func testTimelineCreationSupportsReverseDragAndMinimumDuration() {
        let calendar = utcCalendar
        let day = date(2026, 8, 29, 12, 0, calendar: calendar)

        let interval = MetadataTimelineEditing.creationInterval(
            on: day,
            from: Double(10 * 60 + 4) / Double(24 * 60),
            to: Double(10 * 60 + 2) / Double(24 * 60),
            snapMinutes: 15,
            calendar: calendar
        )

        XCTAssertEqual(interval.start, date(2026, 8, 29, 9, 45, calendar: calendar))
        XCTAssertEqual(interval.end, date(2026, 8, 29, 10, 0, calendar: calendar))
    }

    func testTimelineResizeSnapsAndKeepsMinimumDuration() {
        let calendar = utcCalendar
        let start = date(2026, 8, 29, 9, 0, calendar: calendar)
        let clip = MetadataScheduleClip(
            photographerID: UUID(),
            name: "Morning",
            startsAt: start,
            endsAt: start.addingTimeInterval(3_600)
        )

        let resized = MetadataTimelineEditing.resizing(
            clip,
            edge: .start,
            by: 3_500,
            snapMinutes: 15,
            calendar: calendar
        )

        XCTAssertEqual(resized.startsAt, clip.endsAt.addingTimeInterval(-5 * 60))
        XCTAssertEqual(resized.endsAt, clip.endsAt)
    }

    func testTimelineAnalysisFindsGapsAndOverlapsAtDayBoundaries() {
        let calendar = utcCalendar
        let photographerID = UUID()
        let day = date(2026, 8, 29, 12, 0, calendar: calendar)
        let clips = [
            MetadataScheduleClip(
                photographerID: photographerID,
                name: "Overnight",
                startsAt: date(2026, 8, 28, 23, 30, calendar: calendar),
                endsAt: date(2026, 8, 29, 1, 0, calendar: calendar)
            ),
            MetadataScheduleClip(
                photographerID: photographerID,
                name: "Morning",
                startsAt: date(2026, 8, 29, 2, 0, calendar: calendar),
                endsAt: date(2026, 8, 29, 4, 0, calendar: calendar)
            ),
            MetadataScheduleClip(
                photographerID: photographerID,
                name: "Overlap",
                startsAt: date(2026, 8, 29, 3, 0, calendar: calendar),
                endsAt: date(2026, 8, 29, 5, 0, calendar: calendar)
            ),
        ]

        let gaps = MetadataTimelineAnalysis.gaps(
            in: clips,
            for: photographerID,
            on: day,
            calendar: calendar
        )
        let overlaps = MetadataTimelineAnalysis.overlaps(
            in: clips,
            for: photographerID,
            on: day,
            calendar: calendar
        )

        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0], DateInterval(
            start: date(2026, 8, 29, 1, 0, calendar: calendar),
            end: date(2026, 8, 29, 2, 0, calendar: calendar)
        ))
        XCTAssertEqual(overlaps, [DateInterval(
            start: date(2026, 8, 29, 3, 0, calendar: calendar),
            end: date(2026, 8, 29, 4, 0, calendar: calendar)
        )])
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
