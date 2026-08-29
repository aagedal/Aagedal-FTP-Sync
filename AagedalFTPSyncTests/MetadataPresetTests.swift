import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataPresetTests: XCTestCase {
    func testNormalizationTrimsNameAndNormalizesKeywords() {
        let preset = MetadataPreset(
            name: "  Election night  ",
            fields: ScheduledMetadataFields(
                headline: "Results",
                description: "Votes are counted.",
                keywords: [" politics ", "Oslo", "POLITICS", ""]
            )
        )

        let normalized = preset.normalized()

        XCTAssertEqual(normalized.name, "Election night")
        XCTAssertEqual(normalized.fields.headline, "Results")
        XCTAssertEqual(normalized.fields.description, "Votes are counted.")
        XCTAssertEqual(normalized.fields.keywords, ["politics", "Oslo"])
        XCTAssertNil(normalized.validationMessage)
    }

    func testValidationRejectsAnEmptyName() {
        let preset = MetadataPreset(name: " \n ")

        XCTAssertEqual(preset.validationMessage, "Give the metadata preset a name.")
    }

    func testApplyingPresetCopiesOnlyMetadataFields() {
        let photographerID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clip = MetadataScheduleClip(
            photographerID: photographerID,
            name: "Morning assignment",
            startsAt: start,
            endsAt: start.addingTimeInterval(3_600),
            fields: ScheduledMetadataFields(headline: "Old headline")
        )
        var preset = MetadataPreset(
            name: "Election",
            fields: ScheduledMetadataFields(
                headline: "Election results",
                description: "Votes are counted.",
                keywords: ["politics", "election"]
            )
        )

        let result = clip.applying(preset)
        preset.fields.headline = "Changed later"

        XCTAssertEqual(result.id, clip.id)
        XCTAssertEqual(result.photographerID, photographerID)
        XCTAssertEqual(result.name, clip.name)
        XCTAssertEqual(result.startsAt, clip.startsAt)
        XCTAssertEqual(result.endsAt, clip.endsAt)
        XCTAssertEqual(result.fields.headline, "Election results")
        XCTAssertEqual(result.fields.description, "Votes are counted.")
        XCTAssertEqual(result.fields.keywords, ["politics", "election"])
    }
}

final class MetadataPresetRepositoryTests: XCTestCase {
    func testMissingLibraryLoadsAsEmpty() throws {
        let fileURL = temporaryFileURL()
        let repository = MetadataPresetRepository(fileURL: fileURL)

        let result = try repository.loadResult()

        XCTAssertTrue(result.presets.isEmpty)
        XCTAssertFalse(result.recoveredFromBackup)
    }

    func testRoundTripsPresets() throws {
        let fileURL = temporaryFileURL()
        defer { removeRepositoryFiles(at: fileURL) }
        let repository = MetadataPresetRepository(fileURL: fileURL)
        let presets = [
            MetadataPreset(
                name: "Election",
                fields: ScheduledMetadataFields(
                    headline: "Election results",
                    description: "Votes are counted.",
                    keywords: ["politics", "election"]
                )
            ),
            MetadataPreset(name: "Sports", fields: ScheduledMetadataFields(keywords: ["sports"])),
        ]

        try repository.save(presets)

        XCTAssertEqual(try repository.load(), presets)
    }

    func testRecoversFromBackupWhenPrimaryFileIsCorrupt() throws {
        let fileURL = temporaryFileURL()
        defer { removeRepositoryFiles(at: fileURL) }
        let repository = MetadataPresetRepository(fileURL: fileURL)
        let recoverable = [MetadataPreset(name: "Recover me")]

        try repository.save(recoverable)
        try repository.save([MetadataPreset(name: "Newer state")])
        try Data("not valid JSON".utf8).write(to: fileURL, options: .atomic)

        let result = try repository.loadResult()

        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.presets, recoverable)
    }

    func testCorruptLibraryWithoutBackupThrows() throws {
        let fileURL = temporaryFileURL()
        defer { removeRepositoryFiles(at: fileURL) }
        try Data("not valid JSON".utf8).write(to: fileURL, options: .atomic)
        let repository = MetadataPresetRepository(fileURL: fileURL)

        XCTAssertThrowsError(try repository.load())
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-presets-\(UUID().uuidString).json")
    }

    private func removeRepositoryFiles(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("backup"))
    }
}
