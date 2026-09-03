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

    func testAssignmentMatchesAnyCommaSeparatedCameraInitials() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: " jad, JDX, jad ",
            creator: "Jane Doe",
            copyrightNotice: "© Example News"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Conference",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60)
        )
        let automation = MetadataAutomation(isEnabled: true, photographers: [photographer], clips: [clip])

        XCTAssertEqual(photographer.normalizedPrefixes, ["JAD", "JDX"])
        XCTAssertEqual(photographer.formattedFilenamePrefixes, "JAD, JDX")
        XCTAssertEqual(
            automation.assignment(for: "incoming/JDX_0123.JPG", scheduledAt: timestamp)?.photographer.id,
            photographer.id
        )
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

    func testSpecificityUsesTheInitialsThatMatchedTheFilename() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let broad = PhotographerProfile(
            name: "Broad",
            filenamePrefix: "UNRELATED, A",
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

    func testLegacyClipJSONLoadsWithoutGPSPosition() throws {
        let photographerID = UUID()
        let clipID = UUID()
        let data = Data(
            """
            {
              "id":"\(clipID.uuidString)",
              "photographerID":"\(photographerID.uuidString)",
              "name":"Legacy clip",
              "startsAt":0,
              "endsAt":60,
              "fields":{"headline":"","description":"","keywords":[]}
            }
            """.utf8
        )

        let clip = try JSONDecoder().decode(MetadataScheduleClip.self, from: data)

        XCTAssertEqual(clip.id, clipID)
        XCTAssertNil(clip.gpsPosition)
    }

    func testClipGPSPositionRoundTripsThroughJSON() throws {
        let position = ScheduledGPSPosition(
            latitude: 59.9139,
            longitude: 10.7522,
            altitudeMeters: 24,
            label: "Oslo"
        )
        let clip = MetadataScheduleClip(
            photographerID: UUID(),
            name: "Located clip",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_000_060),
            gpsPosition: position
        )

        let decoded = try JSONDecoder().decode(
            MetadataScheduleClip.self,
            from: JSONEncoder().encode(clip)
        )

        XCTAssertEqual(decoded, clip)
        XCTAssertEqual(decoded.gpsPosition, position)
    }

    func testNewAutomationUsesConfirmedProductDefaults() {
        let automation = MetadataAutomation()

        XCTAssertEqual(automation.timestampPolicy, .sourceModification)
        XCTAssertEqual(automation.existingFieldPolicy, .fillEmpty)
    }

    func testLegacyPhotographerJSONLoadsWithoutWorkHours() throws {
        let id = UUID()
        let data = Data(
            """
            {"id":"\(id.uuidString)","name":"Jane","filenamePrefix":"JAD","creator":"Jane","copyrightNotice":"News"}
            """.utf8
        )

        let photographer = try JSONDecoder().decode(PhotographerProfile.self, from: data)

        XCTAssertEqual(photographer.id, id)
        XCTAssertNil(photographer.workHours)
        XCTAssertNil(photographer.workHourOverrides)
    }

    func testIPTCCreatorIsUsedAsPhotographerName() {
        let photographer = PhotographerProfile(
            name: "Legacy display name",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "News"
        )

        XCTAssertEqual(photographer.photographerName, "Jane Doe")
        XCTAssertEqual(photographer.usingCreatorAsPhotographerName().name, "Jane Doe")
    }

    func testLegacyNameIsUsedWhenCreatorIsEmpty() {
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "",
            copyrightNotice: "News"
        )

        XCTAssertEqual(photographer.photographerName, "Jane Doe")
        XCTAssertEqual(photographer.usingCreatorAsPhotographerName().creator, "Jane Doe")
    }

    func testPhotographerWorkHoursCreateDailyTimelineInterval() throws {
        let calendar = utcCalendar
        let day = date(2026, 8, 30, 12, 0, calendar: calendar)
        let hours = PhotographerWorkHours(startMinutes: 8 * 60 + 30, endMinutes: 16 * 60 + 45)

        let interval = try XCTUnwrap(hours.interval(on: day, calendar: calendar))

        XCTAssertEqual(interval.start, date(2026, 8, 30, 8, 30, calendar: calendar))
        XCTAssertEqual(interval.end, date(2026, 8, 30, 16, 45, calendar: calendar))
    }

    func testPhotographerWorkHoursSupportDateOverridesAndDaysOff() throws {
        let calendar = utcCalendar
        let monday = date(2026, 8, 31, 12, 0, calendar: calendar)
        let tuesday = date(2026, 9, 1, 12, 0, calendar: calendar)
        let wednesday = date(2026, 9, 2, 12, 0, calendar: calendar)
        var photographer = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD",
            creator: "Jane",
            copyrightNotice: "News",
            workHours: PhotographerWorkHours(startMinutes: 9 * 60, endMinutes: 17 * 60)
        )
        let lateShift = PhotographerWorkHours(startMinutes: 12 * 60, endMinutes: 20 * 60)

        photographer.setWorkHoursOverride(lateShift, on: monday, calendar: calendar)
        photographer.setWorkHoursOverride(nil, on: tuesday, calendar: calendar)

        XCTAssertEqual(photographer.workHours(on: monday, calendar: calendar), lateShift)
        XCTAssertNil(photographer.workHours(on: tuesday, calendar: calendar))
        XCTAssertEqual(photographer.workHours(on: wednesday, calendar: calendar), photographer.workHours)
        XCTAssertNotNil(photographer.workHoursOverride(on: tuesday, calendar: calendar))

        photographer.clearWorkHoursOverride(on: monday, calendar: calendar)

        XCTAssertEqual(photographer.workHours(on: monday, calendar: calendar), photographer.workHours)
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
            "The filename initials JAD are assigned to more than one photographer."
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

    func testValidationRejectsDuplicateSecondaryCameraInitials() {
        let first = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD, CAM2",
            creator: "Jane",
            copyrightNotice: ""
        )
        let second = PhotographerProfile(
            name: "John",
            filenamePrefix: "JOS, cam2",
            creator: "John",
            copyrightNotice: ""
        )
        let automation = MetadataAutomation(photographers: [first, second])

        XCTAssertEqual(
            automation.validationMessage,
            "The filename initials CAM2 are assigned to more than one photographer."
        )
    }

    func testValidationRejectsInvalidGPSPosition() {
        let photographer = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD",
            creator: "Jane",
            copyrightNotice: ""
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Invalid location",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_000_060),
            gpsPosition: ScheduledGPSPosition(latitude: 91, longitude: 10)
        )
        let automation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [clip]
        )

        XCTAssertEqual(
            automation.validationMessage,
            "Every clip location must use valid latitude and longitude coordinates."
        )
    }

    func testPositionedPhotographersChangeAtHalfOpenClipBoundary() throws {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let photographer = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD",
            creator: "Jane",
            copyrightNotice: ""
        )
        let firstPosition = ScheduledGPSPosition(latitude: 59.9139, longitude: 10.7522, label: "Oslo")
        let secondPosition = ScheduledGPSPosition(latitude: 60.3913, longitude: 5.3221, label: "Bergen")
        let automation = MetadataAutomation(
            photographers: [photographer],
            clips: [
                MetadataScheduleClip(
                    photographerID: photographer.id,
                    name: "Oslo",
                    startsAt: boundary.addingTimeInterval(-3_600),
                    endsAt: boundary,
                    gpsPosition: firstPosition
                ),
                MetadataScheduleClip(
                    photographerID: photographer.id,
                    name: "Bergen",
                    startsAt: boundary,
                    endsAt: boundary.addingTimeInterval(3_600),
                    gpsPosition: secondPosition
                ),
            ]
        )

        XCTAssertEqual(
            try XCTUnwrap(automation.positionedPhotographers(at: boundary.addingTimeInterval(-1)).first).position,
            firstPosition
        )
        XCTAssertEqual(
            try XCTUnwrap(automation.positionedPhotographers(at: boundary).first).position,
            secondPosition
        )
    }

    func testMapChangePointsIncludeOnlyLocatedClipBoundariesInsideDay() {
        let calendar = utcCalendar
        let day = date(2026, 9, 3, 12, 0, calendar: calendar)
        let photographerID = UUID()
        let automation = MetadataAutomation(clips: [
            MetadataScheduleClip(
                photographerID: photographerID,
                name: "Located",
                startsAt: date(2026, 9, 3, 9, 0, calendar: calendar),
                endsAt: date(2026, 9, 3, 11, 0, calendar: calendar),
                gpsPosition: ScheduledGPSPosition(latitude: 59.9139, longitude: 10.7522)
            ),
            MetadataScheduleClip(
                photographerID: photographerID,
                name: "No location",
                startsAt: date(2026, 9, 3, 12, 0, calendar: calendar),
                endsAt: date(2026, 9, 3, 13, 0, calendar: calendar)
            ),
        ])

        XCTAssertEqual(automation.mapChangePoints(on: day, calendar: calendar), [
            date(2026, 9, 3, 9, 0, calendar: calendar),
            date(2026, 9, 3, 11, 0, calendar: calendar),
        ])
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

    func testTimelinePasteAnchorsEarliestClipAndRemapsSingleSourceTrack() {
        let calendar = utcCalendar
        let sourcePhotographerID = UUID()
        let targetPhotographerID = UUID()
        let firstStart = date(2026, 8, 29, 9, 0, calendar: calendar)
        let secondStart = date(2026, 8, 29, 11, 30, calendar: calendar)
        let targetStart = date(2026, 8, 30, 14, 15, calendar: calendar)
        let source = [
            MetadataScheduleClip(
                photographerID: sourcePhotographerID,
                name: "First",
                startsAt: firstStart,
                endsAt: firstStart.addingTimeInterval(3_600),
                gpsPosition: ScheduledGPSPosition(latitude: 59.9139, longitude: 10.7522)
            ),
            MetadataScheduleClip(
                photographerID: sourcePhotographerID,
                name: "Second",
                startsAt: secondStart,
                endsAt: secondStart.addingTimeInterval(1_800)
            ),
        ]

        let copies = MetadataTimelineEditing.copies(
            of: source,
            anchoredAt: targetStart,
            on: targetPhotographerID
        ).sorted { $0.startsAt < $1.startsAt }

        XCTAssertEqual(copies.map(\.photographerID), [targetPhotographerID, targetPhotographerID])
        XCTAssertEqual(copies[0].startsAt, targetStart)
        XCTAssertEqual(copies[0].endsAt.timeIntervalSince(copies[0].startsAt), 3_600)
        XCTAssertEqual(copies[1].startsAt.timeIntervalSince(copies[0].startsAt), 2.5 * 3_600)
        XCTAssertEqual(copies[1].endsAt.timeIntervalSince(copies[1].startsAt), 1_800)
        XCTAssertNotEqual(copies[0].id, source[0].id)
        XCTAssertNotEqual(copies[1].id, source[1].id)
        XCTAssertEqual(copies[0].gpsPosition, source[0].gpsPosition)
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

    func testRestrictedAutomationClipsProgrammingToSelectedDaysAndPhotographers() {
        let calendar = utcCalendar
        let includedPhotographer = PhotographerProfile(
            name: "Included",
            filenamePrefix: "INC",
            creator: "Included",
            copyrightNotice: ""
        )
        let excludedPhotographer = PhotographerProfile(
            name: "Excluded",
            filenamePrefix: "EXC",
            creator: "Excluded",
            copyrightNotice: ""
        )
        let overnight = MetadataScheduleClip(
            photographerID: includedPhotographer.id,
            name: "Overnight",
            startsAt: date(2026, 9, 2, 23, 0, calendar: calendar),
            endsAt: date(2026, 9, 4, 1, 0, calendar: calendar)
        )
        let later = MetadataScheduleClip(
            photographerID: excludedPhotographer.id,
            name: "Later",
            startsAt: date(2026, 9, 5, 10, 0, calendar: calendar),
            endsAt: date(2026, 9, 5, 11, 0, calendar: calendar)
        )
        let automation = MetadataAutomation(
            isEnabled: true,
            photographers: [includedPhotographer, excludedPhotographer],
            clips: [overnight, later]
        )

        let result = automation.restricted(
            to: [date(2026, 9, 3, 12, 0, calendar: calendar)],
            calendar: calendar
        )

        XCTAssertEqual(result.photographers, [includedPhotographer])
        XCTAssertEqual(result.clips.count, 1)
        XCTAssertEqual(result.clips[0].id, overnight.id)
        XCTAssertEqual(result.clips[0].startsAt, date(2026, 9, 3, 0, 0, calendar: calendar))
        XCTAssertEqual(result.clips[0].endsAt, date(2026, 9, 4, 0, 0, calendar: calendar))
    }

    func testRestrictedAutomationSplitsClipAcrossNoncontiguousSelectedDays() {
        let calendar = utcCalendar
        let photographer = PhotographerProfile(
            name: "Jane",
            filenamePrefix: "JAD",
            creator: "Jane",
            copyrightNotice: ""
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Long assignment",
            startsAt: date(2026, 9, 2, 12, 0, calendar: calendar),
            endsAt: date(2026, 9, 6, 12, 0, calendar: calendar)
        )
        let automation = MetadataAutomation(photographers: [photographer], clips: [clip])

        let result = automation.restricted(
            to: [
                date(2026, 9, 3, 12, 0, calendar: calendar),
                date(2026, 9, 5, 12, 0, calendar: calendar),
            ],
            calendar: calendar
        )

        XCTAssertEqual(result.clips.count, 2)
        XCTAssertEqual(Set(result.clips.map(\.id)).count, 2)
        XCTAssertEqual(
            result.clips.map { DateInterval(start: $0.startsAt, end: $0.endsAt) },
            [
                DateInterval(
                    start: date(2026, 9, 3, 0, 0, calendar: calendar),
                    end: date(2026, 9, 4, 0, 0, calendar: calendar)
                ),
                DateInterval(
                    start: date(2026, 9, 5, 0, 0, calendar: calendar),
                    end: date(2026, 9, 6, 0, 0, calendar: calendar)
                ),
            ]
        )
    }

    func testProgrammingDaySelectionUsesShiftRangeAndContextTarget() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let first = date(2026, 3, 28, 12, 0, calendar: calendar)
        let last = date(2026, 3, 30, 12, 0, calendar: calendar)
        let unselected = date(2026, 4, 2, 12, 0, calendar: calendar)
        var selection = ProgrammingDaySelection(selectedDate: first, calendar: calendar)

        selection.select(last, extending: true)

        XCTAssertEqual(selection.days.count, 3)
        XCTAssertEqual(selection.contextSelection(for: last), selection.days)
        XCTAssertEqual(
            selection.contextSelection(for: unselected),
            [calendar.startOfDay(for: unselected)]
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
