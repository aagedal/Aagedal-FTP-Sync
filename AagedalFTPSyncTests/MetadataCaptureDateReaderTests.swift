import AppKit
import Foundation
import MetadataTemplates
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataCaptureDateReaderTests: XCTestCase {
    private typealias Reader = MetadataCaptureDateReader
    private func decode(_ value: String?, offset: String? = nil, subseconds: String? = nil,
                        zone: String? = "Europe/Oslo") -> Reader.Result {
        Reader.decode(original: value, offset: offset, subseconds: subseconds, persistedFallbackTimeZoneIdentifier: zone)
    }
    private func resolved(_ result: Reader.Result, file: StaticString = #filePath, line: UInt = #line) throws
        -> (MetadataCaptureDate, Reader.Provenance) {
        guard case .resolved(let date, let provenance) = result else {
            XCTFail("Expected resolved capture, got \(result)", file: file, line: line)
            throw CocoaError(.coderInvalidValue)
        }
        return (date, provenance)
    }

    func testGregorianValidationRejectsNormalizationAndLeapSeconds() throws {
        for value in ["0000:01:01 00:00:00", "2023:02:29 00:00:00", "1900:02:29 00:00:00",
                      "2024:04:31 00:00:00", "2024:00:01 00:00:00", "2024:13:01 00:00:00",
                      "2024:01:00 00:00:00", "2024:01:01 24:00:00", "2024:01:01 00:60:00",
                      "2024:01:01 00:00:60"] {
            XCTAssertEqual(decode(value), .invalid(.calendarComponents, .exifOriginal), value)
        }
        let leap = try resolved(decode("2000:02:29 12:34:56Z"))
        XCTAssertEqual(leap.0.date.timeIntervalSince1970, 951_827_696)
        let ancient = try resolved(decode("1500:03:01 00:00:00Z"))
        XCTAssertEqual(ancient.0.date.timeIntervalSince1970, -14_826_672_000)
        let ancientFallback = try resolved(decode("1500:03:01 00:00:00", zone: "GMT"))
        XCTAssertEqual(ancientFallback.0.date, ancient.0.date)
        let earliest = try resolved(decode("0001:01:01 00:00:00Z"))
        XCTAssertEqual(earliest.0.date.timeIntervalSince1970, -62_135_596_800)
    }

    func testOffsetsAreBoundedWholeMinutesAndKeepProvenance() throws {
        for offset in ["+14:01", "-14:01", "+15:00", "+01:60", "+01:99", "+1:00", "+0100", "", " Z", "z"] {
            XCTAssertEqual(decode("2024:01:01 00:00:00", offset: offset), .invalid(.malformedOffset, .exifOriginal), offset)
        }
        for (offset, seconds) in [("+14:00", 50400), ("-14:00", -50400), ("+05:45", 20700), ("Z", 0), ("-00:00", 0)] {
            let result = try resolved(decode("2024:01:01 00:00:00", offset: offset, zone: nil))
            XCTAssertEqual(result.0.date.timeIntervalSince1970, 1_704_067_200 - Double(seconds))
            XCTAssertEqual(result.0.zoneSource, .explicitOffset(secondsFromGMT: seconds))
            XCTAssertEqual(result.1.zoneSource, result.0.zoneSource)
        }
    }

    func testEmbeddedAndSeparateOffsetAndFractionConflictsFail() throws {
        XCTAssertEqual(decode("2024:01:01 00:00:00+02:00", offset: "+01:00"), .invalid(.conflictingOffsets, .exifOriginal))
        XCTAssertEqual(decode("2024:01:01 00:00:00.125Z", subseconds: "126"), .invalid(.conflictingSubseconds, .exifOriginal))
        let matched = try resolved(decode("2024:01:01 00:00:00.125Z", offset: "+00:00", subseconds: "125000000"))
        XCTAssertEqual(matched.1.nanosecond, 125_000_000)
        XCTAssertEqual(matched.0.date.timeIntervalSince1970, 1_704_067_200.125, accuracy: 0.000001)
        for fraction in ["", "-1", "12 ", "1234567890", "١٢"] {
            XCTAssertEqual(decode("2024:01:01 00:00:00Z", subseconds: fraction), .invalid(.malformedSubseconds, .exifOriginal))
        }
        let tiny = try resolved(decode("2024:01:01 00:00:00.000000001Z"))
        XCTAssertEqual(tiny.1.nanosecond, 1, "Preserve exact input despite Date Double precision")
    }

    func testFractionalRoundingCannotAdvanceCaptureDayInTemplateResolution() throws {
        for offset in ["Z", "+14:00", "-14:00"] {
            let capture = try resolved(decode("2024:01:01 23:59:59.999999999" + offset))
            XCTAssertEqual(capture.1.nanosecond, 999_999_999)
            let context = MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: 0),
                processingTimeZone: TimeZone(secondsFromGMT: 0)!, captureDate: capture.0)
            XCTAssertEqual(try MetadataTemplates.MetadataTemplate.parse("{dateCaptured:YYYY-MM-DD}").resolve(using: context), .resolved("2024-01-01"))
        }
    }

    func testOffsetFreeValuesRequirePersistedZoneAndNeverReadCurrentSetting() throws {
        XCTAssertEqual(decode("2024:01:01 00:00:00", zone: nil), .invalid(.missingFallbackZone, .exifOriginal))
        XCTAssertEqual(decode("2024:01:01 00:00:00", zone: "invalid/zone"), .invalid(.invalidFallbackZone, .exifOriginal))
        let winter = try resolved(decode("2024:01:01 00:00:00"))
        XCTAssertEqual(winter.0.date.timeIntervalSince1970, 1_704_063_600)
        XCTAssertEqual(winter.0.zoneSource, .persistedFallback(identifier: "Europe/Oslo"))
        let summer = try resolved(decode("2024:07:01 00:00:00"))
        XCTAssertEqual(summer.0.timeZone.secondsFromGMT(for: summer.0.date), 7200)
        XCTAssertEqual(decode("2024:07:01 00:00:00"), decode("2024:07:01 00:00:00"))
    }

    func testDSTGapsAndFoldsAreTypedAndExplicitOffsetDisambiguates() throws {
        XCTAssertEqual(decode("2024:03:31 02:30:00"), .invalid(.nonexistentLocalTime, .exifOriginal))
        XCTAssertEqual(decode("2024:10:27 02:30:00"), .ambiguousLocalTime(.exifOriginal, persistedTimeZoneIdentifier: "Europe/Oslo"))
        let first = try resolved(decode("2024:10:27 02:30:00+02:00"))
        let last = try resolved(decode("2024:10:27 02:30:00+01:00"))
        XCTAssertEqual(last.0.date.timeIntervalSince(first.0.date), 3600)
        XCTAssertEqual(decode("2024:10:06 02:15:00", zone: "Australia/Lord_Howe"), .invalid(.nonexistentLocalTime, .exifOriginal))
        XCTAssertEqual(decode("2024:04:07 01:45:00", zone: "Australia/Lord_Howe"),
                       .ambiguousLocalTime(.exifOriginal, persistedTimeZoneIdentifier: "Australia/Lord_Howe"))
        XCTAssertEqual(decode("2011:12:30 12:00:00", zone: "Pacific/Apia"), .invalid(.nonexistentLocalTime, .exifOriginal))
    }

    func testPersistedFixedZonesAndFuturePOSIXFooterRules() throws {
        let fixed = try resolved(decode("2100:01:15 00:00:00", zone: "GMT+0530"))
        XCTAssertEqual(fixed.0.date.timeIntervalSince1970, 4_103_654_400 - 19_800)
        XCTAssertEqual(fixed.0.zoneSource, .persistedFallback(identifier: "GMT+0530"))
        let winter = try resolved(decode("2100:01:15 00:00:00", zone: "Europe/Oslo"))
        let summer = try resolved(decode("2100:07:15 00:00:00", zone: "Europe/Oslo"))
        XCTAssertEqual(winter.0.date.timeIntervalSince1970, 4_103_654_400 - 3_600)
        XCTAssertEqual(summer.0.date.timeIntervalSince1970, 4_119_292_800 - 7_200)
        XCTAssertEqual(decode("2100:04:04 01:45:00", zone: "Australia/Lord_Howe"),
                       .ambiguousLocalTime(.exifOriginal, persistedTimeZoneIdentifier: "Australia/Lord_Howe"))
        let ancient = try resolved(decode("1500:03:01 00:00:00Z"))
        let context = MetadataTemplateContext(processingDate: Date(timeIntervalSince1970: 0),
            processingTimeZone: TimeZone(secondsFromGMT: 0)!, captureDate: ancient.0)
        XCTAssertEqual(try MetadataTemplates.MetadataTemplate.parse("{dateCaptured:YYYY-MM-DD}").resolve(using: context),
                       .resolved("1500-03-01"))
    }

    func testMissingMalformedUnicodeNULAndOversizedValuesNeverFallBack() {
        XCTAssertEqual(decode(nil), .unavailable(.originalCaptureMissing))
        for value in ["", "2024:1:01 00:00:00", "2024-01-01T00:00:00", "２０２４:01:01 00:00:00",
                      "2024:01:01 00:00:00\0", " 2024:01:01 00:00:00", String(repeating: "9", count: 100_000)] {
            XCTAssertEqual(decode(value), .invalid(.malformedDate, .exifOriginal))
        }
    }

    private func exif(_ original: String, offset: String? = nil, fraction: String? = nil) -> ExifData {
        let values: [(UInt16, String?)] = [(ExifTag.dateTimeOriginal, original),
                                          (ExifTag.offsetTimeOriginal, offset), (ExifTag.subSecTimeOriginal, fraction)]
        var result = ExifData()
        result.exifIFD = IFD(entries: values.compactMap { tag, value in
            guard let value else { return nil }
            let data = Data((value + "\0").utf8)
            return IFDEntry(tag: tag, type: .ascii, count: UInt32(data.count), valueData: data)
        })
        return result
    }

    func testOriginalMetadataPrecedenceAndNoGenericCreateDateFallback() throws {
        var xmp = XMPData()
        xmp.exifDateTimeOriginal = "2024-01-02T03:04:05.25+05:45"
        var metadata = ImageMetadata(exif: exif("invalid"), xmp: xmp)
        XCTAssertEqual(Reader.read(metadata, persistedFallbackTimeZoneIdentifier: "GMT"), .invalid(.malformedDate, .exifOriginal))
        metadata.exif = nil
        var structured = xmp
        structured.setValue(.array(["2024-01-01T00:00:00Z"]), namespace: XMPNamespace.exif, property: "DateTimeOriginal")
        XCTAssertEqual(Reader.read(ImageMetadata(xmp: structured), persistedFallbackTimeZoneIdentifier: "GMT"),
                       .invalid(.malformedDate, .xmpOriginal))
        let result = try resolved(Reader.read(metadata, persistedFallbackTimeZoneIdentifier: nil))
        XCTAssertEqual(result.1.source, .xmpOriginal)
        XCTAssertEqual(result.1.nanosecond, 250_000_000)
        XCTAssertEqual(result.0.zoneSource, .explicitOffset(secondsFromGMT: 20700))
        xmp.exifDateTimeOriginal = nil
        xmp.createDate = "2024-01-01T00:00:00Z"
        metadata.xmp = xmp
        XCTAssertEqual(Reader.read(metadata, persistedFallbackTimeZoneIdentifier: "GMT"), .unavailable(.originalCaptureMissing))
    }

    func testPresentNonASCIIExifTagsAreInvalidRatherThanMissing() {
        var xmp = XMPData()
        xmp.exifDateTimeOriginal = "2024-01-01T00:00:00Z"
        for (tag, expected) in [(ExifTag.dateTimeOriginal, Reader.Invalid.malformedDate),
                                (ExifTag.offsetTimeOriginal, .malformedOffset),
                                (ExifTag.subSecTimeOriginal, .malformedSubseconds)] {
            var metadataExif = exif("2024:01:01 00:00:00")
            var entries = metadataExif.exifIFD!.entries.filter { $0.tag != tag }
            entries.append(IFDEntry(tag: tag, type: .short, count: 1, valueData: Data([0, 1])))
            metadataExif.exifIFD = IFD(entries: entries)
            XCTAssertEqual(Reader.read(ImageMetadata(exif: metadataExif, xmp: xmp), persistedFallbackTimeZoneIdentifier: "GMT"),
                           .invalid(expected, .exifOriginal))
        }
    }

    func testExplicitXMPSidecarReadUsesOnlyOriginalAndPreservesBytes() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("capture-xmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.XMP")
        var xmp = XMPData()
        xmp.exifDateTimeOriginal = "2024-02-29T23:59:59.875-03:30"
        try XMPSidecar.write(xmp, to: file)
        let before = try Data(contentsOf: file)
        let result = try resolved(Reader.read(from: file, persistedFallbackTimeZoneIdentifier: nil))
        XCTAssertEqual(result.1.source, .xmpOriginal)
        XCTAssertEqual(result.0.zoneSource, .explicitOffset(secondsFromGMT: -12600))
        XCTAssertEqual(result.1.nanosecond, 875_000_000)
        XCTAssertEqual(try Data(contentsOf: file), before)
        xmp.exifDateTimeOriginal = nil
        xmp.createDate = "2024-01-01T00:00:00Z"
        try XMPSidecar.write(xmp, to: file)
        XCTAssertEqual(Reader.read(from: file, persistedFallbackTimeZoneIdentifier: "GMT"), .unavailable(.originalCaptureMissing))
    }

    func testSyntheticJPEGReadUsesOriginalOffsetAndSubsecondsWithoutChangingFile() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("capture-date-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                                  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 100, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        var metadata = try ImageMetadata.read(from: file)
        metadata.exif = exif("2024:02:29 23:59:59", offset: "+14:00", fraction: "875")
        try metadata.write(to: file)
        let timestamp = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        let before = try Data(contentsOf: file)
        let result = try resolved(Reader.read(from: file, persistedFallbackTimeZoneIdentifier: "invalid/unused"))
        XCTAssertEqual(result.0.zoneSource, .explicitOffset(secondsFromGMT: 50400))
        XCTAssertEqual(result.1.nanosecond, 875_000_000)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, timestamp)
        XCTAssertEqual(Reader.read(from: root.appendingPathComponent("missing.jpg"), persistedFallbackTimeZoneIdentifier: "GMT"),
                       .unavailable(.metadataUnreadable))
    }
}
