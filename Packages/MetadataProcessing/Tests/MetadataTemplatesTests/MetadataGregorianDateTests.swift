import Foundation
import Testing
@testable import MetadataTemplates

// Golden Unix instants from Python datetime's proleptic Gregorian subtraction,
// rather than Foundation Calendar or the implementation's conversion formula.
@Test(arguments: [
    (-62_135_596_800.0, "0001-01-01"), (-14_826_672_000.0, "1500-03-01"),
    (-12_220_243_200.0, "1582-10-04"), (-12_220_156_800.0, "1582-10-05"),
    (-12_219_379_200.0, "1582-10-14"), (-12_219_292_800.0, "1582-10-15"),
    (-11_670_998_400.0, "1600-02-29"), (-2_203_891_200.0, "1900-03-01"),
    (-0.5, "1969-12-31"), (0.0, "1970-01-01"), (253_402_214_400.0, "9999-12-31")
]) func dateTokensUseProlepticGregorianCalendar(fixture: (Double, String)) throws {
    let date = Date(timeIntervalSince1970: fixture.0)
    let zone = TimeZone(secondsFromGMT: 0)!
    let capture = MetadataCaptureDate(date: date, zoneSource: .explicitOffset(secondsFromGMT: 0))!
    let context = MetadataTemplateContext(processingDate: date, processingTimeZone: zone, captureDate: capture)
    let tokens = try MetadataTemplate.parse("{date:YYYY-MM-DD}/{date:yyyy-MM-dd}/{dateCaptured:YYYY-MM-DD}")
    #expect(tokens.resolve(using: context) == .resolved(Array(repeating: fixture.1, count: 3).joined(separator: "/")))
}

@Test(arguments: [
    (-14_826_672_000.0, -60, "1500-02-28"), (-14_826_672_000.0, 60, "1500-03-01"),
    (-12_220_156_800.0, -50_400, "1582-10-04"), (-12_220_156_800.0, 50_400, "1582-10-05"),
    (-1.0, 60, "1970-01-01"), (0.0, -60, "1969-12-31"),
    (253_402_214_400.0, 50_400, "9999-12-31")
]) func dateTokensApplyExplicitZoneBeforeGregorianDayConversion(fixture: (Double, Int, String)) throws {
    let date = Date(timeIntervalSince1970: fixture.0)
    let zone = TimeZone(secondsFromGMT: fixture.1)!
    let capture = MetadataCaptureDate(date: date, zoneSource: .explicitOffset(secondsFromGMT: fixture.1))!
    let context = MetadataTemplateContext(processingDate: date, processingTimeZone: zone, captureDate: capture)
    #expect(try MetadataTemplate.parse("{date:YYYY-MM-DD}/{dateCaptured:YYYY-MM-DD}").resolve(using: context)
            == .resolved("\(fixture.2)/\(fixture.2)"))
}

@Test func dateTokensKeepRepresentableInstantsBeforeMidnightInPreviousDay() throws {
    for offset in [-50_400, 0, 50_400] {
        // 2024-01-02 at midnight in the selected fixed zone, then the preceding
        // representable Date value. Conversion to Unix Double can round forward.
        let midnight = Date(timeIntervalSince1970: 1_704_153_600 - Double(offset))
        let before = Date(timeIntervalSinceReferenceDate: midnight.timeIntervalSinceReferenceDate.nextDown)
        let zone = TimeZone(secondsFromGMT: offset)!
        let context = MetadataTemplateContext(processingDate: before, processingTimeZone: zone)
        #expect(try MetadataTemplate.parse("{date:YYYY-MM-DD}").resolve(using: context) == .resolved("2024-01-01"))
    }
}

@Test func civilYearsOutsideSupportedRangeRemainUnavailableAfterZoneConversion() throws {
    for (seconds, offset) in [(-62_135_596_801.0, 0), (-62_135_596_800.0, -60),
                               (253_402_300_800.0, 0), (253_402_300_799.0, 60)] {
        let context = MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: seconds),
                                              processingTimeZone: TimeZone(secondsFromGMT: offset)!)
        #expect(try MetadataTemplate.parse("{date:YYYY-MM-DD}").resolve(using: context)
                == .preserveExisting(.invalidDate(.processingDate)))
    }
}
