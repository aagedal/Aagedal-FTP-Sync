import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import CoreLocation
@preconcurrency import MapKit
import SwiftMediaMetadata

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeFailure(description: message) }
}

@main
struct Probe {
    @MainActor
    static func main() async throws {
        let arguments = Set(CommandLine.arguments.dropFirst())
        guard arguments.isSubset(of: ["--online-mapkit", "--online-corelocation"]) else {
            throw ProbeFailure(description: "Options: --online-mapkit or --online-corelocation. Default stays offline.")
        }
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString); deployment target macOS 14; SwiftMediaMetadata 2.0.0")
        try offline()
        try metadataRoundTrip()
        if arguments.contains("--online-mapkit") { try await mapKit() }
        if arguments.contains("--online-corelocation") { try await coreLocation() }
    }

    static func offline() throws {
        let clock = ContinuousClock()
        let start = clock.now
        let geocoder = ReverseGeocoder()
        let constructed = clock.now
        let oslo = geocoder.lookup(latitude: 59.9139, longitude: 10.7522, maxDistance: 50)
        try require(oslo?.city == "Oslo" && oslo?.countryCodeAlpha2 == "NO", "Oslo lookup mismatch")
        try require(oslo?.localizedCountry(Locale(identifier: "nb_NO")) == "Norge", "Offline country localization mismatch")
        try require(geocoder.lookup(latitude: -48.876, longitude: -123.393, maxDistance: 50) == nil, "Ocean distance cutoff failed")
        let warmStart = clock.now
        for _ in 0..<1000 {
            try require(geocoder.lookup(latitude: 59.9139, longitude: 10.7522)?.country == "Norway", "Warm lookup mismatch")
        }
        print("OFFLINE PASS city=Oslo country=Norway localized=Norge distanceKm=\(oslo!.distance) initialization=\(start.duration(to: constructed)) warm1000=\(warmStart.duration(to: clock.now))")
    }

    static func metadataRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-m0-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = root.appendingPathComponent("synthetic.jpg")
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProbeFailure(description: "Cannot create synthetic image")
        }
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProbeFailure(description: "Cannot create JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Cannot write synthetic JPEG")
        let originalPixels = try pixels(jpeg)
        var metadata = try ImageMetadata.read(from: jpeg)
        var xmp = XMPData()
        xmp.city = "Oslo"
        xmp.country = "Norway"
        xmp.personInImage = ["Synthetic Person", "Example ÆØÅ"]
        xmp.description = "Unrelated caption survives"
        metadata.xmp = xmp
        try metadata.iptc.setValue("Oslo", for: .city)
        try metadata.iptc.setValue("Norway", for: .countryPrimaryLocationName)
        _ = try metadata.write(to: jpeg)
        let reread = try ImageMetadata.read(from: jpeg)
        try require(reread.xmp?.city == "Oslo" && reread.xmp?.country == "Norway", "Embedded place fields failed")
        try require(reread.xmp?.personInImage == xmp.personInImage, "Embedded Person Shown failed")
        try require(reread.xmp?.description == xmp.description, "Unrelated caption changed")
        let resultingPixels = try pixels(jpeg)
        try require(resultingPixels == originalPixels, "JPEG decoded pixels changed")
        let sidecar = root.appendingPathComponent("synthetic.xmp")
        try XMPSidecar.write(xmp, to: sidecar)
        let sidecarRead = try XMPSidecar.read(from: sidecar)
        try require(sidecarRead.city == xmp.city && sidecarRead.country == xmp.country && sidecarRead.personInImage == xmp.personInImage, "Sidecar round trip failed")
        try require(sidecarRead.description == xmp.description, "Sidecar unrelated caption changed")
        print("METADATA PASS JPEG/XMP City, Country, Person Shown, Unicode, retained caption, identical decoded JPEG pixels")
    }

    static func pixels(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let bytes = image.dataProvider?.data else { throw ProbeFailure(description: "Cannot decode pixels") }
        return bytes as Data
    }

    // Public synthetic Oslo coordinates only. These paths run only with explicit flags.
    @MainActor
    static func mapKit() async throws {
        guard #available(macOS 26.0, *) else {
            throw ProbeFailure(description: "MapKit reverse geocoder requires macOS 26; use Core Location on 14/15")
        }
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: 59.9139, longitude: 10.7522)) else {
            throw ProbeFailure(description: "Cannot construct MapKit request")
        }
        request.preferredLocale = Locale(identifier: "en_US")
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(20))
            request.cancel()
        }
        defer { timeout.cancel() }
        let items = try await request.mapItems
        try require(items.first?.addressRepresentations?.cityName != nil, "MapKit returned no city")
        print("MAPKIT PASS city=\(items.first?.addressRepresentations?.cityName ?? "") country=\(items.first?.addressRepresentations?.regionName ?? "")")
    }

    @MainActor
    static func coreLocation() async throws {
        let geocoder = CLGeocoder()
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(20))
            geocoder.cancelGeocode()
        }
        defer { timeout.cancel() }
        let placemarks = try await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: 59.9139, longitude: 10.7522), preferredLocale: Locale(identifier: "en_US"))
        try require(placemarks.first?.locality != nil, "Core Location returned no city")
        print("CORELOCATION PASS city=\(placemarks.first?.locality ?? "") country=\(placemarks.first?.country ?? "")")
    }
}
