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

    // Legacy callers freeze their literal source at this boundary. New processing
    // paths can pass the same ResolvedMetadataChanges to assess and apply.
    static func assess(_ assignment: MetadataAssignment, at fileURL: URL, relativePath: String) throws -> ApplicationAssessment {
        try assess(.literal(assignment), at: fileURL, relativePath: relativePath)
    }

    @discardableResult
    static func apply(_ assignment: MetadataAssignment, to fileURL: URL) throws -> [String] {
        try apply(.literal(assignment), to: fileURL)
    }

    static func apply(_ assignment: MetadataAssignment, to fileURL: URL, relativePath: String) throws -> WriteResult {
        try apply(.literal(assignment), to: fileURL, relativePath: relativePath)
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

    /// In-memory preview values only. Keep carriers separate when embedded IPTC
    /// and XMP disagree; neither is silently presented as the sole existing value.
    struct ExistingFieldsSnapshot: Equatable, Sendable {
        enum Value: Equatable, Sendable {
            case text(String), list([String]), position(ScheduledGPSPosition)
        }
        struct Carrier: Equatable, Sendable {
            let name: String
            let fields: [MetadataWritableField: Value]
            let personInImage: [String]

            init(name: String, fields: [MetadataWritableField: Value], personInImage: [String] = []) {
                self.name = name
                self.fields = fields
                self.personInImage = personInImage
            }
        }
        let carriers: [Carrier]
        let readable: Bool
    }

    static func existingFields(at fileURL: URL, relativePath: String) throws -> ExistingFieldsSnapshot {
        func xmpFields(_ xmp: XMPData) -> [MetadataWritableField: ExistingFieldsSnapshot.Value] {
            var fields: [MetadataWritableField: ExistingFieldsSnapshot.Value] = [:]
            if let value = xmp.headline, !value.isEmpty { fields[.headline] = .text(value) }
            if let value = xmp.description, !value.isEmpty { fields[.description] = .text(value) }
            if !xmp.subject.isEmpty { fields[.keywords] = .list(xmp.subject) }
            if !xmp.creator.isEmpty { fields[.creator] = .list(xmp.creator) }
            if let value = xmp.rights, !value.isEmpty { fields[.copyright] = .text(value) }
            if let value = MetadataCoordinateReader.xmpPosition(in: xmp) { fields[.gpsPosition] = .position(value) }
            return fields
        }
        if usesXMPSidecar(for: relativePath) {
            let existing = try rawPolicyMetadata(at: fileURL)
            let embedded = try? ImageMetadata.read(from: fileURL)
            var fields = xmpFields(existing.xmp)
            let sidecar = fileURL.deletingPathExtension().appendingPathExtension("xmp")
            if !FileManager.default.fileExists(atPath: sidecar.path) {
                // Keep the legacy text seed while displaying GPS only from strict
                // original carriers, never the legacy parser's fabricated zero.
                let gps = embedded?.xmp.flatMap { MetadataCoordinateReader.xmpPosition(in: $0) }
                    ?? embedded.flatMap { MetadataCoordinateReader.embeddedPosition(in: $0) }
                fields[.gpsPosition] = gps.map { .position($0) }
            }
            var carriers: [ExistingFieldsSnapshot.Carrier] = [
                .init(name: existing.origin, fields: fields, personInImage: existing.xmp.personInImage)
            ]
            if let embedded, let gps = MetadataCoordinateReader.embeddedPosition(in: embedded) {
                carriers.append(.init(name: "Embedded EXIF", fields: [.gpsPosition: .position(gps)]))
            }
            return ExistingFieldsSnapshot(carriers: carriers, readable: existing.readable)
        }
        let metadata = try ImageMetadata.read(from: fileURL)
        var iptc: [MetadataWritableField: ExistingFieldsSnapshot.Value] = [:]
        if let value = metadata.iptc.headline, !value.isEmpty { iptc[.headline] = .text(value) }
        if let value = metadata.iptc.caption, !value.isEmpty { iptc[.description] = .text(value) }
        if !metadata.iptc.keywords.isEmpty { iptc[.keywords] = .list(metadata.iptc.keywords) }
        if let value = metadata.iptc.byline, !value.isEmpty { iptc[.creator] = .text(value) }
        if let value = metadata.iptc.copyright, !value.isEmpty { iptc[.copyright] = .text(value) }
        var carriers: [ExistingFieldsSnapshot.Carrier] = [.init(name: "Embedded IPTC", fields: iptc)]
        if let xmp = metadata.xmp {
            carriers.append(.init(name: "Embedded XMP", fields: xmpFields(xmp), personInImage: xmp.personInImage))
        }
        if let gps = MetadataCoordinateReader.embeddedPosition(in: metadata) { carriers.append(.init(name: "Embedded EXIF", fields: [.gpsPosition: .position(gps)])) }
        return ExistingFieldsSnapshot(carriers: carriers, readable: true)
    }

    private static func rawPolicyMetadata(at fileURL: URL) throws -> (xmp: XMPData, origin: String, readable: Bool) {
        let sidecar = fileURL.deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            return (try XMPSidecar.read(from: sidecar), "Existing XMP sidecar", true)
        }
        if var embedded = try? ImageMetadata.read(from: fileURL) {
            embedded.syncIPTCToXMP()
            var xmp = embedded.xmp ?? XMPData()
            if xmpGPSPosition(xmp) == nil, let position = embeddedGPSPosition(embedded) { setGPS(position, on: &xmp) }
            return (xmp, "Embedded metadata used to seed a new sidecar", true)
        }
        return (XMPData(), "No readable embedded metadata or sidecar", false)
    }

    struct ExistingPlaceFieldsSnapshot: Equatable, Sendable {
        struct Carrier: Equatable, Sendable {
            let name: String
            let city: String?
            let country: String?
        }
        let carriers: [Carrier]
        let readable: Bool
    }

    /// Only enrichment callers use this strict boundary; legacy metadata parsing
    /// remains unchanged. The returned XMP was parsed from the validated capture.
    static func readExistingGeocodingSidecar(at fileURL: URL) throws -> XMPData? {
        let sidecar = fileURL.deletingPathExtension().appendingPathExtension("xmp")
        let manager = FileManager.default
        guard manager.fileExists(atPath: sidecar.path)
            || (try? manager.destinationOfSymbolicLink(atPath: sidecar.path)) != nil else { return nil }
        let values = try sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AppError.invalidConfiguration("The existing XMP sidecar must be a regular file without symbolic links.")
        }
        return try MetadataXMPValidation.read(at: sidecar)
    }

    static func existingPlaceFields(at fileURL: URL, relativePath: String) throws -> ExistingPlaceFieldsSnapshot {
        if usesXMPSidecar(for: relativePath) {
            if let xmp = try readExistingGeocodingSidecar(at: fileURL) {
                return .init(carriers: [.init(name: "Existing XMP sidecar", city: xmp.city, country: xmp.country)], readable: true)
            }
            let raw = try rawPolicyMetadata(at: fileURL)
            return .init(carriers: [.init(name: raw.origin, city: raw.xmp.city, country: raw.xmp.country)], readable: raw.readable)
        }
        let metadata = try ImageMetadata.read(from: fileURL)
        return .init(carriers: [.init(name: "Embedded IPTC", city: metadata.iptc.city, country: metadata.iptc.countryName),
                                .init(name: "Embedded XMP", city: metadata.xmp?.city, country: metadata.xmp?.country)], readable: true)
    }

    static func writablePlaceFields(at fileURL: URL, relativePath: String,
                                    settings: MetadataGeocodingSettings) throws -> Set<MetadataPlaceField> {
        // Even variable-only settings must reject a damaged sidecar before any
        // scheduled legacy field can be assessed or written by the caller.
        let validatedXMP = settings.isEnabled && usesXMPSidecar(for: relativePath)
            ? try readExistingGeocodingSidecar(at: fileURL) : nil
        guard settings.cityPolicy != .disabled || settings.countryPolicy != .disabled else { return [] }
        let existing: ExistingPlaceFieldsSnapshot
        if let validatedXMP {
            existing = .init(carriers: [.init(name: "Existing XMP sidecar", city: validatedXMP.city,
                country: validatedXMP.country)], readable: true)
        } else { existing = try existingPlaceFields(at: fileURL, relativePath: relativePath) }
        return Set(MetadataPlaceField.allCases.filter { field in
            let policy = field == .city ? settings.cityPolicy : settings.countryPolicy
            switch policy {
            case .disabled: return false
            case .overwrite: return true
            case .fillEmpty:
                return existing.carriers.allSatisfy { isEmpty(field == .city ? $0.city : $0.country) }
            }
        })
    }

    static func maximumPlaceUTF8Bytes(for field: MetadataPlaceField) -> Int {
        (field == .city ? IPTCTag.city : IPTCTag.countryPrimaryLocationName).maxLength!
    }

    private static func validatePlaceChanges(_ places: ResolvedMetadataPlaceChanges?) throws {
        guard let places else { return }
        for field in MetadataPlaceField.allCases {
            let policy = field == .city ? places.cityPolicy : places.countryPolicy
            guard policy != .disabled, let value = field == .city ? places.city : places.country else { continue }
            guard value.utf8.count <= maximumPlaceUTF8Bytes(for: field), validXMLText(value) else {
                throw AppError.invalidConfiguration("Resolved \(field.title) exceeds metadata limits or contains an unsupported character.")
            }
        }
    }

    private static func validateFaceNames(_ changes: ResolvedFaceNameChanges?) throws {
        guard let changes else { return }
        guard changes.names.count <= PeopleLibraryManifest.Limits().maximumPeople else {
            throw AppError.invalidConfiguration("Resolved face names exceed metadata limits.")
        }
        var totalBytes = 0
        for name in changes.names {
            guard name.utf8.count <= PeopleLibraryManifest.Limits().maximumNameUTF8Bytes,
                  validXMLText(name), name.utf8.count <= Int.max - totalBytes else {
                throw AppError.invalidConfiguration("A resolved face name exceeds metadata limits or contains an unsupported character.")
            }
            totalBytes += name.utf8.count
            if changes.appendToKeywords,
               name.utf8.count > IPTCTag.keywords.maxLength! {
                throw AppError.invalidConfiguration("A resolved face name exceeds the Keywords metadata limit.")
            }
        }
        guard totalBytes <= 1_048_576 else {
            throw AppError.invalidConfiguration("Resolved face names exceed metadata limits.")
        }
    }

    private static func validXMLText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13 || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
        }
    }

    /// Read-only policy assessment using the same carriers as apply(). An existing
    /// RAW sidecar is authoritative; when absent, seed from embedded IPTC/XMP just
    /// as sidecar creation does. No generated sidecar or metadata write occurs here.
    static func writableFields(at fileURL: URL, relativePath: String,
                               policy: MetadataExistingFieldPolicy) throws -> Set<MetadataWritableField> {
        if usesXMPSidecar(for: relativePath) {
            let xmp = try rawPolicyMetadata(at: fileURL).xmp
            return Set(MetadataWritableField.allCases.filter { field in
                if policy.overwrites(field) { return true }
                switch field {
                case .headline: return isEmpty(xmp.headline)
                case .description: return isEmpty(xmp.description)
                case .keywords: return xmp.subject.isEmpty
                case .creator: return xmp.creator.isEmpty
                case .copyright: return isEmpty(xmp.rights)
                case .gpsPosition: return xmpGPSPosition(xmp) == nil
                }
            })
        }
        let metadata = try ImageMetadata.read(from: fileURL)
        return Set(MetadataWritableField.allCases.filter { field in
            if policy.overwrites(field) { return true }
            switch field {
            case .headline: return isEmpty(metadata.iptc.headline) && isEmpty(metadata.xmp?.headline)
            case .description: return isEmpty(metadata.iptc.caption) && isEmpty(metadata.xmp?.description)
            case .keywords: return metadata.iptc.keywords.isEmpty && (metadata.xmp?.subject.isEmpty ?? true)
            case .creator: return isEmpty(metadata.iptc.byline) && (metadata.xmp?.creator.isEmpty ?? true)
            case .copyright: return isEmpty(metadata.iptc.copyright) && isEmpty(metadata.xmp?.rights)
            case .gpsPosition: return embeddedGPSPosition(metadata) == nil && metadata.xmp.flatMap(xmpGPSPosition) == nil
            }
        })
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
        _ changes: ResolvedMetadataChanges,
        at fileURL: URL,
        relativePath: String
    ) throws -> ApplicationAssessment {
        try validatePlaceChanges(changes.places)
        try validateFaceNames(changes.faceNames)
        if usesXMPSidecar(for: relativePath) {
            let sidecarURL = fileURL.deletingPathExtension().appendingPathExtension("xmp")
            if changes.places != nil || !(changes.faceNames?.names.isEmpty ?? true) {
                let xmp = try readExistingGeocodingSidecar(at: fileURL) ?? rawPolicyMetadata(at: fileURL).xmp
                return assessment(for: changes, xmp: xmp)
            }
            guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return .willApply }
            return assessment(for: changes, xmp: try XMPSidecar.read(from: sidecarURL))
        }

        return assessment(for: changes, metadata: try ImageMetadata.read(from: fileURL))
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
    static func apply(_ changes: ResolvedMetadataChanges, to fileURL: URL) throws -> [String] {
        try validatePlaceChanges(changes.places)
        try validateFaceNames(changes.faceNames)
        var metadata = try ImageMetadata.read(from: fileURL)
        let readWarnings = metadata.warnings
        metadata.iptc = try utf8IPTCForWriting(metadata.iptc)
        var xmp = metadata.xmp ?? XMPData()

        let headline = changes.headline
        let description = changes.description
        let creator = changes.creator
        let copyright = changes.copyright
        let keywords = changes.keywords

        if !headline.isEmpty,
           changes.existingFieldPolicy.overwrites(.headline) || (isEmpty(metadata.iptc.headline) && isEmpty(metadata.xmp?.headline)) {
            try metadata.iptc.setValue(headline, for: .headline)
            xmp.headline = headline
        }
        if !description.isEmpty,
           changes.existingFieldPolicy.overwrites(.description) || (isEmpty(metadata.iptc.caption) && isEmpty(metadata.xmp?.description)) {
            try metadata.iptc.setValue(description, for: .captionAbstract)
            xmp.description = description
        }
        if !keywords.isEmpty,
           changes.existingFieldPolicy.overwrites(.keywords) || (metadata.iptc.keywords.isEmpty && (metadata.xmp?.subject.isEmpty ?? true)) {
            try metadata.iptc.setValues(keywords, for: .keywords)
            xmp.subject = keywords
        }
        if !creator.isEmpty,
           changes.existingFieldPolicy.overwrites(.creator) || (isEmpty(metadata.iptc.byline) && (metadata.xmp?.creator.isEmpty ?? true)) {
            try metadata.iptc.setValue(creator, for: .byline)
            xmp.creator = [creator]
        }
        if !copyright.isEmpty,
           changes.existingFieldPolicy.overwrites(.copyright) || (isEmpty(metadata.iptc.copyright) && isEmpty(metadata.xmp?.rights)) {
            try metadata.iptc.setValue(copyright, for: .copyrightNotice)
            xmp.rights = copyright
        }
        if let places = changes.places {
            if let city = places.city, places.cityPolicy != .disabled,
               places.cityPolicy == .overwrite || (isEmpty(metadata.iptc.city) && isEmpty(xmp.city)) {
                try metadata.iptc.setValue(city, for: .city)
                xmp.city = city
            }
            if let country = places.country, places.countryPolicy != .disabled,
               places.countryPolicy == .overwrite || (isEmpty(metadata.iptc.countryName) && isEmpty(xmp.country)) {
                try metadata.iptc.setValue(country, for: .countryPrimaryLocationName)
                xmp.country = country
            }
        }
        try applyFaceNames(changes.faceNames, metadata: &metadata, xmp: &xmp)
        metadata.xmp = xmp
        applyGPS(from: changes, to: &metadata)
        let writeWarnings = try metadata.write(to: fileURL)
        return uniqueWarnings(readWarnings + writeWarnings)
    }

    /// The pinned writer already emits UTF-8. Perform that same lossless
    /// conversion before setting new Unicode values, which would otherwise try
    /// to encode in the old character set. Never relabel existing raw bytes.
    /// Undecodable retained text fails while the image is still untouched.
    static func utf8IPTCForWriting(_ source: IPTCData) throws -> IPTCData {
        guard source.encoding != .utf8 else { return source }
        var converted = try IPTCReader.read(from: IPTCWriter.write(source))
        // Keep the promotion contract explicit even when ASCII-only output
        // omits its charset marker.
        converted.encoding = .utf8
        return converted
    }

    static func apply(
        _ changes: ResolvedMetadataChanges,
        to fileURL: URL,
        relativePath: String
    ) throws -> WriteResult {
        guard usesXMPSidecar(for: relativePath) else {
            let warnings = try apply(changes, to: fileURL)
            return .embedded(size: try fileSize(at: fileURL), warnings: warnings)
        }

        try validatePlaceChanges(changes.places)
        try validateFaceNames(changes.faceNames)
        let sidecarURL = fileURL.deletingPathExtension().appendingPathExtension("xmp")
        // The new enrichment path must not replace an unreadable existing sidecar.
        var xmp: XMPData
        if changes.places != nil || !(changes.faceNames?.names.isEmpty ?? true) {
            xmp = try readExistingGeocodingSidecar(at: fileURL) ?? XMPData()
        } else { xmp = (try? XMPSidecar.read(from: sidecarURL)) ?? XMPData() }
        var warnings: [String] = []
        if !FileManager.default.fileExists(atPath: sidecarURL.path),
           var metadata = try? ImageMetadata.read(from: fileURL) {
            // Preserve the RAW file's existing XMP and mirror any legacy IPTC fields
            // into the generated sidecar before applying the programmed values.
            warnings.append(contentsOf: metadata.warnings)
            metadata.syncIPTCToXMP()
            xmp = metadata.xmp ?? xmp
            if xmpGPSPosition(xmp) == nil,
               let embeddedPosition = embeddedGPSPosition(metadata) {
                setGPS(embeddedPosition, on: &xmp)
            }
        }
        apply(changes, to: &xmp)

        let serialized = Data(XMPWriter.generateXML(xmp).utf8)
        do {
            try MetadataXMPValidation.validate(serialized)
        } catch {
            throw AppError.invalidConfiguration("The updated XMP sidecar exceeds metadata safety limits.")
        }
        try XMPSidecar.write(xmp, to: sidecarURL)
        return .sidecar(
            localURL: sidecarURL,
            size: try fileSize(at: sidecarURL),
            warnings: uniqueWarnings(warnings)
        )
    }

    private static func apply(_ changes: ResolvedMetadataChanges, to xmp: inout XMPData) {
        let headline = changes.headline
        let description = changes.description
        let creator = changes.creator
        let copyright = changes.copyright
        let keywords = changes.keywords

        if !headline.isEmpty, changes.existingFieldPolicy.overwrites(.headline) || isEmpty(xmp.headline) {
            xmp.headline = headline
        }
        if !description.isEmpty, changes.existingFieldPolicy.overwrites(.description) || isEmpty(xmp.description) {
            xmp.description = description
        }
        if !keywords.isEmpty, changes.existingFieldPolicy.overwrites(.keywords) || xmp.subject.isEmpty {
            xmp.subject = keywords
        }
        if !creator.isEmpty, changes.existingFieldPolicy.overwrites(.creator) || xmp.creator.isEmpty {
            xmp.creator = [creator]
        }
        if !copyright.isEmpty, changes.existingFieldPolicy.overwrites(.copyright) || isEmpty(xmp.rights) {
            xmp.rights = copyright
        }
        if let places = changes.places {
            if let city = places.city, places.cityPolicy != .disabled,
               places.cityPolicy == .overwrite || isEmpty(xmp.city) { xmp.city = city }
            if let country = places.country, places.countryPolicy != .disabled,
               places.countryPolicy == .overwrite || isEmpty(xmp.country) { xmp.country = country }
        }
        applyFaceNames(changes.faceNames, xmp: &xmp)
        applyGPS(from: changes, to: &xmp)
    }

    private enum FieldAssessment: Equatable {
        case matches
        case willChange
        case preserved
    }

    private static func assessment(
        for changes: ResolvedMetadataChanges,
        metadata: ImageMetadata
    ) -> ApplicationAssessment {
        var assessments: [FieldAssessment] = []

        assess(
            changes.headline,
            currentValues: [metadata.iptc.headline, metadata.xmp?.headline],
            overwrite: changes.existingFieldPolicy.overwrites(.headline),
            into: &assessments
        )
        assess(
            changes.description,
            currentValues: [metadata.iptc.caption, metadata.xmp?.description],
            overwrite: changes.existingFieldPolicy.overwrites(.description),
            into: &assessments
        )
        assessKeywords(changes, currentValues: [metadata.iptc.keywords, metadata.xmp?.subject ?? []], into: &assessments)
        assess(
            changes.creator,
            currentValues: [metadata.iptc.byline] + (metadata.xmp?.creator.map(Optional.some) ?? []),
            overwrite: changes.existingFieldPolicy.overwrites(.creator),
            into: &assessments
        )
        assess(
            changes.copyright,
            currentValues: [metadata.iptc.copyright, metadata.xmp?.rights],
            overwrite: changes.existingFieldPolicy.overwrites(.copyright),
            into: &assessments
        )
        assessGPS(
            changes.gpsPosition,
            currentValues: [embeddedGPSPosition(metadata), metadata.xmp.flatMap(xmpGPSPosition)],
            overwrite: changes.existingFieldPolicy.overwrites(.gpsPosition),
            into: &assessments
        )
        assessFaceNames(changes.faceNames, personInImage: metadata.xmp?.personInImage ?? [], into: &assessments)

        assessPlaces(changes.places, city: [metadata.iptc.city, metadata.xmp?.city],
                     country: [metadata.iptc.countryName, metadata.xmp?.country], into: &assessments)
        return combinedAssessment(assessments)
    }

    private static func assessment(
        for changes: ResolvedMetadataChanges,
        xmp: XMPData
    ) -> ApplicationAssessment {
        var assessments: [FieldAssessment] = []

        assess(changes.headline, currentValues: [xmp.headline], overwrite: changes.existingFieldPolicy.overwrites(.headline), into: &assessments)
        assess(changes.description, currentValues: [xmp.description], overwrite: changes.existingFieldPolicy.overwrites(.description), into: &assessments)
        assessKeywords(changes, currentValues: [xmp.subject], into: &assessments)
        assess(
            changes.creator,
            currentValues: xmp.creator.map(Optional.some),
            overwrite: changes.existingFieldPolicy.overwrites(.creator),
            into: &assessments
        )
        assess(
            changes.copyright,
            currentValues: [xmp.rights],
            overwrite: changes.existingFieldPolicy.overwrites(.copyright),
            into: &assessments
        )
        assessGPS(
            changes.gpsPosition,
            currentValues: [xmpGPSPosition(xmp)],
            overwrite: changes.existingFieldPolicy.overwrites(.gpsPosition),
            into: &assessments
        )
        assessFaceNames(changes.faceNames, personInImage: xmp.personInImage, into: &assessments)

        assessPlaces(changes.places, city: [xmp.city], country: [xmp.country], into: &assessments)
        return combinedAssessment(assessments)
    }

    private static func applyFaceNames(
        _ changes: ResolvedFaceNameChanges?,
        metadata: inout ImageMetadata,
        xmp: inout XMPData
    ) throws {
        guard let changes, !changes.names.isEmpty else { return }
        xmp.personInImage = appendingUnique(changes.names, to: xmp.personInImage)
        guard changes.appendToKeywords else { return }
        let iptcKeywords = appendingUnique(changes.names, to: metadata.iptc.keywords)
        let xmpKeywords = appendingUnique(changes.names, to: xmp.subject)
        if iptcKeywords != metadata.iptc.keywords { try metadata.iptc.setValues(iptcKeywords, for: .keywords) }
        xmp.subject = xmpKeywords
    }

    private static func applyFaceNames(_ changes: ResolvedFaceNameChanges?, xmp: inout XMPData) {
        guard let changes, !changes.names.isEmpty else { return }
        xmp.personInImage = appendingUnique(changes.names, to: xmp.personInImage)
        if changes.appendToKeywords { xmp.subject = appendingUnique(changes.names, to: xmp.subject) }
    }

    private static func assessFaceNames(
        _ changes: ResolvedFaceNameChanges?,
        personInImage: [String],
        into assessments: inout [FieldAssessment]
    ) {
        guard let changes, !changes.names.isEmpty else { return }
        assessments.append(appendingUnique(changes.names, to: personInImage) == personInImage ? .matches : .willChange)
    }

    private static func assessKeywords(
        _ changes: ResolvedMetadataChanges,
        currentValues: [[String]],
        into assessments: inout [FieldAssessment]
    ) {
        guard let faceNames = changes.faceNames, faceNames.appendToKeywords, !faceNames.names.isEmpty else {
            assess(changes.keywords, currentValues: currentValues,
                overwrite: changes.existingFieldPolicy.overwrites(.keywords), into: &assessments)
            return
        }
        let shouldReplace = !changes.keywords.isEmpty &&
            (changes.existingFieldPolicy.overwrites(.keywords) || currentValues.allSatisfy { $0.isEmpty })
        if shouldReplace {
            let desired = appendingUnique(faceNames.names, to: changes.keywords)
            assessments.append(currentValues.allSatisfy({ $0 == desired }) ? .matches : .willChange)
        } else {
            assess(changes.keywords, currentValues: currentValues,
                overwrite: changes.existingFieldPolicy.overwrites(.keywords), into: &assessments)
            assessments.append(currentValues.allSatisfy {
                appendingUnique(faceNames.names, to: $0) == $0
            } ? .matches : .willChange)
        }
    }

    private static func appendingUnique(_ additions: [String], to existing: [String]) -> [String] {
        var result = existing
        var seen = Set(existing.compactMap(normalizationKey))
        for addition in additions {
            guard let key = normalizationKey(addition), seen.insert(key).inserted else { continue }
            result.append(addition)
        }
        return result
    }

    private static func normalizationKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ResolvedFaceNameChanges.normalizationKey(trimmed)
    }

    private static func assessPlaces(_ places: ResolvedMetadataPlaceChanges?, city: [String?], country: [String?],
                                     into assessments: inout [FieldAssessment]) {
        guard let places else { return }
        if let value = places.city, places.cityPolicy != .disabled {
            assess(value, currentValues: city, overwrite: places.cityPolicy == .overwrite, into: &assessments)
        }
        if let value = places.country, places.countryPolicy != .disabled {
            assess(value, currentValues: country, overwrite: places.countryPolicy == .overwrite, into: &assessments)
        }
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

    private static func assessGPS(
        _ desiredPosition: ScheduledGPSPosition?,
        currentValues: [ScheduledGPSPosition?],
        overwrite: Bool,
        into assessments: inout [FieldAssessment]
    ) {
        guard let desiredPosition, desiredPosition.isValid else { return }
        let populated = currentValues.compactMap { $0 }
        if !populated.isEmpty,
           populated.allSatisfy({ positionsMatch($0, desiredPosition) }) {
            assessments.append(.matches)
        } else if overwrite || populated.isEmpty {
            assessments.append(.willChange)
        } else {
            assessments.append(.preserved)
        }
    }

    private static func applyGPS(from changes: ResolvedMetadataChanges, to metadata: inout ImageMetadata) {
        guard let desiredPosition = changes.gpsPosition,
              desiredPosition.isValid else { return }
        let hasExistingPosition = embeddedGPSPosition(metadata) != nil
            || metadata.xmp.flatMap(xmpGPSPosition) != nil
        guard changes.existingFieldPolicy.overwrites(.gpsPosition) || !hasExistingPosition else { return }

        metadata.setGPS(
            latitude: desiredPosition.latitude,
            longitude: desiredPosition.longitude,
            altitude: desiredPosition.altitudeMeters
        )
        // A scheduled location is a position, not a recorded satellite fix. Do
        // not claim that the time at which metadata was applied was a GPS fix.
        _ = metadata.removeGPSTag(ExifTag.gpsTimeStamp)
        _ = metadata.removeGPSTag(ExifTag.gpsDateStamp)

        var xmp = metadata.xmp ?? XMPData()
        setGPS(desiredPosition, on: &xmp)
        metadata.xmp = xmp
    }

    private static func applyGPS(from changes: ResolvedMetadataChanges, to xmp: inout XMPData) {
        guard let desiredPosition = changes.gpsPosition,
              desiredPosition.isValid else { return }
        guard changes.existingFieldPolicy.overwrites(.gpsPosition) || xmpGPSPosition(xmp) == nil else { return }
        setGPS(desiredPosition, on: &xmp)
    }

    private static func setGPS(_ position: ScheduledGPSPosition, on xmp: inout XMPData) {
        xmp.exifGPSLatitude = xmpCoordinate(position.latitude, isLatitude: true)
        xmp.exifGPSLongitude = xmpCoordinate(position.longitude, isLatitude: false)
        if let altitude = position.altitudeMeters {
            xmp.exifGPSAltitude = "\(Int((abs(altitude) * 1_000).rounded()))/1000"
            xmp.setValue(
                .simple(altitude < 0 ? "1" : "0"),
                namespace: XMPNamespace.exif,
                property: "GPSAltitudeRef"
            )
        } else {
            xmp.exifGPSAltitude = nil
            xmp.removeValue(namespace: XMPNamespace.exif, property: "GPSAltitudeRef")
        }
        xmp.exifGPSTimeStamp = nil
    }

    private static func embeddedGPSPosition(_ metadata: ImageMetadata) -> ScheduledGPSPosition? {
        guard let latitude = metadata.exif?.gpsLatitude,
              let longitude = metadata.exif?.gpsLongitude,
              latitude.isFinite,
              longitude.isFinite else { return nil }
        let altitude = metadata.exif?.gpsAltitude
        let position = ScheduledGPSPosition(
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: altitude
        )
        return position.isValid ? position : nil
    }

    private static func xmpGPSPosition(_ xmp: XMPData) -> ScheduledGPSPosition? {
        guard let latitude = parseXMPCoordinate(xmp.exifGPSLatitude, isLatitude: true),
              let longitude = parseXMPCoordinate(xmp.exifGPSLongitude, isLatitude: false) else {
            return nil
        }
        var altitude = parseRational(xmp.exifGPSAltitude)
        if xmp.simpleValue(namespace: XMPNamespace.exif, property: "GPSAltitudeRef") == "1" {
            altitude = altitude.map { -abs($0) }
        }
        let position = ScheduledGPSPosition(
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: altitude
        )
        return position.isValid ? position : nil
    }

    private static func xmpCoordinate(_ coordinate: Double, isLatitude: Bool) -> String {
        let absolute = abs(coordinate)
        let degrees = Int(absolute.rounded(.down))
        let minutes = (absolute - Double(degrees)) * 60
        let direction: Character
        if isLatitude {
            direction = coordinate < 0 ? "S" : "N"
        } else {
            direction = coordinate < 0 ? "W" : "E"
        }
        return String(format: "%d,%.7f%@", locale: Locale(identifier: "en_US_POSIX"), degrees, minutes, String(direction))
    }

    // Shared with the read-only effective-coordinate adapter; legacy parsing is unchanged.
    static func parseXMPCoordinate(_ value: String?, isLatitude: Bool) -> Double? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let direction = normalized.last,
              (isLatitude ? "NS" : "EW").contains(direction) else { return nil }
        let components = normalized.dropLast().split(separator: ",")
        guard components.count == 2,
              let degrees = Double(components[0]),
              let minutes = Double(components[1]),
              degrees >= 0,
              minutes >= 0,
              minutes < 60 else { return nil }
        let sign = direction == "S" || direction == "W" ? -1.0 : 1.0
        let coordinate = sign * (degrees + minutes / 60)
        let limit = isLatitude ? 90.0 : 180.0
        return abs(coordinate) <= limit ? coordinate : nil
    }

    static func parseRational(_ value: String?) -> Double? {
        guard let value else { return nil }
        let components = value.split(separator: "/")
        if components.count == 1 {
            return Double(components[0])
        }
        guard components.count == 2,
              let numerator = Double(components[0]),
              let denominator = Double(components[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }

    private static func positionsMatch(
        _ lhs: ScheduledGPSPosition,
        _ rhs: ScheduledGPSPosition
    ) -> Bool {
        let coordinateTolerance = 0.000_001
        let altitudeTolerance = 0.01
        guard abs(lhs.latitude - rhs.latitude) <= coordinateTolerance,
              abs(lhs.longitude - rhs.longitude) <= coordinateTolerance else {
            return false
        }
        switch (lhs.altitudeMeters, rhs.altitudeMeters) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            return abs(lhs - rhs) <= altitudeTolerance
        default:
            return false
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
