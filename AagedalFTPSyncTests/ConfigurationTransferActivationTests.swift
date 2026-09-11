import XCTest
import CommonCrypto
import CryptoKit
import MetadataTemplates
@testable import AagedalFTPSync

final class ConfigurationTransferActivationTests: XCTestCase {
    private let password = "activation-test-password"

    private func transfer(active: Bool, scope: ConfigurationTransferScope = .metadata) throws -> ConfigurationTransfer {
        var fields = ScheduledMetadataFields(headline: "Literal {gps:city}", keywords: [" unchanged "])
        if active {
            fields.setHeadline(try MetadataTemplateText.activated("From {gps:city}"))
            fields.setKeywords(try MetadataTemplateKeywords.activated([" {gps:city} ", "{persons}"]))
        }
        var photographer = PhotographerProfile(name: "Test", filenamePrefix: "T", creator: "Test", copyrightNotice: "Literal {date}")
        if active { photographer.setCopyright(try MetadataTemplateText.activated("Copyright {gps:country}")) }
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Test", startsAt: Date(timeIntervalSince1970: 100),
                                        endsAt: Date(timeIntervalSince1970: 200), fields: fields)
        var job = SyncJob(name: "Test", left: Endpoint(kind: .local, localPath: "/tmp/source"), right: Endpoint(kind: .local, localPath: "/tmp/destination"))
        job.metadataAutomation = MetadataAutomation(isEnabled: true, photographers: [photographer], clips: [clip])
        return ConfigurationTransfer(scope: scope, jobs: [job], metadataPresets: [MetadataPreset(name: "Test", fields: fields)],
                                     photographers: [photographer], exportedAt: Date(timeIntervalSince1970: 100))
    }

    func testActivePlainAndEncryptedPackagesPreserveAtomicPairs() throws {
        for scope in [ConfigurationTransferScope.metadata, .package] {
            let original = try transfer(active: true, scope: scope)
            XCTAssertEqual(original.version, 3)
            for encryption in [nil, Optional(password)] {
                let data = try ConfigurationTransferCodec.encode(original, password: encryption)
                XCTAssertEqual(try ConfigurationTransferCodec.decode(data, password: encryption), original)
                if encryption != nil {
                    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertEqual(envelope["version"] as? Int, 1)
                }
            }
        }
    }

    func testLiteralAndJobsOnlySelectionsKeepVersionTwoWithoutMarkerKeys() throws {
        for original in [try transfer(active: false), try transfer(active: true, scope: .jobs)] {
            XCTAssertEqual(original.version, 2)
            let data = try ConfigurationTransferCodec.encode(original, password: nil)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(text.contains("templateVersions"))
            XCTAssertFalse(text.contains("copyrightTemplateVersion"))
            XCTAssertEqual(try ConfigurationTransferCodec.decode(data, password: nil), original)
        }
    }

    func testEachSelectedMetadataLibraryIndependentlyRequiresVersionThree() throws {
        let active = try transfer(active: true)
        let presetOnly = ConfigurationTransfer(scope: .metadata, jobs: [], metadataPresets: active.metadataPresets, photographers: [])
        let photographersOnly = ConfigurationTransfer(scope: .metadata, jobs: [], metadataPresets: [], photographers: active.photographers)
        XCTAssertEqual(presetOnly.version, 3)
        XCTAssertEqual(photographersOnly.version, 3)
    }

    func testLegacyMarkerMismatchIsRejectedBeforeDomainDecodePlainAndEncrypted() throws {
        // Deliberately lacks every domain field. Header/marker preflight must win.
        for version in [1, 2] {
            for marker in ["templateVersions", "copyrightTemplateVersion"] {
                let payload = try JSONSerialization.data(withJSONObject: [
                    "format": ConfigurationTransfer.formatIdentifier, "version": version,
                    "ignoredFutureObject": [marker: NSNull()]
                ])
                for data in [payload, try encrypted(payload)] {
                    XCTAssertThrowsError(try ConfigurationTransferCodec.decode(data, password: password)) {
                        XCTAssertEqual($0 as? ConfigurationTransferError, .inconsistentContents)
                    }
                }
            }
        }
    }

    func testDuplicateObjectKeysCannotHideLegacyMarkersFromDomainDecoder() throws {
        var rejected = 0
        for objects in [
            #""ignored":{"templateVersions":{}},"ignored":{}"#,
            #""ignored":{},"ignored":{"templateVersions":{}}"#
        ] {
            let data = Data((#"{"format":"aagedal-ftp-sync-configuration","version":2,"# + objects + "}").utf8)
            // Match the same Foundation key-selection policy as the actual models.
            do { try VersionedStoreCodec.rejectLegacyTemplateMarkers(in: data) }
            catch VersionedStoreCodec.HeaderError.requiresVersion3Storage {
                rejected += 1
                XCTAssertThrowsError(try ConfigurationTransferCodec.decode(data, password: nil)) {
                    XCTAssertEqual($0 as? ConfigurationTransferError, .inconsistentContents)
                }
            }
        }
        XCTAssertGreaterThan(rejected, 0)
    }

    func testValidActiveContentsCannotBeRelabeledAsLegacy() throws {
        let encoded = try ConfigurationTransferCodec.encode(transfer(active: true), password: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for version in [1, 2] {
            object["version"] = version
            let payload = try JSONSerialization.data(withJSONObject: object)
            for data in [payload, try encrypted(payload)] {
                XCTAssertThrowsError(try ConfigurationTransferCodec.decode(data, password: password)) {
                    XCTAssertEqual($0 as? ConfigurationTransferError, .inconsistentContents)
                }
            }
        }
    }

    func testDecryptedInnerHeaderIsValidatedBeforeMalformedDomainData() throws {
        for (format, version, expected) in [
            (ConfigurationTransfer.formatIdentifier, 99, ConfigurationTransferError.unsupportedVersion(99)),
            ("unrelated", 3, ConfigurationTransferError.invalidFormat)
        ] {
            let payload = try JSONSerialization.data(withJSONObject: ["format": format, "version": version, "jobs": false])
            XCTAssertThrowsError(try ConfigurationTransferCodec.decode(encrypted(payload), password: password)) {
                XCTAssertEqual($0 as? ConfigurationTransferError, expected)
            }
        }
    }

    func testFrozenVersionTwoProductionHeaderGateRejectsActualActiveExport() throws {
        let data = try ConfigurationTransferCodec.encode(transfer(active: true), password: nil)
        XCTAssertThrowsError(try VersionTwoHeaderGate.protection(of: data)) {
            XCTAssertEqual($0 as? ConfigurationTransferError, .unsupportedVersion(3))
        }
        XCTAssertEqual(try VersionTwoHeaderGate.protection(of: ConfigurationTransferCodec.encode(transfer(active: false), password: nil)), .unencrypted)
    }

    /// Builds authenticated hostile-inner-payload fixtures independently of encode(),
    /// which correctly refuses invalid transfers. Uses the unchanged envelope-v1 wire contract.
    private func encrypted(_ payload: Data) throws -> Data {
        let salt = Data(repeating: 7, count: 16)
        let iterations = 100_000
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                password.withCString { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                        output.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        var aad = Data("aagedal-ftp-sync-encrypted|1|AES-256-GCM|PBKDF2-HMAC-SHA256|100000|".utf8)
        aad.append(salt)
        let combined = try XCTUnwrap(AES.GCM.seal(payload, using: SymmetricKey(data: derived), authenticating: aad).combined)
        return try JSONSerialization.data(withJSONObject: ["format": "aagedal-ftp-sync-encrypted", "version": 1,
            "encryption": "AES-256-GCM", "keyDerivation": "PBKDF2-HMAC-SHA256", "iterations": iterations,
            "salt": salt.base64EncodedString(), "sealedPayload": combined.base64EncodedString()])
    }
}

/// Frozen production protection() body from app revision 263562e, with only its
/// containing type/constants made local. This proves that real v3 exports fail
/// the old admission gate; it is not evidence of running a historical binary.
private enum VersionTwoHeaderGate {
    private static let maximumFileSize = 50 * 1_024 * 1_024
    private static let envelopeFormat = "aagedal-ftp-sync-encrypted"
    private static let envelopeVersion = 1
    private enum ConfigurationTransfer {
        static let formatIdentifier = "aagedal-ftp-sync-configuration"
        static let minimumSupportedVersion = 1
        static let currentVersion = 2
    }
    private struct FormatProbe: Decodable { let format: String; let version: Int }
    private static var configuredDecoder: JSONDecoder { JSONDecoder() }
    static func protection(of data: Data) throws -> ConfigurationTransferProtection {
        guard data.count <= maximumFileSize else { throw ConfigurationTransferError.fileTooLarge }
        let probe: FormatProbe
        do {
            probe = try configuredDecoder.decode(FormatProbe.self, from: data)
        } catch {
            throw ConfigurationTransferError.invalidFormat
        }
        switch probe.format {
        case envelopeFormat:
            guard probe.version == envelopeVersion else {
                throw ConfigurationTransferError.unsupportedVersion(probe.version)
            }
            return .encrypted
        case ConfigurationTransfer.formatIdentifier:
            guard (ConfigurationTransfer.minimumSupportedVersion ... ConfigurationTransfer.currentVersion)
                .contains(probe.version) else {
                throw ConfigurationTransferError.unsupportedVersion(probe.version)
            }
            return .unencrypted
        default:
            throw ConfigurationTransferError.invalidFormat
        }
    }
}
