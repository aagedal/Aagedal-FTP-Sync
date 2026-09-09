import Foundation
import XCTest
@testable import AagedalFTPSync

final class RemoteTransportIntegrationTests: XCTestCase {
    func testSharedServerDownloadUploadRoundTripExcludesRenamedCopies() async throws {
        let configuration = try Self.configuration()
        for kind in [EndpointKind.ftp, .ftps, .sftp] {
            let session = try makeSession(kind: kind, configuration: configuration)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let initials = "TA" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let filename = initials + "_001.JPG"
            let originalBytes = Data("camera original".utf8)
            let original = try temporaryFile(containing: originalBytes)
            defer { try? FileManager.default.removeItem(at: original) }
            let file = SyncFile(relativePath: filename, size: Int64(originalBytes.count), modifiedAt: Date().addingTimeInterval(-300))
            let remote = Endpoint(kind: kind, host: "localhost", username: "integration",
                hostKeyFingerprint: kind == .sftp ? try required("AFTPSYNC_REMOTE_SFTP_FINGERPRINT", in: configuration) : "")
            func localEndpoint(_ name: String) throws -> Endpoint {
                let folder = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return Endpoint(kind: .local, localPath: folder.path,
                    bookmark: try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            }
            let downloadFolder = try localEndpoint("downloads")
            let engine = SyncEngine(
                sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
                sessionFactory: { endpoint, _, _ -> any EndpointSession in
                    if endpoint.kind.isRemote { return session }
                    return try LocalEndpointSession(endpoint: endpoint)
                })
            do {
                try await session.importFile(from: original, as: file, preserveDate: true, verifySize: true)
                var downloadJob = SyncJob(name: "Shared-server download")
                downloadJob.left = remote
                downloadJob.right = downloadFolder
                downloadJob.filter = FileFilter(photographerInitials: initials, excludedFilenameSuffixes: "_EDITED")
                let downloaded = try await engine.run(job: downloadJob, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(downloaded.transferred, 1, kind.rawValue)
                let localPhoto = URL(fileURLWithPath: downloadFolder.localPath).appendingPathComponent(filename)
                XCTAssertEqual(try Data(contentsOf: localPhoto), originalBytes)
                let editedBytes = Data("edited photo for publication".utf8)
                try editedBytes.write(to: localPhoto)
                var uploadJob = SyncJob(name: "Shared-server upload")
                uploadJob.left = downloadFolder
                uploadJob.right = remote
                uploadJob.uploadNaming = UploadNaming(suffix: "_EDITED")
                let uploaded = try await engine.run(job: uploadJob, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(uploaded.transferred, 1, kind.rawValue)
                let unchanged = try await engine.run(job: uploadJob, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(unchanged.transferred, 0, kind.rawValue)
                let editedPath = try XCTUnwrap(uploadJob.uploadNaming).relativePath(for: filename)
                let remoteFiles = try await session.listFiles()
                let editedFile = try XCTUnwrap(remoteFiles[editedPath])
                let check = try temporaryFile(containing: Data())
                defer { try? FileManager.default.removeItem(at: check) }
                try await session.exportFile(editedFile, to: check)
                XCTAssertEqual(try Data(contentsOf: check), editedBytes)
                // Start with an empty download folder: this proves the exclusion
                // itself prevents a loop, independently of timestamp comparisons.
                downloadJob.right = try localEndpoint("fresh-downloads")
                let downloadedAgain = try await engine.run(job: downloadJob, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(downloadedAgain.transferred, 1, kind.rawValue)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloadJob.right.localPath), [filename])
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: downloadJob.right.localPath).appendingPathComponent(filename)), originalBytes)
                // Each engine run closes its sessions. Reconnect before fixture cleanup.
                _ = try await session.listFiles()
                try await session.removeFile(file)
                try await session.removeFile(editedFile)
                await session.close()
                try assertNoStagingFiles(in: rootURL(kind: kind, configuration: configuration))
            } catch {
                await session.close()
                throw error
            }
        }
    }

