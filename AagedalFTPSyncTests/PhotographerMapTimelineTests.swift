import Foundation
import XCTest
@testable import AagedalFTPSync

final class PhotographerMapTimelineTests: XCTestCase {
    func testRowsUseSelectedDaysTrackOrderAndRetainEmptyTracks() throws {
        let calendar = utcCalendar
        let day = date(2026, 9, 4, 12, 0, calendar: calendar)
        let first = photographer("First")
        let second = photographer("Second")
        let automation = MetadataAutomation(
            photographers: [first, second],
            photographerTracks: [
                MetadataPhotographerTrack(
                    photographerID: second.id,
                    date: PhotographerWorkDate(day, calendar: calendar)
                ),
                MetadataPhotographerTrack(
                    photographerID: first.id,
                    date: PhotographerWorkDate(day, calendar: calendar)
                ),
            ],
            clips: [MetadataScheduleClip(
                photographerID: first.id,
                name: "Assignment",
                startsAt: date(2026, 9, 4, 9, 0, calendar: calendar),
                endsAt: date(2026, 9, 4, 10, 0, calendar: calendar)
            )]
        )

        let rows = PhotographerMapTimeline.rows(for: automation, on: day, calendar: calendar)

        XCTAssertEqual(rows.map(\.photographer.id), [second.id, first.id])
        XCTAssertTrue(try XCTUnwrap(rows.first).clips.isEmpty)
        XCTAssertEqual(try XCTUnwrap(rows.last).clips.map(\.name), ["Assignment"])
    }

    func testRowsClipOvernightAssignmentsToSelectedDayAndPreserveLocationState() throws {
        let calendar = utcCalendar
        let day = date(2026, 9, 4, 12, 0, calendar: calendar)
        let person = photographer("Night")
        let position = ScheduledGPSPosition(latitude: 59.9139, longitude: 10.7522)
        let automation = MetadataAutomation(
            photographers: [person],
            clips: [
                MetadataScheduleClip(
                    photographerID: person.id,
                    name: "Overnight",
                    startsAt: date(2026, 9, 3, 23, 0, calendar: calendar),
                    endsAt: date(2026, 9, 4, 2, 0, calendar: calendar),
                    gpsPosition: position
                ),
                MetadataScheduleClip(
                    photographerID: person.id,
                    name: "Desk",
                    startsAt: date(2026, 9, 4, 9, 0, calendar: calendar),
                    endsAt: date(2026, 9, 4, 10, 0, calendar: calendar)
                ),
            ]
        )

        let row = try XCTUnwrap(
            PhotographerMapTimeline.rows(for: automation, on: day, calendar: calendar).first
        )

        XCTAssertEqual(row.clips.map(\.name), ["Overnight", "Desk"])
        XCTAssertEqual(row.clips[0].startsAt, calendar.startOfDay(for: day))
        XCTAssertEqual(row.clips[0].endsAt, date(2026, 9, 4, 2, 0, calendar: calendar))
        XCTAssertEqual(row.clips[0].gpsPosition, position)
        XCTAssertNil(row.clips[1].gpsPosition)
    }

    private func photographer(_ name: String) -> PhotographerProfile {
        PhotographerProfile(
            name: name,
            filenamePrefix: String(name.prefix(1)),
            creator: name,
            copyrightNotice: ""
        )
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
