import Foundation
import SwiftMediaMetadata

enum MetadataWriter {
    enum ApplicationAssessment: Equatable, Sendable {
        case willApply
        case alreadyApplied
        case existingMetadataPreserved
    }

    enum WriteResult {
        case embedded(size: Int64, warnings: [String])
        case sidecar(localURL: URL, size: Int64, warnings: [String])

        var warnings: [String] {
            switch self {
            case .embedded(_, let warnings), .sidecar(_, _, let warnings): warnings
            }
        }
    }

    static func usesXMPSidecar(for relativePath: String) -> Bool {
        guard let rawExtensions = FilterPreset.raw.extensions else { return false }
        return rawExtensions.contains(
            URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        )
    }

    static func sidecarRelativePath(for relativePath: String) -> String {
        (relativePath as NSString).deletingPathExtension + ".xmp"
    }

    static func schedulingDate(
        for policy: MetadataTimestampPolicy,
        sourceModifiedAt: Date,
        localArrivalAt: Date,
        fileURL: URL
    ) -> Date? {
        switch policy {
        case .sourceModification:
            sourceModifiedAt
        case .localArrival:
            localArrivalAt
        case .cameraCapture:
            captureDate(from: fileURL)
        }
    }

    static func captureDate(from fileURL: URL, localTimeZone: TimeZone = .current) -> Date? {
        guard let metadata = try? ImageMetadata.read(from: fileURL),
              let exif = metadata.exif,
              let value = CompositeTagCalculator.subSecDateTimeOriginal(exif) else {
            return nil
        }
        return parseExifDate(value, localTimeZone: localTimeZone)
    }

    static func assess(
        _ assignment: MetadataAssignment,
        at fileURL: URL,
        relativePath: String
    ) throws -> ApplicationAssessment {
        if usesXMPSidecar(for: relativePath) {
            let sidecarURL = fileURL.deletingPathExtension().appendingPathExtension("xmp")
            guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
                return .willApply
            }
            return assessment(for: assignment, xmp: try XMPSidecar.read(from: sidecarURL))
        }

