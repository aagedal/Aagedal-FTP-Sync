import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

final class PhotographerLibraryActivationBoundaryTests: XCTestCase {
    private func profile(active: Bool) throws -> PhotographerProfile {
        var profile = PhotographerProfile(name: "Test", filenamePrefix: "T", creator: "Test", copyrightNotice: "Literal {gps:city}")
        if active { profile.setCopyright(try .activated("Copyright {photographer}")) }
        return profile
    }

    func testActiveCopyrightCannotBeExportedThroughLiteralOnlyList() throws {
        let value = try profile(active: true)
        XCTAssertThrowsError(try PhotographerLibraryTransferCodec.encode([value])) {
            XCTAssertEqual($0 as? PhotographerLibraryTransferError, .activatedTemplatesRequireConfigurationPackage)
        }
        XCTAssertEqual(value.copyrightTemplateVersion, 1)
        XCTAssertEqual(value.copyrightNotice, "Copyright {photographer}")
    }

    func testLiteralEnvelopeAndLegacyArrayStillRoundTripWithoutMarkers() throws {
        let profiles = [try profile(active: false)]
        for data in [try PhotographerLibraryTransferCodec.encode(profiles), try JSONEncoder().encode(profiles)] {
            XCTAssertEqual(try PhotographerLibraryTransferCodec.decode(data), profiles)
            XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("copyrightTemplateVersion"))
        }
    }

    func testActiveEnvelopeAndLegacyArrayCannotBypassImportGuard() throws {
        let profiles = [try profile(active: true)]
        for data in [try JSONEncoder().encode(PhotographerLibraryTransfer(photographers: profiles)), try JSONEncoder().encode(profiles)] {
            XCTAssertThrowsError(try PhotographerLibraryTransferCodec.decode(data)) {
                XCTAssertEqual($0 as? PhotographerLibraryTransferError, .activatedTemplatesRequireConfigurationPackage)
            }
        }
    }

    func testMarkerPresenceIsRejectedBeforeMalformedModelsAndRawArrayFallback() throws {
        for value in ["null", "true", "2", "1"] {
            for source in [
                "[{\"copyrightTemplateVersion\":\(value)}]",
                "{\"format\":\"aagedal-ftp-sync-photographers\",\"version\":1,\"photographers\":[{\"copyrightTemplateVersion\":\(value)}]}"
            ] {
                XCTAssertThrowsError(try PhotographerLibraryTransferCodec.decode(Data(source.utf8))) {
                    XCTAssertEqual($0 as? PhotographerLibraryTransferError, .activatedTemplatesRequireConfigurationPackage)
                }
            }
        }
    }

    func testHeaderVersionIsRejectedBeforeMalformedPhotographerBody() {
        let data = Data(#"{"format":"aagedal-ftp-sync-photographers","version":99,"photographers":false}"#.utf8)
        XCTAssertThrowsError(try PhotographerLibraryTransferCodec.decode(data)) {
            XCTAssertEqual($0 as? PhotographerLibraryTransferError, .unsupportedVersion(99))
        }
    }
}
