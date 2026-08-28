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

        let assignment = automation.assignment(for: "incoming/JAD_0123.JPG", modifiedAt: timestamp)

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

        XCTAssertNotNil(automation.assignment(for: "JAD0001.jpg", modifiedAt: start))
        XCTAssertNil(automation.assignment(for: "JAD0001.jpg", modifiedAt: end))
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
            automation.assignment(for: "ABC_001.jpg", modifiedAt: timestamp)?.photographer.id,
            specific.id
        )
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
}
