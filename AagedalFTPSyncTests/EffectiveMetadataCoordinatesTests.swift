import XCTest
@testable import AagedalFTPSync

final class EffectiveMetadataCoordinatesTests: XCTestCase {
    private typealias Resolver = EffectiveMetadataCoordinates
    private let exif = Resolver.Candidate(latitude: 59.91, longitude: 10.75)
    private let xmp = Resolver.Candidate(latitude: -33.86, longitude: 151.2)
    private let scheduled = ScheduledGPSPosition(latitude: 0, longitude: -180)

    func testImageKindSelectsWholePairAndRecordsConflict() {
        for (kind, source, latitude, longitude) in [
            (Resolver.ImageKind.raw, Resolver.Source.xmp, -33.86, 151.2),
            (.embedded, .embeddedEXIF, 59.91, 10.75)
        ] {
            let result = Resolver.resolve(imageKind: kind, embeddedEXIF: exif, xmp: xmp)
            XCTAssertEqual(result.selected?.source, source)
            XCTAssertEqual(result.selected?.pair.latitude, latitude)
            XCTAssertEqual(result.selected?.pair.longitude, longitude)
            XCTAssertEqual(result.existingConflict?.embeddedEXIF.latitude, 59.91)
            XCTAssertEqual(result.existingConflict?.xmp.longitude, 151.2)
            XCTAssertTrue(result.invalidSources.isEmpty)
            XCTAssertEqual(result.scheduledDisposition, .absent)
        }
    }

    func testIncompleteCandidatesNeverCombineComponents() {
        for kind in [Resolver.ImageKind.raw, .embedded] {
            let result = Resolver.resolve(imageKind: kind,
                embeddedEXIF: .init(latitude: 59, longitude: nil),
                xmp: .init(latitude: nil, longitude: 10))
            XCTAssertNil(result.selected)
            XCTAssertNil(result.existingConflict)
            XCTAssertEqual(result.invalidSources, [.embeddedEXIF, .xmp])
        }
    }

    func testInvalidPreferredSourceFallsBackToWholeOtherPair() {
        let invalid = Resolver.Candidate(latitude: .nan, longitude: 42)
        let raw = Resolver.resolve(imageKind: .raw, embeddedEXIF: exif, xmp: invalid)
        XCTAssertEqual(raw.selected?.source, .embeddedEXIF)
        XCTAssertEqual(raw.selected?.pair.longitude, 10.75)
        XCTAssertEqual(raw.invalidSources, [.xmp])
        let embedded = Resolver.resolve(imageKind: .embedded, embeddedEXIF: invalid, xmp: xmp)
        XCTAssertEqual(embedded.selected?.source, .xmp)
        XCTAssertEqual(embedded.selected?.pair.latitude, -33.86)
        XCTAssertEqual(embedded.invalidSources, [.embeddedEXIF])
    }

    func testFillEmptyPreservesEitherExistingSourceForBothImageKinds() {
        for kind in [Resolver.ImageKind.raw, .embedded] {
            for useEXIF in [true, false] {
                let result = Resolver.resolve(imageKind: kind,
                    embeddedEXIF: useEXIF ? exif : nil, xmp: useEXIF ? nil : xmp,
                    scheduled: scheduled, policy: .fillEmpty)
                XCTAssertEqual(result.selected?.source, useEXIF ? .embeddedEXIF : .xmp)
                XCTAssertEqual(result.scheduledDisposition, .preservedExisting)
            }
        }
    }

    func testScheduledOverwriteRetainsExistingConflictAndUsesGPSFieldPolicyOnly() {
        for kind in [Resolver.ImageKind.raw, .embedded] {
            let overwrite = Resolver.resolve(imageKind: kind, embeddedEXIF: exif, xmp: xmp,
                scheduled: scheduled, policy: .init(overwriteFields: [.gpsPosition]))
            XCTAssertEqual(overwrite.selected?.source, .scheduled)
            XCTAssertEqual(overwrite.selected?.pair.latitude, 0)
            XCTAssertEqual(overwrite.selected?.pair.longitude, -180)
            XCTAssertNotNil(overwrite.existingConflict)
            XCTAssertEqual(overwrite.scheduledDisposition, .overwroteExisting)
            let unrelated = Resolver.resolve(imageKind: kind, embeddedEXIF: exif,
                scheduled: scheduled, policy: .standard)
            XCTAssertEqual(unrelated.selected?.source, .embeddedEXIF)
            XCTAssertEqual(unrelated.scheduledDisposition, .preservedExisting)
        }
    }

