import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AagedalFTPSync

final class AuraFaceComponentInstallerTests: XCTestCase {
    private struct Fixture {
        let key: Curve25519.Signing.PrivateKey
        let trust: AuraFaceDistributionTrust
        let descriptor: AuraFaceDistributionDescriptor
        let descriptorData: Data
        let signatureData: Data
        let archiveData: Data
    }

    private final class DownloadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [URL: Data]
        private(set) var requested: [URL] = []
        var finalURLOverride: URL?
        var archiveError: Error?

        init(payloads: [URL: Data] = [:]) { self.payloads = payloads }
        func install(_ payloads: [URL: Data]) { lock.withLock { self.payloads = payloads } }

        func client() -> AuraFaceDownloadClient {
            AuraFaceDownloadClient { [self] url, destination, maximum, progress in
                let value: Data = try lock.withLock {
                    requested.append(url)
                    if url.path.hasSuffix(".zip"), let archiveError { throw archiveError }
                    guard let data = payloads[url] else { throw URLError(.unsupportedURL) }
                    return data
                }
                guard value.count <= maximum else { throw AuraFaceComponentError.responseTooLarge }
                try value.write(to: destination, options: [.atomic])
                progress(value.count, value.count)
                return .init(statusCode: 200, finalURL: finalURLOverride ?? url, byteCount: value.count)
            }
        }
    }

    func testCanonicalSignedDescriptorPinsOriginSizesAndHashes() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(try AuraFaceDistributionContract.verify(
            descriptorData: fixture.descriptorData, signatureData: fixture.signatureData,
            trust: fixture.trust), fixture.descriptor)

        var nonCanonical = fixture.descriptorData
        nonCanonical.append(0x0a)
        let replacementSignature = try fixture.key.signature(for: nonCanonical).base64EncodedData()
        XCTAssertThrowsError(try AuraFaceDistributionContract.verify(
            descriptorData: nonCanonical, signatureData: replacementSignature, trust: fixture.trust)) {
            XCTAssertEqual($0 as? AuraFaceComponentError, .nonCanonicalDescriptor)
        }

        var tampered = fixture.descriptorData
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try AuraFaceDistributionContract.verify(
            descriptorData: tampered, signatureData: fixture.signatureData, trust: fixture.trust)) {
            XCTAssertEqual($0 as? AuraFaceComponentError, .invalidDescriptorSignature)
        }
    }

    func testInstallResolveAndRemovalAreOfflineAfterDownload() async throws {
        let fixture = try makeFixture()
        let root = try temporaryRoot()
        let probe = DownloadProbe()
        probe.install([
            fixture.trust.descriptorURL: fixture.descriptorData,
            fixture.trust.signatureURL: fixture.signatureData,
            fixture.descriptor.downloadURL: fixture.archiveData,
        ])
        let installer = try makeInstaller(fixture: fixture, root: root, client: probe.client())
        _ = try await installer.downloadAndInstall()
        XCTAssertEqual(probe.requested, [fixture.trust.descriptorURL, fixture.trust.signatureURL,
                                         fixture.descriptor.downloadURL])

        let offline = AuraFaceDownloadClient { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        let reopened = try makeInstaller(fixture: fixture, root: root, client: offline)
        let resolution = try await reopened.resolveInstalled()
        XCTAssertEqual(resolution.availability, .installed(version: fixture.descriptor.modelVersion))

        try await reopened.removeInstalled()
        let removed = try await reopened.resolveInstalled()
        XCTAssertEqual(removed.availability, .notInstalled)
    }

    func testRedirectAndCancellationNeverPublishCandidate() async throws {
        let fixture = try makeFixture()
        let redirectRoot = try temporaryRoot()
        let redirect = DownloadProbe()
        redirect.install([
            fixture.trust.descriptorURL: fixture.descriptorData,
            fixture.trust.signatureURL: fixture.signatureData,
            fixture.descriptor.downloadURL: fixture.archiveData,
        ])
        redirect.finalURLOverride = URL(string: "https://models.test.invalid/redirected")!
        let redirected = try makeInstaller(fixture: fixture, root: redirectRoot, client: redirect.client())
        await XCTAssertThrowsErrorAsync(try await redirected.downloadAndInstall()) {
            XCTAssertEqual($0 as? AuraFaceComponentError, .redirectedResponse)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: redirectRoot.appendingPathComponent("current").path))

        let cancellationRoot = try temporaryRoot()
        let cancelled = DownloadProbe()
        cancelled.install([
            fixture.trust.descriptorURL: fixture.descriptorData,
            fixture.trust.signatureURL: fixture.signatureData,
        ])
        cancelled.archiveError = CancellationError()
        let cancellingInstaller = try makeInstaller(fixture: fixture, root: cancellationRoot,
                                                     client: cancelled.client())
        await XCTAssertThrowsErrorAsync(try await cancellingInstaller.downloadAndInstall()) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancellationRoot.appendingPathComponent("current").path))
    }

    func testArchiveAdmissionPrecedesExtractionAndRejectsPathSubstitution() async throws {
        let files = packageFiles()
        var entries = files.map { (AuraFaceDistributionContract.packageDirectory + "/" + $0.key, $0.value) }
        entries[0] = (AuraFaceDistributionContract.packageDirectory + "/Data/../Manifest.json", entries[0].1)
        let badArchive = zip(entries)
        let fixture = try makeFixture(archiveOverride: badArchive)
        let root = try temporaryRoot()
        let probe = DownloadProbe()
        probe.install([
            fixture.trust.descriptorURL: fixture.descriptorData,
            fixture.trust.signatureURL: fixture.signatureData,
            fixture.descriptor.downloadURL: fixture.archiveData,
        ])
        let installer = try makeInstaller(fixture: fixture, root: root, client: probe.client())
        await XCTAssertThrowsErrorAsync(try await installer.downloadAndInstall()) {
            XCTAssertTrue($0 as? AuraFaceComponentError == .unsafeArchive ||
                          $0 as? AuraFaceComponentError == .packageFileSetMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("current").path))
    }

    func testInterruptedPublicationRecoversVerifiedRollbackWithoutNetwork() async throws {
        let fixture = try makeFixture()
        let root = try temporaryRoot()
        let probe = DownloadProbe()
        probe.install([
            fixture.trust.descriptorURL: fixture.descriptorData,
            fixture.trust.signatureURL: fixture.signatureData,
            fixture.descriptor.downloadURL: fixture.archiveData,
        ])
        let installer = try makeInstaller(fixture: fixture, root: root, client: probe.client())
        _ = try await installer.downloadAndInstall()
        try FileManager.default.moveItem(at: root.appendingPathComponent("current"),
                                         to: root.appendingPathComponent("rollback"))

        let recovered = try await installer.resolveInstalled()
        XCTAssertEqual(recovered.availability, .installed(version: fixture.descriptor.modelVersion))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("current").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rollback").path))
    }

    func testComponentRootStaysOutsideVersionThreeInventory() throws {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFaceLayout-\(UUID().uuidString)", isDirectory: true)
        let storage = AppStorageLayout(root: applicationSupport.appendingPathComponent("v3", isDirectory: true),
                                       storageFormat: .version3)
        XCTAssertEqual(try AuraFaceComponentInstaller.componentRoot(forValidatedStorage: storage),
                       applicationSupport.appendingPathComponent("Components/AuraFace", isDirectory: true))
    }

    private func makeFixture(archiveOverride: Data? = nil) throws -> Fixture {
        let key = Curve25519.Signing.PrivateKey()
        let descriptorURL = URL(string: "https://models.test.invalid/AuraFace.distribution.json")!
        let signatureURL = URL(string: "https://models.test.invalid/AuraFace.distribution.json.sig")!
        let archiveURL = URL(string: "https://models.test.invalid/AuraFaceR100.mlpackage.zip")!
        let origin = try AuraFaceDistributionOrigin(host: "models.test.invalid")
        let trust = try AuraFaceDistributionTrust(
            descriptorURL: descriptorURL, signatureURL: signatureURL, allowedOrigins: [origin],
            publicKeyData: key.publicKey.rawRepresentation, supportedEmbeddingVersion: 3)
        let files = packageFiles()
        let archive = archiveOverride ?? zip(files.map {
            (AuraFaceDistributionContract.packageDirectory + "/" + $0.key, $0.value)
        })
        let descriptor = AuraFaceDistributionDescriptor(
            schemaVersion: 2, componentID: AuraFaceDistributionContract.componentID,
            modelVersion: "AuraFace-v1/glintr100", embeddingVersion: 3,
            packageDirectory: AuraFaceDistributionContract.packageDirectory,
            packageFiles: files.mapValues { .init(byteCount: $0.count, sha256: sha($0)) },
            archive: .init(fileName: AuraFaceDistributionContract.archiveFile,
                           byteCount: archive.count, sha256: sha(archive)),
            downloadURL: archiveURL)
        let descriptorData = try AuraFaceDistributionContract.canonicalData(for: descriptor)
        let signatureData = try key.signature(for: descriptorData).base64EncodedData()
        return .init(key: key, trust: trust, descriptor: descriptor, descriptorData: descriptorData,
                     signatureData: signatureData, archiveData: archive)
    }

    private func makeInstaller(fixture: Fixture, root: URL, client: AuraFaceDownloadClient) throws
        -> AuraFaceComponentInstaller {
        try AuraFaceComponentInstaller(trust: fixture.trust, root: root, downloads: client) { _, destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try Data("compiled fixture".utf8).write(to: destination.appendingPathComponent("model.bin"))
        }
    }

    private func temporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFaceInstaller-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let components = parent.appendingPathComponent("Components", isDirectory: true)
        try FileManager.default.createDirectory(at: components, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return components.appendingPathComponent("AuraFace", isDirectory: true)
    }

    private func packageFiles() -> [String: Data] {
        [
            "Data/com.apple.CoreML/model.mlmodel": Data("model".utf8),
            "Data/com.apple.CoreML/weights/weight.bin": Data("weights".utf8),
            "Manifest.json": Data("{\"model\":\"fixture\"}".utf8),
        ]
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func zip(_ entries: [(String, Data)]) -> Data {
        struct Central { let name: Data; let bytes: Data; let crc: UInt32; let offset: UInt32 }
        var result = Data(), central: [Central] = []
        for (path, bytes) in entries.sorted(by: { $0.0 < $1.0 }) {
            let name = Data(path.utf8), crc = crc32(bytes), offset = UInt32(result.count)
            result.le32(0x0403_4b50); result.le16(20); result.le16(0x0800); result.le16(0)
            result.le16(0); result.le16(0); result.le32(crc); result.le32(UInt32(bytes.count))
            result.le32(UInt32(bytes.count)); result.le16(UInt16(name.count)); result.le16(0)
            result.append(name); result.append(bytes)
            central.append(.init(name: name, bytes: bytes, crc: crc, offset: offset))
        }
        let centralOffset = UInt32(result.count)
        for item in central {
            result.le32(0x0201_4b50); result.le16(UInt16(3 << 8) | 20); result.le16(20)
            result.le16(0x0800); result.le16(0); result.le16(0); result.le16(0); result.le32(item.crc)
            result.le32(UInt32(item.bytes.count)); result.le32(UInt32(item.bytes.count))
            result.le16(UInt16(item.name.count)); result.le16(0); result.le16(0); result.le16(0)
            result.le16(0); result.le32(UInt32(S_IFREG | 0o600) << 16); result.le32(item.offset)
            result.append(item.name)
        }
        let centralSize = UInt32(result.count) - centralOffset
        result.le32(0x0605_4b50); result.le16(0); result.le16(0)
        result.le16(UInt16(entries.count)); result.le16(UInt16(entries.count))
        result.le32(centralSize); result.le32(centralOffset); result.le16(0)
        return result
    }

    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        }
        return value ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func le32(_ value: UInt32) {
        le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
