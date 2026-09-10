import Foundation

public enum MetadataTemplateVariable: String, CaseIterable, Hashable, Sendable {
    case processingDate, captureDate, photographer, city, country, persons
}

public enum MetadataTemplateParseError: Error, Equatable, Sendable {
    case sourceLimitExceeded(maxUTF8Bytes: Int)
    case unmatchedOpeningBrace(utf8Offset: Int)
    case unmatchedClosingBrace(utf8Offset: Int)
    case nestedOpeningBrace(utf8Offset: Int)
    case unknownToken(String, utf8Offset: Int)
    case unsupportedDateFormat(String, utf8Offset: Int)
}

public enum MetadataTemplatePreservationReason: Equatable, Sendable {
    case missingValues(Set<MetadataTemplateVariable>)
    case invalidDate(MetadataTemplateVariable)
    case outputLimitExceeded(maxUTF8Bytes: Int)
    case keywordEntryLimitExceeded(maxEntries: Int)
}

/// A preservation outcome contains no partially resolved text that could accidentally be published.
public enum MetadataTemplateOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case resolved(Value)
    case preserveExisting(MetadataTemplatePreservationReason)
}

/// Version 1 of the opt-in template language. Parse only records explicitly activated by the caller;
/// legacy strings must bypass this API unchanged, including their original braces.
public struct MetadataTemplate: Equatable, Sendable {
    public static let languageVersion = 1
    public static let maximumSourceUTF8Bytes = 16_384
    public static let maximumOutputUTF8Bytes = 65_536
    public static let maximumKeywordEntries = 1_024

    public let source: String
    public let requiredVariables: Set<MetadataTemplateVariable>
    private let segments: [Segment]

    private enum Segment: Equatable, Sendable {
        case literal(String)
        case variable(MetadataTemplateVariable)
    }

    public static func parse(_ source: String) throws -> Self {
        guard source.utf8.count <= maximumSourceUTF8Bytes else {
            throw MetadataTemplateParseError.sourceLimitExceeded(maxUTF8Bytes: maximumSourceUTF8Bytes)
        }
        let bytes = Array(source.utf8)
        var segments: [Segment] = []
        var literal: [UInt8] = []
        var required = Set<MetadataTemplateVariable>()
        var index = 0
        func flushLiteral() {
            guard !literal.isEmpty else { return }
            segments.append(.literal(String(decoding: literal, as: UTF8.self)))
            literal.removeAll(keepingCapacity: true)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if (byte == 123 || byte == 125), index + 1 < bytes.count, bytes[index + 1] == byte {
                literal.append(byte)
                index += 2
            } else if byte == 123 {
                flushLiteral()
                let opening = index
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != 125 {
                    guard bytes[index] != 123 else {
                        throw MetadataTemplateParseError.nestedOpeningBrace(utf8Offset: index)
                    }
                    index += 1
                }
                guard index < bytes.count else {
                    throw MetadataTemplateParseError.unmatchedOpeningBrace(utf8Offset: opening)
                }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                let variable = try parseToken(token, offset: opening)
                required.insert(variable)
                segments.append(.variable(variable))
                index += 1
            } else if byte == 125 {
                throw MetadataTemplateParseError.unmatchedClosingBrace(utf8Offset: index)
            } else {
                literal.append(byte)
                index += 1
            }
        }
        flushLiteral()
        return Self(source: source, requiredVariables: required, segments: segments)
    }

    private static func parseToken(_ token: String, offset: Int) throws -> MetadataTemplateVariable {
        switch token {
        case "photographer": return .photographer
        case "gps:city": return .city
        case "gps:country": return .country
        case "persons": return .persons
        case "date:YYYY-MM-DD", "date:yyyy-MM-dd": return .processingDate
        case "dateCaptured:YYYY-MM-DD", "dateCaptured:yyyy-MM-dd": return .captureDate
        default:
            if token == "date" || token == "dateCaptured" || token.hasPrefix("date:") || token.hasPrefix("dateCaptured:") {
                throw MetadataTemplateParseError.unsupportedDateFormat(token, utf8Offset: offset)
            }
            throw MetadataTemplateParseError.unknownToken(token, utf8Offset: offset)
        }
    }

