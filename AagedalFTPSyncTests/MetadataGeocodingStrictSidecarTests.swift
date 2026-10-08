import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataGeocodingStrictSidecarTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("strict-place-sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.cr3")
        try Data("opaque RAW bytes must remain untouched".utf8).write(to: file)
        return (file, file.deletingPathExtension().appendingPathExtension("xmp"))
    }

    func testTokenizableMalformedPlacesFailAllNewBoundariesBeforeMutation() throws {
        let (file, sidecar) = try fixture()
        let original = try Data(contentsOf: file)
        // The pinned tokenizer accepts these names despite the missing end tags.
        let malformed = Data(#"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"><photoshop:City>Existing city</photoshop:City><photoshop:Country>Existing country</photoshop:Country>"#.utf8)
        try malformed.write(to: sidecar)
        XCTAssertEqual(try XMPSidecar.read(from: sidecar).city, "Existing city")
        let policies = [try MetadataGeocodingSettings(resolveVariables: true, localeIdentifier: "en"),
            try MetadataGeocodingSettings(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en")]
        for settings in policies {
            XCTAssertThrowsError(try MetadataWriter.writablePlaceFields(at: file, relativePath: "fixture.cr3", settings: settings))
        }
        XCTAssertThrowsError(try MetadataWriter.existingPlaceFields(at: file, relativePath: "fixture.cr3"))
        let changes = ResolvedMetadataChanges(places: .init(city: "New city", cityPolicy: .overwrite))
        XCTAssertThrowsError(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.cr3"))
        XCTAssertThrowsError(try MetadataWriter.apply(changes, to: file, relativePath: "fixture.cr3"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: sidecar), malformed)
    }

    func testAllDisabledGeocodingKeepsLegacyPolicyBoundaryUnchanged() throws {
        let (file, sidecar) = try fixture()
        try Data("not XML".utf8).write(to: sidecar)
        let disabled = try MetadataGeocodingSettings(localeIdentifier: "en")
        XCTAssertEqual(try MetadataWriter.writablePlaceFields(at: file, relativePath: "fixture.cr3", settings: disabled), [])
        // Legacy nil-place assessment retains the established permissive parser.
        XCTAssertNoThrow(try MetadataWriter.assess(.init(headline: "Literal"), at: file, relativePath: "fixture.cr3"))
    }

    func testDanglingAndLiveSidecarLinksCannotBeRewrittenByPlaces() throws {
        let (file, sidecar) = try fixture()
        let target = file.deletingLastPathComponent().appendingPathComponent("other.xmp")
        let changes = ResolvedMetadataChanges(places: .init(city: "New city", cityPolicy: .overwrite))
        for targetExists in [false, true] {
            if targetExists { try XMPSidecar.write(XMPData(), to: target) }
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
            XCTAssertThrowsError(try MetadataWriter.assess(changes, at: file, relativePath: "fixture.cr3"))
            XCTAssertThrowsError(try MetadataWriter.apply(changes, to: file, relativePath: "fixture.cr3"))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path), target.path)
            try FileManager.default.removeItem(at: sidecar)
        }
    }

    func testValidExistingPlacesUseStrictCaptureAndAvoidAWrite() throws {
        let (file, sidecar) = try fixture()
        var xmp = XMPData(); xmp.city = "Existing city"; xmp.country = "Existing country"
        try XMPSidecar.write(xmp, to: sidecar)
        let original = try Data(contentsOf: sidecar)
        let settings = try MetadataGeocodingSettings(cityPolicy: .fillEmpty, countryPolicy: .fillEmpty, localeIdentifier: "en")
        XCTAssertEqual(try MetadataWriter.writablePlaceFields(at: file, relativePath: "fixture.cr3", settings: settings), [])
        XCTAssertEqual(try MetadataWriter.existingPlaceFields(at: file, relativePath: "fixture.cr3").carriers.first?.city, "Existing city")
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }
}