    func testScheduledFillsMissingAndInvalidExistingGPS() {
        for candidate in [nil, Resolver.Candidate(latitude: 91, longitude: 0)] {
            let result = Resolver.resolve(imageKind: .raw, embeddedEXIF: candidate, scheduled: scheduled)
            XCTAssertEqual(result.selected?.source, .scheduled)
            XCTAssertEqual(result.scheduledDisposition, .filledEmpty)
        }
    }

    func testInvalidScheduledPositionNeverReplacesExistingEvenWithOverwrite() {
        for position in [ScheduledGPSPosition(latitude: .infinity, longitude: 0),
                         ScheduledGPSPosition(latitude: 0, longitude: -181),
                         ScheduledGPSPosition(latitude: 0, longitude: 0, altitudeMeters: .nan)] {
            let result = Resolver.resolve(imageKind: .embedded, embeddedEXIF: exif,
                scheduled: position, policy: .overwrite)
            XCTAssertEqual(result.selected?.source, .embeddedEXIF)
            XCTAssertEqual(result.invalidSources, [.scheduled])
            XCTAssertEqual(result.scheduledDisposition, .invalid)
        }
    }

    func testCoordinateBoundsZeroAndNegativeValuesAreValidWithoutRounding() {
        for (latitude, longitude) in [(0.0, 0.0), (-90, -180), (90, 180), (-0.00000001, 0.00000001)] {
            let result = Resolver.resolve(imageKind: .embedded,
                embeddedEXIF: .init(latitude: latitude, longitude: longitude))
            XCTAssertEqual(result.selected?.pair.latitude, latitude)
            XCTAssertEqual(result.selected?.pair.longitude, longitude)
            XCTAssertTrue(result.invalidSources.isEmpty)
        }
    }

    func testInvalidComponentsAndAltitudeFollowWriterAcceptance() {
        let invalid: [Resolver.Candidate] = [
            .init(latitude: 90.00001, longitude: 0), .init(latitude: -90.00001, longitude: 0),
            .init(latitude: 0, longitude: 180.00001), .init(latitude: 0, longitude: -180.00001),
            .init(latitude: .nan, longitude: 0), .init(latitude: 0, longitude: .nan),
            .init(latitude: .infinity, longitude: 0), .init(latitude: 0, longitude: -.infinity),
            .init(latitude: 0, longitude: 0, altitudeMeters: .infinity),
            .init(latitude: nil, longitude: nil)
        ]
        for candidate in invalid {
            let result = Resolver.resolve(imageKind: .raw, xmp: candidate)
            XCTAssertNil(result.selected)
            XCTAssertEqual(result.invalidSources, [.xmp])
        }
    }

    func testConflictIsExactPairComparisonIndependentOfAltitude() {
        let same = Resolver.resolve(imageKind: .raw, embeddedEXIF: exif,
            xmp: .init(latitude: 59.91, longitude: 10.75, altitudeMeters: 100))
        XCTAssertNil(same.existingConflict)
        let near = Resolver.resolve(imageKind: .raw, embeddedEXIF: exif,
            xmp: .init(latitude: 59.91, longitude: 10.750000001))
        XCTAssertNotNil(near.existingConflict)
    }

    func testNoClipAndNoGPSHaveExplicitEmptyOutcome() {
        let result = Resolver.resolve(imageKind: .embedded)
        XCTAssertNil(result.selected)
        XCTAssertNil(result.existingConflict)
        XCTAssertTrue(result.invalidSources.isEmpty)
        XCTAssertEqual(result.scheduledDisposition, .absent)
    }
}