    public func resolve(using context: MetadataTemplateContext) -> MetadataTemplateOutcome<String> {
        var values: [MetadataTemplateVariable: String] = [:]
        var missing = Set<MetadataTemplateVariable>()
        // Stable order makes diagnostics deterministic if several inputs are invalid.
        for variable in MetadataTemplateVariable.allCases where requiredVariables.contains(variable) {
            let value: String?
            switch variable {
            case .processingDate:
                guard let formatted = Self.formatDate(context.processingDate, zone: context.processingTimeZone) else {
                    return .preserveExisting(.invalidDate(variable))
                }
                value = formatted
            case .captureDate:
                if let capture = context.captureDate {
                    guard let formatted = Self.formatDate(capture.date, zone: capture.timeZone) else {
                        return .preserveExisting(.invalidDate(variable))
                    }
                    value = formatted
                } else { value = nil }
            case .photographer: value = context.photographer
            case .city: value = context.city
            case .country: value = context.country
            case .persons:
                // Bound before joining; the context is external data, not template syntax.
                let names = context.persons ?? []
                var bytes = 0
                var nonempty: [String] = []
                for name in names {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let count = name.utf8.count
                    let separatorBytes = nonempty.isEmpty ? 0 : 2
                    guard count <= Self.maximumOutputUTF8Bytes - bytes - separatorBytes else {
                        return .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: Self.maximumOutputUTF8Bytes))
                    }
                    bytes += count + separatorBytes
                    nonempty.append(name)
                }
                value = nonempty.isEmpty ? nil : nonempty.joined(separator: ", ")
            }
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard value.utf8.count <= Self.maximumOutputUTF8Bytes else {
                    return .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: Self.maximumOutputUTF8Bytes))
                }
                values[variable] = value
            } else { missing.insert(variable) }
        }
        guard missing.isEmpty else { return .preserveExisting(.missingValues(missing)) }
        var result = ""
        var size = 0
        for segment in segments {
            let value: String
            switch segment {
            case .literal(let text): value = text
            case .variable(let variable): value = values[variable]!
            }
            guard value.utf8.count <= Self.maximumOutputUTF8Bytes - size else {
                return .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: Self.maximumOutputUTF8Bytes))
            }
            size += value.utf8.count
            result.append(value)
        }
        return .resolved(result)
    }

    private static func formatDate(_ date: Date, zone: TimeZone) -> String? {
        let interval = date.timeIntervalSinceReferenceDate
        // Bound conversion before querying the zone or converting to integers.
        // All supported civil years (1–9999), including their zone offsets, fit.
        guard interval.isFinite, abs(interval) < 1_000_000_000_000 else { return nil }
        // Date's reference epoch is 2001-01-01. Floor its stored value BEFORE
        // adding the Unix epoch/zone offsets: floating-point epoch conversion can
        // otherwise round a representable instant just before midnight forward.
        let seconds = Int64(floor(interval)) + 978_307_200 + Int64(zone.secondsFromGMT(for: date))
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        // Proleptic Gregorian civil-from-days conversion, independent of locale
        // and Foundation Calendar's Julian/Gregorian cutover in October 1582.
        let shiftedDays = days + 719_468
        let era = (shiftedDays >= 0 ? shiftedDays : shiftedDays - 146_096) / 146_097
        let dayOfEra = shiftedDays - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = Int(dayOfYear - (153 * shiftedMonth + 2) / 5 + 1)
        let month = Int(shiftedMonth + (shiftedMonth < 10 ? 3 : -9))
        let year = Int(yearOfEra + era * 400 + (month <= 2 ? 1 : 0))
        guard (1...9999).contains(year) else { return nil }
        func padded(_ number: Int, width: Int) -> String {
            let value = String(number)
            return String(repeating: "0", count: max(0, width - value.count)) + value
        }
        return "\(padded(year, width: 4))-\(padded(month, width: 2))-\(padded(day, width: 2))"
    }

    /// Resolve every entry before returning any keywords. A comma in a value is never a separator.
    /// Returns only the scheduled list; the caller may independently append accepted face names.
    public static func resolveKeywords(
        _ templates: [Self], using context: MetadataTemplateContext
    ) -> MetadataTemplateOutcome<[String]> {
        guard templates.count <= maximumKeywordEntries else {
            return .preserveExisting(.keywordEntryLimitExceeded(maxEntries: maximumKeywordEntries))
        }
        var result: [String] = []
        var seen = Set<String>()
        var missing = Set<MetadataTemplateVariable>()
        var size = 0
        for template in templates {
            switch template.resolve(using: context) {
            case .preserveExisting(.missingValues(let values)):
                missing.formUnion(values)
            case .preserveExisting(let reason): return .preserveExisting(reason)
            case .resolved(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard seen.insert(key).inserted else { continue }
                guard trimmed.utf8.count <= maximumOutputUTF8Bytes - size else {
                    return .preserveExisting(.outputLimitExceeded(maxUTF8Bytes: maximumOutputUTF8Bytes))
                }
                size += trimmed.utf8.count
                result.append(trimmed)
            }
        }
        return missing.isEmpty ? .resolved(result) : .preserveExisting(.missingValues(missing))
    }
}
