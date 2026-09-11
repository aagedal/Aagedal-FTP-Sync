import Foundation
import SwiftMediaMetadata

/// Read-only carrier selection for activated processing. Legacy writer acceptance
/// remains unchanged; malformed EXIF tags must never become a fabricated (0, 0).
enum MetadataCoordinateReader {
    static func read(
        at fileURL: URL, relativePath: String,
        scheduled: ScheduledGPSPosition? = nil,
        policy: MetadataExistingFieldPolicy = .fillEmpty
    ) throws -> EffectiveMetadataCoordinates.Resolution {
        guard fileURL.isFileURL, PathSafety.isSafeRelativePath(relativePath) else {
            throw AppError.invalidConfiguration("GPS metadata requires a local image and a safe relative filename.")
        }
        try Task.checkCancellation()
        let isRaw = MetadataWriter.usesXMPSidecar(for: relativePath)
        let metadata: ImageMetadata?
        let xmp: XMPData?
        if isRaw {
            let sidecar = fileURL.deletingPathExtension().appendingPathExtension("xmp")
            let manager = FileManager.default
            let sidecarExists = manager.fileExists(atPath: sidecar.path)
                || (try? manager.destinationOfSymbolicLink(atPath: sidecar.path)) != nil
            if sidecarExists {
                let values = try sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw AppError.invalidConfiguration("The existing GPS sidecar must be a regular file without symbolic links.")
                }
                // Never suppress a damaged existing sidecar and substitute embedded metadata.
                xmp = try MetadataXMPValidation.read(at: sidecar)
                metadata = try? ImageMetadata.read(from: fileURL)
            } else {
                metadata = try? ImageMetadata.read(from: fileURL)
                xmp = metadata?.xmp
            }
            // A valid sidecar is authoritative for RAW. If embedded metadata is
            // unreadable in that case, no reported conflict does not prove agreement.
            // Otherwise unreadable embedded GPS is unknown, not an empty field.
            guard metadata != nil || (sidecarExists && position(xmpCandidate(xmp)) != nil) else {
                throw AppError.transferFailed("Embedded GPS metadata could not be read and no valid sidecar position was available. Existing coordinates were not assumed empty.")
            }
        } else {
            metadata = try ImageMetadata.read(from: fileURL)
            xmp = metadata?.xmp
        }
        try Task.checkCancellation()
        return EffectiveMetadataCoordinates.resolve(imageKind: isRaw ? .raw : .embedded,
            embeddedEXIF: embeddedCandidate(metadata?.exif), xmp: xmpCandidate(xmp),
            scheduled: scheduled, policy: policy)
    }

    /// GPS-only preview carrier, using the same strict acceptance as this reader.
    static func embeddedPosition(in metadata: ImageMetadata) -> ScheduledGPSPosition? {
        position(embeddedCandidate(metadata.exif))
    }

    static func xmpPosition(in xmp: XMPData) -> ScheduledGPSPosition? {
        position(xmpCandidate(xmp))
    }

    private static func position(_ candidate: EffectiveMetadataCoordinates.Candidate?) -> ScheduledGPSPosition? {
        guard let candidate, let latitude = candidate.latitude, let longitude = candidate.longitude else { return nil }
        let result = ScheduledGPSPosition(latitude: latitude, longitude: longitude, altitudeMeters: candidate.altitudeMeters)
        return result.isValid ? result : nil
    }

    private static func embeddedCandidate(_ exif: ExifData?) -> EffectiveMetadataCoordinates.Candidate? {
        guard let exif, let gps = exif.gpsIFD else { return nil }
        let tags: Set<UInt16> = [ExifTag.gpsLatitude, ExifTag.gpsLatitudeRef, ExifTag.gpsLongitude,
            ExifTag.gpsLongitudeRef, ExifTag.gpsAltitude, ExifTag.gpsAltitudeRef]
        let entries = gps.entries.filter { tags.contains($0.tag) }
        guard !entries.isEmpty else { return nil }
        guard Set(entries.map(\.tag)).count == entries.count else {
            return .init(latitude: nil, longitude: nil)
        }
        let latitude = coordinate(gps.entry(for: ExifTag.gpsLatitude), ref: gps.entry(for: ExifTag.gpsLatitudeRef),
            latitude: true, endian: exif.byteOrder)
        let longitude = coordinate(gps.entry(for: ExifTag.gpsLongitude), ref: gps.entry(for: ExifTag.gpsLongitudeRef),
            latitude: false, endian: exif.byteOrder)
        var altitude: Double?
        if let entry = gps.entry(for: ExifTag.gpsAltitude) {
            if entry.type == .rational, entry.count == 1,
               let rational = entry.rationalValue(endian: exif.byteOrder), rational.denominator > 0 {
                altitude = Double(rational.numerator) / Double(rational.denominator)
            } else { altitude = .nan }
        }
        if let ref = gps.entry(for: ExifTag.gpsAltitudeRef) {
            if ref.type == .byte, ref.count == 1, let value = ref.valueData.first, value <= 1, let current = altitude {
                altitude = value == 1 ? -abs(current) : current
            } else { altitude = .nan }
        }
        return .init(latitude: latitude, longitude: longitude, altitudeMeters: altitude)
    }

    private static func coordinate(_ entry: IFDEntry?, ref: IFDEntry?, latitude: Bool, endian: ByteOrder) -> Double? {
        guard let entry, entry.type == .rational, entry.count == 3, entry.valueData.count >= 24,
              let ref, ref.type == .ascii, ref.count == 2, ref.valueData.count == 2,
              ref.valueData.last == 0, let direction = ref.stringValue(endian: endian),
              (latitude ? ["N", "S"] : ["E", "W"]).contains(direction) else { return nil }
        var reader = BinaryReader(data: entry.valueData)
        var components: [Double] = []
        for _ in 0..<3 {
            guard let numerator = try? reader.readUInt32(endian: endian),
                  let denominator = try? reader.readUInt32(endian: endian), denominator > 0 else { return nil }
            components.append(Double(numerator) / Double(denominator))
        }
        // The pinned writer rounds seconds to 1/10000 without carrying into
        // minutes: 59.9 becomes 59 degrees, 53 minutes, 600000/10000 seconds.
        // Accept exactly that endpoint, normalize by the sum, and retain final
        // latitude/longitude bounds. Values above 60 remain malformed.
        guard components[1] < 60, components[2] <= 60 else { return nil }
        let magnitude = components[0] + components[1] / 60 + components[2] / 3600
        return (direction == "S" || direction == "W") ? -magnitude : magnitude
    }

    private static func xmpCandidate(_ xmp: XMPData?) -> EffectiveMetadataCoordinates.Candidate? {
        guard let xmp else { return nil }
        let properties = ["GPSLatitude", "GPSLongitude", "GPSAltitude", "GPSAltitudeRef"]
        guard properties.contains(where: { xmp.value(namespace: XMPNamespace.exif, property: $0) != nil }) else { return nil }
        let latitude = MetadataWriter.parseXMPCoordinate(xmp.exifGPSLatitude, isLatitude: true)
        let longitude = MetadataWriter.parseXMPCoordinate(xmp.exifGPSLongitude, isLatitude: false)
        var altitude: Double?
        if xmp.value(namespace: XMPNamespace.exif, property: "GPSAltitude") != nil {
            altitude = MetadataWriter.parseRational(xmp.exifGPSAltitude) ?? .nan
        }
        if xmp.value(namespace: XMPNamespace.exif, property: "GPSAltitudeRef") != nil {
            if let ref = xmp.simpleValue(namespace: XMPNamespace.exif, property: "GPSAltitudeRef"),
               ["0", "1"].contains(ref), let current = altitude {
                altitude = ref == "1" ? -abs(current) : current
            } else { altitude = .nan }
        }
        return .init(latitude: latitude, longitude: longitude, altitudeMeters: altitude)
    }
}