    func testUploadSizeVerificationPreservesExistingFileAcrossTransports() async throws {
        let configuration = try Self.configuration()
        for kind in [EndpointKind.ftp, .ftps, .sftp] {
            let session = try makeSession(kind: kind, configuration: configuration)
            let original = try temporaryFile(containing: Data("original".utf8))
            let replacement = try temporaryFile(containing: Data("replacement".utf8))
            defer {
                try? FileManager.default.removeItem(at: original)
                try? FileManager.default.removeItem(at: replacement)
            }
            let name = "size-check-\(UUID().uuidString).jpg"
            let file = SyncFile(relativePath: name, size: 8, modifiedAt: Date())
            do {
                try await session.importFile(from: original, as: file, preserveDate: true, verifySize: true)
                do {
                    try await session.importFile(from: replacement, as: file, preserveDate: true, verifySize: true)
                    XCTFail("A mismatched upload must not be published")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Size verification failed"), error.localizedDescription)
                }
                let downloaded = try temporaryFile(containing: Data())
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try await session.exportFile(file, to: downloaded)
                XCTAssertEqual(try Data(contentsOf: downloaded), Data("original".utf8))
                try await session.removeFile(file)
                await session.close()
                try assertNoStagingFiles(in: rootURL(kind: kind, configuration: configuration))
            } catch {
                await session.close()
                throw error
            }
        }
    }

    func testFTPCleanupDuringDownloadReconnectsAndPreservesPermissionErrors() async throws {
        let configuration = try Self.configuration()
        for kind in [EndpointKind.ftp, .ftps] {
            for mode in ["GONE", "STALL", "DENIED", "RETRY"] {
                let session = try makeSession(kind: kind, configuration: configuration)
                let bytes = Data("photo bytes".utf8)
                let input = try temporaryFile(containing: bytes)
                let output = try temporaryFile(containing: Data())
                defer {
                    try? FileManager.default.removeItem(at: input)
                    try? FileManager.default.removeItem(at: output)
                }
                let file = SyncFile(
                    relativePath: "CLEANUP-\(mode)-\(UUID().uuidString).JPG",
                    size: Int64(bytes.count), modifiedAt: Date()
                )
                let survivor = SyncFile(
                    relativePath: "SURVIVOR-\(UUID().uuidString).JPG",
                    size: Int64(bytes.count), modifiedAt: Date()
                )
                do {
                    try await session.importFile(from: input, as: file, preserveDate: true, verifySize: true)
                    try await session.importFile(from: input, as: survivor, preserveDate: true, verifySize: true)
                    let before = try await session.listFiles()
                    XCTAssertNotNil(before[file.relativePath])
                    do {
                        try await session.exportFile(file, to: output)
                        XCTFail("The fixture must fail the requested download")
                    } catch let failure as FTPFileNoLongerListed {
                        XCTAssertTrue(mode == "GONE" || mode == "STALL")
                        XCTAssertEqual(failure.relativePath, file.relativePath)
                    } catch let failure as FTPDownloadFailure {
                        XCTAssertTrue(mode == "DENIED" || mode == "RETRY")
                        let reply = try XCTUnwrap(failure.underlyingError as? FTPCommandFailure)
                        XCTAssertEqual(reply.code, mode == "DENIED" ? 550 : 450)
                        XCTAssertEqual(failure.relativePath, file.relativePath)
                    }
                    try await session.exportFile(survivor, to: output)
                    XCTAssertEqual(try Data(contentsOf: output), bytes)
                    let after = try await session.listFiles()
                    XCTAssertEqual(after[file.relativePath] != nil, mode == "DENIED" || mode == "RETRY")
                    if mode == "RETRY" {
                        await session.close()
                        try await session.exportFile(file, to: output)
                        XCTAssertEqual(try Data(contentsOf: output), bytes)
                    }
                    if mode == "DENIED" || mode == "RETRY" { try await session.removeFile(file) }
                    try await session.removeFile(survivor)
                    await session.close()
                } catch {
                    await session.close()
                    throw error
                }
            }
        }
    }

