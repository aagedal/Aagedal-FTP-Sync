import Foundation
import MetadataTemplates
import SwiftMediaMetadata

/// Strict original-capture decoding for frozen variable contexts. This deliberately
/// does not change MetadataWriter's legacy scheduling parser. Reads never write a
/// photo/sidecar, consult file modification dates, or use the current clock/zone.
enum MetadataCaptureDateReader {
    enum Source: String, Equatable, Sendable { case exifOriginal, xmpOriginal }
    enum Unavailable: Equatable, Sendable { case originalCaptureMissing, metadataUnreadable }
    enum Invalid: Equatable, Sendable {
        case malformedDate, calendarComponents, malformedOffset, conflictingOffsets
        case malformedSubseconds, conflictingSubseconds, missingFallbackZone, invalidFallbackZone
        case nonexistentLocalTime
    }
    struct Provenance: Equatable, Sendable {
        let source: Source
        /// Exact original value; bounded to 64 ASCII bytes by the decoder.
        let original: String
        /// Exact nanoseconds decoded before Foundation Date's floating-point rounding.
        let nanosecond: Int
        let zoneSource: MetadataCaptureDate.ZoneSource
    }
    enum Result: Equatable, Sendable {
        case resolved(MetadataCaptureDate, Provenance)
        case unavailable(Unavailable)
        case invalid(Invalid, Source)
        /// A repeated local time is not enough evidence to choose either instant.
        /// A supplied explicit offset resolves this case; never silently choose a fold.
        case ambiguousLocalTime(Source, persistedTimeZoneIdentifier: String)
    }

    static func read(from url: URL, persistedFallbackTimeZoneIdentifier: String?) -> Result {
        guard url.isFileURL else { return .unavailable(.metadataUnreadable) }
        if url.pathExtension.lowercased() == "xmp" {
            guard let xmp = try? XMPSidecar.read(from: url) else { return .unavailable(.metadataUnreadable) }
            return readOriginalXMP(xmp, persistedFallbackTimeZoneIdentifier: persistedFallbackTimeZoneIdentifier)
        }
        guard let metadata = try? ImageMetadata.read(from: url) else { return .unavailable(.metadataUnreadable) }
        return read(metadata, persistedFallbackTimeZoneIdentifier: persistedFallbackTimeZoneIdentifier)
    }

    /// EXIF original takes precedence even when malformed. XMP's EXIF-original
    /// property is considered only when the EXIF original tag is absent. No use of
    /// xmp:CreateDate, digitized time, or generic EXIF DateTime. A RAW sidecar can be
    /// selected by the future caller; this reader does not silently change carriers.
    static func read(_ metadata: ImageMetadata, persistedFallbackTimeZoneIdentifier: String?) -> Result {
        if let exif = metadata.exif, exif.exifIFD?.entry(for: ExifTag.dateTimeOriginal) != nil {
            guard let original = exif.dateTimeOriginal else { return .invalid(.malformedDate, .exifOriginal) }
            if exif.exifIFD?.entry(for: ExifTag.offsetTimeOriginal) != nil, exif.offsetTimeOriginal == nil {
                return .invalid(.malformedOffset, .exifOriginal)
            }
            if exif.exifIFD?.entry(for: ExifTag.subSecTimeOriginal) != nil, exif.subSecTimeOriginal == nil {
                return .invalid(.malformedSubseconds, .exifOriginal)
            }
            return decode(original: original, offset: exif.offsetTimeOriginal,
                          subseconds: exif.subSecTimeOriginal,
                          persistedFallbackTimeZoneIdentifier: persistedFallbackTimeZoneIdentifier)
        }
        return readOriginalXMP(metadata.xmp, persistedFallbackTimeZoneIdentifier: persistedFallbackTimeZoneIdentifier)
    }

    private static func readOriginalXMP(_ xmp: XMPData?, persistedFallbackTimeZoneIdentifier: String?) -> Result {
        guard let value = xmp?.value(namespace: XMPNamespace.exif, property: "DateTimeOriginal") else {
            return .unavailable(.originalCaptureMissing)
        }
        guard case .simple(let original) = value else { return .invalid(.malformedDate, .xmpOriginal) }
        return decode(original: original, source: .xmpOriginal,
                      persistedFallbackTimeZoneIdentifier: persistedFallbackTimeZoneIdentifier)
    }

