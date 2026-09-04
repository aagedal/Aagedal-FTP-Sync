import Foundation
import MapKit
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

    func testClipSelectionInstantUsesClickedPositionAndStaysInsideClip() {
        let calendar = utcCalendar
        let person = photographer("Selection")
        let clip = MetadataScheduleClip(
            photographerID: person.id,
            name: "Assignment",
            startsAt: date(2026, 9, 4, 9, 0, calendar: calendar),
            endsAt: date(2026, 9, 4, 10, 0, calendar: calendar)
        )

        XCTAssertEqual(
            PhotographerMapTimeline.selectionInstant(in: clip, at: 0.25),
            date(2026, 9, 4, 9, 15, calendar: calendar)
        )
        XCTAssertEqual(
            PhotographerMapTimeline.selectionInstant(in: clip, at: -1),
            clip.startsAt
        )

        let endSelection = PhotographerMapTimeline.selectionInstant(in: clip, at: 2)
        XCTAssertLessThan(endSelection, clip.endsAt)
        XCTAssertEqual(endSelection.timeIntervalSince(clip.endsAt), -0.001, accuracy: 0.000_1)
    }

    func testClipFrameUsesAbsoluteTimeWithinTheDay() {
        let calendar = utcCalendar
        let dayStart = date(2026, 9, 4, 0, 0, calendar: calendar)
        let clip = MetadataScheduleClip(
            photographerID: UUID(),
            name: "Morning",
            startsAt: date(2026, 9, 4, 9, 0, calendar: calendar),
            endsAt: date(2026, 9, 4, 10, 30, calendar: calendar)
        )

        let frame = PhotographerMapTimeline.clipFrame(
            for: clip,
            dayStart: dayStart,
            dayDuration: 24 * 60 * 60,
            totalWidth: 240
        )

        XCTAssertEqual(frame.minX, 90, accuracy: 0.001)
        XCTAssertEqual(frame.width, 15, accuracy: 0.001)
        XCTAssertEqual(frame.midX, 97.5, accuracy: 0.001)
    }

    func testDayCameraFrameContainsEveryValidClipLocationWithPadding() throws {
        let oslo = ScheduledGPSPosition(latitude: 59.9139, longitude: 10.7522)
        let drammen = ScheduledGPSPosition(latitude: 59.7439, longitude: 10.2045)
        let rect = try XCTUnwrap(PhotographerMapCameraFraming.mapRect(for: [
            oslo,
            ScheduledGPSPosition(latitude: 200, longitude: 10),
            drammen,
        ]))

        XCTAssertTrue(rect.contains(MKMapPoint(CLLocationCoordinate2D(
            latitude: oslo.latitude,
            longitude: oslo.longitude
        ))))
        XCTAssertTrue(rect.contains(MKMapPoint(CLLocationCoordinate2D(
            latitude: drammen.latitude,
            longitude: drammen.longitude
        ))))
        XCTAssertGreaterThan(rect.width, abs(
            MKMapPoint(CLLocationCoordinate2D(latitude: oslo.latitude, longitude: oslo.longitude)).x
                - MKMapPoint(CLLocationCoordinate2D(latitude: drammen.latitude, longitude: drammen.longitude)).x
        ))
        XCTAssertNil(PhotographerMapCameraFraming.mapRect(for: []))
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