        return assessment(for: assignment, metadata: try ImageMetadata.read(from: fileURL))
    }

    static func parseExifDate(_ value: String, localTimeZone: TimeZone = .current) -> Date? {
        let pattern = #"^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.range == NSRange(value.startIndex..., in: value) else {
            return nil
        }

        func component(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
            return Int(value[swiftRange])
        }

        guard let year = component(1),
              let month = component(2),
              let day = component(3),
              let hour = component(4),
              let minute = component(5),
              let second = component(6) else {
            return nil
        }

        let fractionalRange = match.range(at: 7)
        let nanosecond: Int
        if fractionalRange.location != NSNotFound,
           let range = Range(fractionalRange, in: value) {
            let digits = String(value[range].prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
            nanosecond = Int(digits) ?? 0
        } else {
            nanosecond = 0
        }

        let zoneRange = match.range(at: 8)
        let timeZone: TimeZone
        if zoneRange.location == NSNotFound {
            timeZone = localTimeZone
        } else if let range = Range(zoneRange, in: value) {
            let zone = String(value[range])
            if zone == "Z" {
                timeZone = TimeZone(secondsFromGMT: 0)!
            } else {
                let sign = zone.first == "-" ? -1 : 1
                let parts = zone.dropFirst().split(separator: ":")
                guard parts.count == 2,
                      let hours = Int(parts[0]),
                      let minutes = Int(parts[1]),
                      let parsed = TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60)) else {
                    return nil
                }
                timeZone = parsed
            }
        } else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            nanosecond: nanosecond
        ))
    }

    @discardableResult
    static func apply(_ assignment: MetadataAssignment, to fileURL: URL) throws -> [String] {
        var metadata = try ImageMetadata.read(from: fileURL)
        let readWarnings = metadata.warnings
        let fields = assignment.clip.fields

        let headline = fields.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = fields.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = assignment.photographer.photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyright = assignment.photographer.copyrightNotice.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = fields.normalizedKeywords
        let shouldOverwrite = assignment.existingFieldPolicy == .overwrite

        if !headline.isEmpty,
           shouldOverwrite || (isEmpty(metadata.iptc.headline) && isEmpty(metadata.xmp?.headline)) {
            try metadata.iptc.setValue(headline, for: .headline)
        }
        if !description.isEmpty,
           shouldOverwrite || (isEmpty(metadata.iptc.caption) && isEmpty(metadata.xmp?.description)) {
            try metadata.iptc.setValue(description, for: .captionAbstract)
        }
        if !keywords.isEmpty,
           shouldOverwrite || (metadata.iptc.keywords.isEmpty && (metadata.xmp?.subject.isEmpty ?? true)) {
            try metadata.iptc.setValues(keywords, for: .keywords)
        }
        if !creator.isEmpty,
           shouldOverwrite || (isEmpty(metadata.iptc.byline) && (metadata.xmp?.creator.isEmpty ?? true)) {
            try metadata.iptc.setValue(creator, for: .byline)
        }
        if !copyright.isEmpty,
           shouldOverwrite || (isEmpty(metadata.iptc.copyright) && isEmpty(metadata.xmp?.rights)) {
            try metadata.iptc.setValue(copyright, for: .copyrightNotice)
        }
        metadata.syncIPTCToXMP()
        let writeWarnings = try metadata.write(to: fileURL)
        return uniqueWarnings(readWarnings + writeWarnings)
    }

    static func apply(
        _ assignment: MetadataAssignment,
        to fileURL: URL,
        relativePath: String
    ) throws -> WriteResult {
        guard usesXMPSidecar(for: relativePath) else {
            let warnings = try apply(assignment, to: fileURL)
            return .embedded(size: try fileSize(at: fileURL), warnings: warnings)
        }

        let sidecarURL = fileURL.deletingPathExtension().appendingPathExtension("xmp")
        var xmp = (try? XMPSidecar.read(from: sidecarURL)) ?? XMPData()
        var warnings: [String] = []
        if !FileManager.default.fileExists(atPath: sidecarURL.path),
           var metadata = try? ImageMetadata.read(from: fileURL) {
            // Preserve the RAW file's existing XMP and mirror any legacy IPTC fields
            // into the generated sidecar before applying the programmed values.
            warnings.append(contentsOf: metadata.warnings)
            metadata.syncIPTCToXMP()
            xmp = metadata.xmp ?? xmp
        }
        apply(assignment, to: &xmp)

        try XMPSidecar.write(xmp, to: sidecarURL)
        return .sidecar(
            localURL: sidecarURL,
            size: try fileSize(at: sidecarURL),
            warnings: uniqueWarnings(warnings)
        )
    }

    private static func apply(_ assignment: MetadataAssignment, to xmp: inout XMPData) {
        let fields = assignment.clip.fields
        let headline = fields.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = fields.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = assignment.photographer.photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyright = assignment.photographer.copyrightNotice.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = fields.normalizedKeywords
        let shouldOverwrite = assignment.existingFieldPolicy == .overwrite

        if !headline.isEmpty, shouldOverwrite || isEmpty(xmp.headline) {
            xmp.headline = headline
        }
        if !description.isEmpty, shouldOverwrite || isEmpty(xmp.description) {
            xmp.description = description
        }
        if !keywords.isEmpty, shouldOverwrite || xmp.subject.isEmpty {
            xmp.subject = keywords
        }
        if !creator.isEmpty, shouldOverwrite || xmp.creator.isEmpty {
            xmp.creator = [creator]
        }
        if !copyright.isEmpty, shouldOverwrite || isEmpty(xmp.rights) {
            xmp.rights = copyright
        }
    }

    private enum FieldAssessment: Equatable {
        case matches
        case willChange
        case preserved
    }

    private static func assessment(
        for assignment: MetadataAssignment,
        metadata: ImageMetadata
    ) -> ApplicationAssessment {
        let fields = assignment.clip.fields
        let overwrite = assignment.existingFieldPolicy == .overwrite
        var assessments: [FieldAssessment] = []

        assess(
            fields.headline,
            currentValues: [metadata.iptc.headline, metadata.xmp?.headline],
            overwrite: overwrite,
            into: &assessments
        )
        assess(
            fields.description,
            currentValues: [metadata.iptc.caption, metadata.xmp?.description],
            overwrite: overwrite,
            into: &assessments
        )
        assess(
            fields.normalizedKeywords,
            currentValues: [metadata.iptc.keywords, metadata.xmp?.subject ?? []],
            overwrite: overwrite,
            into: &assessments
        )
        assess(
            assignment.photographer.photographerName,
            currentValues: [metadata.iptc.byline] + (metadata.xmp?.creator.map(Optional.some) ?? []),
            overwrite: overwrite,
            into: &assessments
        )
        assess(
            assignment.photographer.copyrightNotice,
            currentValues: [metadata.iptc.copyright, metadata.xmp?.rights],
            overwrite: overwrite,
            into: &assessments
        )

        return combinedAssessment(assessments)
    }

    private static func assessment(
        for assignment: MetadataAssignment,
        xmp: XMPData
    ) -> ApplicationAssessment {
        let fields = assignment.clip.fields
        let overwrite = assignment.existingFieldPolicy == .overwrite
        var assessments: [FieldAssessment] = []

        assess(fields.headline, currentValues: [xmp.headline], overwrite: overwrite, into: &assessments)
        assess(fields.description, currentValues: [xmp.description], overwrite: overwrite, into: &assessments)
        assess(fields.normalizedKeywords, currentValues: [xmp.subject], overwrite: overwrite, into: &assessments)
        assess(
            assignment.photographer.photographerName,
            currentValues: xmp.creator.map(Optional.some),
            overwrite: overwrite,
            into: &assessments
        )
        assess(
            assignment.photographer.copyrightNotice,
            currentValues: [xmp.rights],
            overwrite: overwrite,
            into: &assessments
        )

        return combinedAssessment(assessments)
    }

    private static func assess(
        _ desiredValue: String,
        currentValues: [String?],
        overwrite: Bool,
        into assessments: inout [FieldAssessment]
    ) {
        let desired = desiredValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desired.isEmpty else { return }
        let populated = currentValues.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if !populated.isEmpty, populated.allSatisfy({ $0 == desired }) {
            assessments.append(.matches)
        } else if overwrite || populated.isEmpty {
            assessments.append(.willChange)
        } else {
            assessments.append(.preserved)
        }
    }

    private static func assess(
        _ desiredValues: [String],
        currentValues: [[String]],
        overwrite: Bool,
        into assessments: inout [FieldAssessment]
    ) {
        guard !desiredValues.isEmpty else { return }
        let populated = currentValues.filter { !$0.isEmpty }
        if !populated.isEmpty, populated.allSatisfy({ $0 == desiredValues }) {
            assessments.append(.matches)
        } else if overwrite || populated.isEmpty {
            assessments.append(.willChange)
        } else {
            assessments.append(.preserved)
        }
    }

    private static func combinedAssessment(_ assessments: [FieldAssessment]) -> ApplicationAssessment {
        if assessments.contains(where: { $0 == .willChange }) {
            return .willApply
        }
        if assessments.contains(where: { $0 == .preserved }) {
            return .existingMetadataPreserved
        }
        return .alreadyApplied
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func isEmpty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private static func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(warning).inserted
        }
    }
}