    /// EXIF: YYYY:MM:DD HH:mm:ss; XMP: YYYY-MM-DDTHH:mm:ss. Both allow
    /// .1–9 fractional digits and Z/±HH:mm. Separate EXIF fields must agree with
    /// embedded components. Empty or padded values are invalid, not absent.
    static func decode(
        original: String?, source: Source = .exifOriginal, offset: String? = nil,
        subseconds: String? = nil, persistedFallbackTimeZoneIdentifier: String?
    ) -> Result {
        guard let original else { return .unavailable(.originalCaptureMissing) }
        func invalid(_ reason: Invalid) -> Result { .invalid(reason, source) }
        let bytes = Array(original.utf8.prefix(65))
        guard (19...64).contains(bytes.count), bytes.allSatisfy({ $0 > 0 && $0 < 128 }) else {
            return invalid(.malformedDate)
        }
        let separator: UInt8 = source == .exifOriginal ? 58 : 45
        guard bytes[4] == separator, bytes[7] == separator,
              bytes[10] == (source == .exifOriginal ? 32 : 84), bytes[13] == 58, bytes[16] == 58 else {
            return invalid(.malformedDate)
        }
        func number(_ range: Range<Int>) -> Int? {
            let digits = bytes[range]
            guard digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return digits.reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else {
            return invalid(.malformedDate)
        }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...9999).contains(year), (1...12).contains(month), (1...lengths[month - 1]).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            return invalid(.calendarComponents)
        }
        var position = 19
        var embeddedFraction: String?
        if position < bytes.count, bytes[position] == 46 {
            position += 1
            let start = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            embeddedFraction = String(decoding: bytes[start..<position], as: UTF8.self)
        }
        let embeddedOffset = position == bytes.count ? nil : String(decoding: bytes[position...], as: UTF8.self)
        func fraction(_ value: String) -> Int? {
            let digits = Array(value.utf8.prefix(10))
            guard (1...9).contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return digits.reduce(0) { $0 * 10 + Int($1 - 48) } * Int(pow(10.0, Double(9 - digits.count)))
        }
        var nanosecond = 0
        if let embeddedFraction {
            guard let parsed = fraction(embeddedFraction) else { return invalid(.malformedSubseconds) }
            nanosecond = parsed
        }
        if let subseconds {
            guard let parsed = fraction(subseconds) else { return invalid(.malformedSubseconds) }
            guard embeddedFraction == nil || parsed == nanosecond else { return invalid(.conflictingSubseconds) }
            nanosecond = parsed
        }
        func offsetSeconds(_ value: String) -> Int? {
            if value == "Z" { return 0 }
            let digits = Array(value.utf8.prefix(7))
            guard digits.count == 6, digits[0] == 43 || digits[0] == 45, digits[3] == 58,
                  [1, 2, 4, 5].allSatisfy({ (48...57).contains(digits[$0]) }) else { return nil }
            let hours = Int(digits[1] - 48) * 10 + Int(digits[2] - 48)
            let minutes = Int(digits[4] - 48) * 10 + Int(digits[5] - 48)
            guard hours <= 14, minutes <= 59, hours < 14 || minutes == 0 else { return nil }
            return (digits[0] == 45 ? -1 : 1) * (hours * 3600 + minutes * 60)
        }
        var explicitOffset: Int?
        if let embeddedOffset {
            guard let parsed = offsetSeconds(embeddedOffset) else { return invalid(.malformedOffset) }
            explicitOffset = parsed
        }
        if let offset {
            guard let parsed = offsetSeconds(offset) else { return invalid(.malformedOffset) }
            guard explicitOffset == nil || parsed == explicitOffset else { return invalid(.conflictingOffsets) }
            explicitOffset = parsed
        }
        // Pure proleptic Gregorian civil-to-day conversion. Calendar.date(from:)
        // normalizes impossible components and uses a historical Julian cutover.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let days = era * 146097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719468
        let wallSeconds = Double(days * 86400 + hour * 3600 + minute * 60 + second)
        let zoneSource: MetadataCaptureDate.ZoneSource
        let instant: Date
        if let explicitOffset {
            zoneSource = .explicitOffset(secondsFromGMT: explicitOffset)
            instant = Date(timeIntervalSince1970: wallSeconds - Double(explicitOffset))
        } else {
            guard let identifier = persistedFallbackTimeZoneIdentifier, !identifier.isEmpty else {
                return invalid(.missingFallbackZone)
            }
            guard identifier.utf8.count <= 255, !identifier.utf8.contains(0),
                  let zone = TimeZone(identifier: identifier) else { return invalid(.invalidFallbackZone) }
            zoneSource = .persistedFallback(identifier: identifier)
            guard let offsets = knownOffsets(identifier: identifier) else { return invalid(.invalidFallbackZone) }
            // Test every offset that this zone's rules can use, including its
            // future POSIX rule. This catches non-hour folds that Foundation's
            // Calendar .first/.last matching can collapse into the same instant.
            let candidates = offsets.compactMap { offset -> Date? in
                let candidate = Date(timeIntervalSince1970: wallSeconds - Double(offset))
                return zone.secondsFromGMT(for: candidate) == offset ? candidate : nil
            }.sorted()
            guard let first = candidates.first else { return invalid(.nonexistentLocalTime) }
            guard candidates.count == 1 else { return .ambiguousLocalTime(source, persistedTimeZoneIdentifier: identifier) }
            instant = first
        }
        // Validate wall-clock seconds before adding the fraction. Date stores a
        // Double; keep exact nanoseconds separately rather than demand an inexact
        // nanosecond round-trip or accidentally accept normalized seconds.
        let wholeSecond = instant.timeIntervalSinceReferenceDate
        let fractionalSecond = wholeSecond + Double(nanosecond) / 1_000_000_000
        // Rounding .999999999 must never advance the original civil date. Keep
        // the representable value in its original second; exact input is retained.
        let unixUpperBound = Date(timeIntervalSince1970: (instant.timeIntervalSince1970 + 1).nextDown)
            .timeIntervalSinceReferenceDate
        let boundedSecond = min(fractionalSecond, (wholeSecond + 1).nextDown, unixUpperBound)
        guard let capture = MetadataCaptureDate(date: Date(timeIntervalSinceReferenceDate: boundedSecond),
                                               zoneSource: zoneSource) else { return invalid(.invalidFallbackZone) }
        return .resolved(capture, Provenance(source: source, original: original, nanosecond: nanosecond, zoneSource: zoneSource))
    }

    /// Reads only UTC-offset type records and footer offsets from Foundation's
    /// own bounded TZif data. Foundation remains authoritative for which offset
    /// applies at each candidate instant. Layout: RFC 9636 sections 3.1–3.3.
    /// https://www.rfc-editor.org/rfc/rfc9636.html
    private static func knownOffsets(identifier: String) -> Set<Int>? {
        guard let native = NSTimeZone(name: identifier) else { return nil }
        let data = native.data
        if data.isEmpty {
            // Foundation represents generated fixed zones (including aliases
            // such as GMT+05:30) by a canonical GMT±HHmm name without TZif data.
            let name = Array(native.name.utf8)
            guard name.count == 8, Array(name[0..<3]) == [71, 77, 84],
                  name[3] == 43 || name[3] == 45,
                  name[4..<8].allSatisfy({ (48...57).contains($0) }) else { return nil }
            let hours = Int(name[4] - 48) * 10 + Int(name[5] - 48)
            let minutes = Int(name[6] - 48) * 10 + Int(name[7] - 48)
            guard hours <= 18, minutes < 60 else { return nil }
            let seconds = (name[3] == 45 ? -1 : 1) * (hours * 3600 + minutes * 60)
            guard NSTimeZone(forSecondsFromGMT: seconds).name == native.name else { return nil }
            return [seconds]
        }
        guard (44...1_048_576).contains(data.count) else { return nil }
        let bytes = Array(data)
        var offsets = Set<Int>()
        func unsigned(_ at: Int) -> UInt32 {
            bytes[at..<at + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func block(at start: Int, timeSize: Int) -> Int? {
            guard start >= 0, start + 44 <= bytes.count,
                  Array(bytes[start..<start + 4]) == [84, 90, 105, 102] else { return nil }
            let counts = stride(from: start + 20, to: start + 44, by: 4).map { Int(unsigned($0)) }
            guard counts.allSatisfy({ $0 <= 1_048_576 }), (1...256).contains(counts[4]) else { return nil }
            let types = start + 44 + counts[3] * (timeSize + 1)
            let end = types + counts[4] * 6 + counts[5] + counts[2] * (timeSize + 4) + counts[1] + counts[0]
            guard end <= bytes.count else { return nil }
            for index in 0..<counts[4] {
                let offset = Int(Int32(bitPattern: unsigned(types + index * 6)))
                guard (-93_600...93_600).contains(offset) else { return nil }
                offsets.insert(offset)
            }
            return end
        }
        guard let firstEnd = block(at: 0, timeSize: 4) else { return nil }
        if bytes[4] == 0 { return offsets }
        guard [50, 51, 52].contains(bytes[4]), let end = block(at: firstEnd, timeSize: 8) else { return nil }
        let footer = String(decoding: bytes[end...], as: UTF8.self).trimmingCharacters(in: .newlines)
        if footer.isEmpty { return offsets }
        // POSIX zone offsets have the opposite sign to seconds east of UTC.
        // Transition rules after the first comma do not introduce other offsets.
        let pattern = #"^(<[^>]+>|[A-Za-z]{3,})([+-]?[0-9]{1,3}(?::[0-9]{1,2}){0,2})(?:(<[^>]+>|[A-Za-z]{3,})([+-]?[0-9]{1,3}(?::[0-9]{1,2}){0,2})?)?(?:,|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: footer, range: NSRange(footer.startIndex..., in: footer)) else { return nil }
        func value(_ group: Int) -> String? {
            guard let range = Range(match.range(at: group), in: footer) else { return nil }
            return String(footer[range])
        }
        func parse(_ value: String) -> Int? {
            let sign = value.first == "-" ? -1 : 1
            let raw = value.first == "-" || value.first == "+" ? String(value.dropFirst()) : value
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard (1...3).contains(parts.count), parts[0] <= 26,
                  parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            let seconds = parts[0] * 3600 + (parts.count > 1 ? parts[1] * 60 : 0) + (parts.count > 2 ? parts[2] : 0)
            guard seconds <= 93_600 else { return nil }
            return -sign * seconds
        }
        guard let standardText = value(2), let standard = parse(standardText) else { return nil }
        offsets.insert(standard)
        if value(3) != nil {
            if let daylightText = value(4) {
                guard let daylight = parse(daylightText) else { return nil }
                offsets.insert(daylight)
            } else { offsets.insert(standard + 3600) }
        }
        return offsets
    }
}