    func testVerifiedSourceRemovalRestoresChangedSourcesAcrossTransports() async throws {
        let configuration = try Self.configuration()
        for kind in [EndpointKind.ftp, .ftps, .sftp] {
            for replacement in ["modified", "modified-and-larger"] {
                let original = try temporaryFile(containing: Data("original".utf8))
                let changed = try temporaryFile(containing: Data(replacement.utf8))
                defer {
                    try? FileManager.default.removeItem(at: original)
                    try? FileManager.default.removeItem(at: changed)
                }
                let session = try makeSession(kind: kind, configuration: configuration)
                let file = SyncFile(relativePath: "verified-\(UUID().uuidString).txt", size: Int64(replacement.utf8.count), modifiedAt: Date())
                do {
                    try await session.importFile(from: changed, as: file, preserveDate: true, verifySize: true)
                    do {
                        try await session.removeFilesTransactionally([file], matching: [original])
                        XCTFail("A changed source must be restored for \(kind)")
                    } catch {
                        XCTAssertTrue(
                            error.localizedDescription.contains("source changed")
                                || error.localizedDescription.contains("exceeded its advertised size"),
                            error.localizedDescription
                        )
                    }
                    let restored = try await session.listFiles()
                    XCTAssertNotNil(restored[file.relativePath])
                    let restoredURL = try temporaryFile(containing: Data())
                    defer { try? FileManager.default.removeItem(at: restoredURL) }
                    try await session.exportFile(file, to: restoredURL)
                    XCTAssertEqual(try Data(contentsOf: restoredURL), Data(replacement.utf8))
                    try await session.removeFilesTransactionally([file], matching: [changed])
                    let remaining = try await session.listFiles()
                    XCTAssertNil(remaining[file.relativePath])
                    await session.close()
                } catch {
                    await session.close()
                    throw error
                }
            }
        }
    }

    func testFTPUploadPublishesBytesAndLeavesNoStagingFiles() async throws {
        let configuration = try Self.configuration()
        try await assertSuccessfulUpload(kind: .ftp, configuration: configuration)
    }

    func testFTPPublicationFailureRestoresExistingFileAndCleansStaging() async throws {
        let configuration = try Self.configuration()
        try await assertPublicationFailure(kind: .ftp, configuration: configuration)
    }

    func testTrustedImplicitFTPSUploadPublishesBytesAndLeavesNoStagingFiles() async throws {
        let configuration = try Self.configuration()
        try await assertSuccessfulUpload(kind: .ftps, configuration: configuration)
    }

    func testTrustedImplicitFTPSPublicationFailureRestoresExistingFileAndCleansStaging() async throws {
        let configuration = try Self.configuration()
        try await assertPublicationFailure(kind: .ftps, configuration: configuration)
    }

    func testImplicitFTPSRejectsUntrustedCertificate() async throws {
        let configuration = try Self.configuration()
        let stream = try NetworkStream(
            host: try required("AFTPSYNC_REMOTE_FTPS_HOST", in: configuration),
            port: try requiredInteger("AFTPSYNC_REMOTE_FTPS_PORT", in: configuration),
            tls: true,
            connectionTimeout: 2
        )
        defer { stream.cancel() }
        do {
            try await stream.start()
            XCTFail("Implicit FTPS must reject a certificate outside system trust.")
        } catch {
            // The production default has no custom anchor and rejects the fixture CA.
        }
    }

