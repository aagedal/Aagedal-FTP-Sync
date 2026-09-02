import Foundation
import XCTest
@testable import AagedalFTPSync

final class RemoteTransportIntegrationTests: XCTestCase {
    func testFTPUploadPublishesBytesAndLeavesNoStagingFiles() async throws {
        let configuration = try Self.configuration()
        try await assertSuccessfulUpload(kind: .ftp, configuration: configuration)
    }

    func testFTPPublicationFailureRestoresExistingFileAndCleansStaging() async throws {
        let configuration = try Self.configuration()
        try await assertPublicationFailure(kind: .ftp, configuration: configuration)
    }

    func testSFTPUploadPublishesBytesAndLeavesNoStagingFiles() async throws {
        let configuration = try Self.configuration()
        try await assertSuccessfulUpload(kind: .sftp, configuration: configuration)
    }

    func testSFTPPublicationFailureRestoresExistingFileAndCleansStaging() async throws {
        let configuration = try Self.configuration()
        try await assertPublicationFailure(kind: .sftp, configuration: configuration)
    }

    private func assertSuccessfulUpload(
        kind: EndpointKind,
        configuration: [String: String]
    ) async throws {
        let payload = Data("new-\(kind.rawValue)-payload\n".utf8)
        let relativePath = "\(kind.rawValue)-success.txt"
        let localURL = try temporaryFile(containing: payload)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let session = try makeSession(kind: kind, configuration: configuration)
        do {
            try await session.importFile(
                from: localURL,
                as: SyncFile(
                    relativePath: relativePath,
                    size: Int64(payload.count),
                    modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
                ),
                preserveDate: false,
                verifySize: true
            )
            let files = try await session.listFiles()
            XCTAssertEqual(files[relativePath]?.size, Int64(payload.count))

            let downloadedURL = try temporaryFile(containing: Data())
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            try await session.exportFile(try XCTUnwrap(files[relativePath]), to: downloadedURL)
            XCTAssertEqual(try Data(contentsOf: downloadedURL), payload)
            await session.close()
        } catch {
            await session.close()
            throw error
        }

        try assertNoStagingFiles(in: rootURL(kind: kind, configuration: configuration))
    }

    private func assertPublicationFailure(
        kind: EndpointKind,
        configuration: [String: String]
    ) async throws {
        let failureName = try required(
            kind == .ftp
                ? "AFTPSYNC_REMOTE_FTP_FAILURE_FILE"
                : "AFTPSYNC_REMOTE_SFTP_FAILURE_FILE",
            in: configuration
        )
        let replacement = Data("replacement-must-not-publish\n".utf8)
        let localURL = try temporaryFile(containing: replacement)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let session = try makeSession(kind: kind, configuration: configuration)

        do {
            try await session.importFile(
                from: localURL,
                as: SyncFile(
                    relativePath: failureName,
                    size: Int64(replacement.count),
                    modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
                ),
                preserveDate: false,
                verifySize: true
            )
            XCTFail("The fixture should reject publication of \(failureName)")
        } catch {
            // The fixture rejects both staged-file publication attempts. The
            // transport must restore the backup and remove its staged upload.
        }
        await session.close()

        let root = try rootURL(kind: kind, configuration: configuration)
        let original = try required("AFTPSYNC_REMOTE_ORIGINAL_CONTENT", in: configuration)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(failureName), encoding: .utf8),
            original
        )
        try assertNoStagingFiles(in: root)
    }

    private func makeSession(
        kind: EndpointKind,
        configuration: [String: String]
    ) throws -> any EndpointSession {
        let portName = kind == .ftp
            ? "AFTPSYNC_REMOTE_FTP_PORT"
            : "AFTPSYNC_REMOTE_SFTP_PORT"
        let endpoint = Endpoint(
            kind: kind,
            host: try required("AFTPSYNC_REMOTE_HOST", in: configuration),
            port: try requiredInteger(portName, in: configuration),
            username: try required("AFTPSYNC_REMOTE_USERNAME", in: configuration),
            remotePath: "/",
            hostKeyFingerprint: kind == .sftp
                ? try required("AFTPSYNC_REMOTE_SFTP_FINGERPRINT", in: configuration)
                : ""
        )
        return try EndpointSessionFactory.make(
            endpoint: endpoint,
            password: try required("AFTPSYNC_REMOTE_PASSWORD", in: configuration)
        )
    }

    private func rootURL(
        kind: EndpointKind,
        configuration: [String: String]
    ) throws -> URL {
        URL(fileURLWithPath: try required(
            kind == .ftp ? "AFTPSYNC_REMOTE_FTP_ROOT" : "AFTPSYNC_REMOTE_SFTP_ROOT",
            in: configuration
        ), isDirectory: true)
    }

    private func temporaryFile(containing data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-transport-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func assertNoStagingFiles(in root: URL) throws {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
            )
        )
        let stagingPaths = enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.hasPrefix(".aagedal-sync-")
        }
        XCTAssertEqual(stagingPaths, [])
    }

    private func required(_ name: String, in configuration: [String: String]) throws -> String {
        guard let value = configuration[name], !value.isEmpty else {
            throw IntegrationConfigurationError.missing(name)
        }
        return value
    }

    private func requiredInteger(
        _ name: String,
        in configuration: [String: String]
    ) throws -> Int {
        let value = try required(name, in: configuration)
        guard let integer = Int(value), integer > 0 else {
            throw IntegrationConfigurationError.invalidInteger(name, value)
        }
        return integer
    }

    private static func configuration() throws -> [String: String] {
        var configuration = ProcessInfo.processInfo.environment
        if configuration["AFTPSYNC_RUN_REMOTE_TRANSPORT_TESTS"] != "1",
           let path = discoveredConfigurationPath(),
           let data = FileManager.default.contents(atPath: path),
           let values = try JSONSerialization.jsonObject(with: data) as? [String: String] {
            configuration.merge(values) { _, configuredValue in configuredValue }
        }
        guard configuration["AFTPSYNC_RUN_REMOTE_TRANSPORT_TESTS"] == "1" else {
            throw XCTSkip(
                "Use Scripts/run-remote-transport-tests.py to run loopback FTP/SFTP integration tests."
            )
        }
        return configuration
    }

    private static func discoveredConfigurationPath() -> String? {
        let fileManager = FileManager.default
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return candidates
            .filter { $0.lastPathComponent.hasPrefix("aftpsync-remote-transport-") }
            .map { $0.appendingPathComponent("integration-configuration.json") }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { return nil }
                return (url, date)
            }
            .filter { Date().timeIntervalSince($0.1) < 600 }
            .max { $0.1 < $1.1 }?
            .0.path
    }
}

private enum IntegrationConfigurationError: LocalizedError {
    case missing(String)
    case invalidInteger(String, String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing integration configuration value \(name)."
        case .invalidInteger(let name, let value):
            "Integration configuration value \(name) is not a positive integer: \(value)."
        }
    }
}
