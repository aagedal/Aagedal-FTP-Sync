import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataGeocodingAppleConsentTests: XCTestCase {
    func testPreparingOrDiscardingConfirmationLeavesOriginalUnchanged() throws {
        let original = try MetadataGeocodingSettings(resolveVariables: true, cityPolicy: .fillEmpty, localeIdentifier: "nb")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(original)
        var pending: MetadataGeocodingAppleConsent? = .init(original: original)
        XCTAssertEqual(pending?.original, original)
        XCTAssertEqual(original.provider, .offline)
        XCTAssertFalse(original.allowSendingCoordinatesToApple)
        pending = nil
        XCTAssertNil(pending)
        XCTAssertEqual(try encoder.encode(original), before)
    }

    func testAffirmativeConfirmationPreservesChoicesAndGrantsExplicitConsent() throws {
        let original = try MetadataGeocodingSettings(resolveVariables: true, cityPolicy: .fillEmpty,
                                                   countryPolicy: .overwrite, localeIdentifier: "fr")
        let pending = MetadataGeocodingAppleConsent(original: original)
        let confirmed = try pending.confirmed(current: original)
        XCTAssertEqual(confirmed.provider, .apple)
        XCTAssertTrue(confirmed.allowSendingCoordinatesToApple)
        XCTAssertEqual(confirmed.cityPolicy, original.cityPolicy)
        XCTAssertEqual(confirmed.countryPolicy, original.countryPolicy)
        XCTAssertEqual(confirmed.resolveVariables, original.resolveVariables)
        XCTAssertEqual(confirmed.localeIdentifier, original.localeIdentifier)
        XCTAssertEqual(original.provider, .offline)
        var reverted = confirmed
        try reverted.selectProvider(.offline)
        XCTAssertFalse(reverted.allowSendingCoordinatesToApple)
        XCTAssertEqual(reverted, original)
    }

    func testStaleConfirmationCannotReplaceNewerDraftChoices() throws {
        let original = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, localeIdentifier: "en")
        let pending = MetadataGeocodingAppleConsent(original: original)
        var changed = original
        changed.countryPolicy = .overwrite
        XCTAssertThrowsError(try pending.confirmed(current: changed)) { error in
            guard let consentError = error as? MetadataGeocodingAppleConsent.ConsentError,
                  case .draftChanged = consentError else {
                return XCTFail("Expected the stale confirmation guard")
            }
        }
        XCTAssertEqual(changed.provider, .offline)
        XCTAssertEqual(changed.countryPolicy, .overwrite)
        XCTAssertFalse(changed.allowSendingCoordinatesToApple)
    }

    func testChoosingAppleForAbsentSettingsDoesNotEnableAnyLookupConsumer() throws {
        let pending = MetadataGeocodingAppleConsent(original: nil)
        XCTAssertNil(pending.original)
        let confirmed = try pending.confirmed(current: nil)
        XCTAssertEqual(confirmed.provider, .apple)
        XCTAssertTrue(confirmed.allowSendingCoordinatesToApple)
        XCTAssertFalse(confirmed.resolveVariables)
        XCTAssertEqual(confirmed.cityPolicy, .disabled)
        XCTAssertEqual(confirmed.countryPolicy, .disabled)
        XCTAssertFalse(confirmed.isEnabled)
    }
}