    func testImplicitFTPSTrustRootDoesNotBypassHostnameValidation() async throws {
        let configuration = try Self.configuration()
        let trustRootPath = try required(
            "AFTPSYNC_REMOTE_FTPS_TRUST_ROOT",
            in: configuration
        )
        let stream = try NetworkStream(
            host: "127.0.0.1",
            port: try requiredInteger("AFTPSYNC_REMOTE_FTPS_PORT", in: configuration),
            tls: true,
            tlsTrustRootCertificate: try Data(
                contentsOf: URL(fileURLWithPath: trustRootPath)
            ),
            connectionTimeout: 2
        )
        defer { stream.cancel() }
        do {
            try await stream.start()
            XCTFail("Implicit FTPS must reject a certificate for a different hostname.")
        } catch {
            // The custom CA is trusted, but the built-in SSL hostname policy still applies.
        }
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
        let failureName = try required(failureFileKey(for: kind), in: configuration)
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
        let host: String
        switch kind {
        case .ftp, .sftp:
            host = try required("AFTPSYNC_REMOTE_HOST", in: configuration)
        case .ftps:
            host = try required("AFTPSYNC_REMOTE_FTPS_HOST", in: configuration)
        case .local:
            throw IntegrationConfigurationError.unsupportedKind(kind)
        }
        let endpoint = Endpoint(
            kind: kind,
            host: host,
            port: try requiredInteger(portKey(for: kind), in: configuration),
            username: try required("AFTPSYNC_REMOTE_USERNAME", in: configuration),
            remotePath: "/",
            hostKeyFingerprint: kind == .sftp
                ? try required("AFTPSYNC_REMOTE_SFTP_FINGERPRINT", in: configuration)
                : ""
        )
        let trustRootCertificate: Data?
        if kind == .ftps {
            let path = try required("AFTPSYNC_REMOTE_FTPS_TRUST_ROOT", in: configuration)
            trustRootCertificate = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            trustRootCertificate = nil
        }
        return try EndpointSessionFactory.make(
            endpoint: endpoint,
            password: try required("AFTPSYNC_REMOTE_PASSWORD", in: configuration),
            tlsTrustRootCertificate: trustRootCertificate
        )
    }

    private func rootURL(
        kind: EndpointKind,
        configuration: [String: String]
    ) throws -> URL {
        URL(
            fileURLWithPath: try required(rootKey(for: kind), in: configuration),
            isDirectory: true
        )
    }

    private func failureFileKey(for kind: EndpointKind) throws -> String {
        switch kind {
        case .ftp: "AFTPSYNC_REMOTE_FTP_FAILURE_FILE"
        case .ftps: "AFTPSYNC_REMOTE_FTPS_FAILURE_FILE"
        case .sftp: "AFTPSYNC_REMOTE_SFTP_FAILURE_FILE"
        case .local: throw IntegrationConfigurationError.unsupportedKind(kind)
        }
    }

    private func portKey(for kind: EndpointKind) throws -> String {
        switch kind {
        case .ftp: "AFTPSYNC_REMOTE_FTP_PORT"
        case .ftps: "AFTPSYNC_REMOTE_FTPS_PORT"
        case .sftp: "AFTPSYNC_REMOTE_SFTP_PORT"
        case .local: throw IntegrationConfigurationError.unsupportedKind(kind)
        }
    }

    private func rootKey(for kind: EndpointKind) throws -> String {
        switch kind {
        case .ftp: "AFTPSYNC_REMOTE_FTP_ROOT"
        case .ftps: "AFTPSYNC_REMOTE_FTPS_ROOT"
        case .sftp: "AFTPSYNC_REMOTE_SFTP_ROOT"
        case .local: throw IntegrationConfigurationError.unsupportedKind(kind)
        }
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
        let configuredPath = configuration["AFTPSYNC_REMOTE_TRANSPORT_CONFIG_PATH"]
        if configuration["AFTPSYNC_RUN_REMOTE_TRANSPORT_TESTS"] != "1",
           let path = configuredPath ?? discoveredConfigurationPath() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw IntegrationConfigurationError.invalidConfigurationFile(path)
            }
            configuration.merge(values) { _, configuredValue in configuredValue }
        }
        guard configuration["AFTPSYNC_RUN_REMOTE_TRANSPORT_TESTS"] == "1" else {
            throw XCTSkip(
                "Use Scripts/run-remote-transport-tests.py to run loopback FTP/FTPS/SFTP integration tests."
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
    case invalidConfigurationFile(String)
    case unsupportedKind(EndpointKind)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing integration configuration value \(name)."
        case .invalidInteger(let name, let value):
            "Integration configuration value \(name) is not a positive integer: \(value)."
        case .invalidConfigurationFile(let path):
            "The integration configuration is not a string dictionary: \(path)."
        case .unsupportedKind(let kind):
            "The remote transport integration harness does not support \(kind.rawValue)."
        }
    }
}
