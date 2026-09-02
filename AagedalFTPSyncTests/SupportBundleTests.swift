import Foundation
import XCTest
@testable import AagedalFTPSync

final class SupportBundleTests: XCTestCase {
    func testBundleContainsConfigurationShapeVersionsAndRecentErrors() throws {
        var job = SyncJob()
        job.name = "Secret newsroom"
        job.left = Endpoint(
            kind: .sftp,
            host: "private.example.test",
            username: "reporter",
            remotePath: "/embargoed",
            credentialID: "secret-keychain-id",
            hostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        job.right = Endpoint(
            kind: .local,
            localPath: "/Users/reporter/Private Photos",
            bookmark: Data("secret-bookmark".utf8)
        )
        job.filter = FileFilter(
            preset: .custom,
            customExtensions: "jpg, newsroom-secret",
            includeHiddenFiles: false,
            recentHours: 12
        )
        job.targetCleanup = TargetCleanup(olderThanHours: 24)
        job.metadataAutomation = MetadataAutomation(isEnabled: true)
        let failure = SyncFailureRecord(
            jobID: job.id,
            occurredAt: Date(timeIntervalSince1970: 2_000),
            message: "Upload failed for sftp://reporter:password@private.example.test/embargoed/SECRET.JPG"
        )

        let data = try SupportBundleCodec.encode(
            jobs: [job],
            metadataPresetCount: 3,
            photographerCount: 2,
            failures: [job.id: [failure]],
            applicationVersion: "2.7.0",
            build: "32",
            operatingSystem: "macOS 15.6",
            generatedAt: Date(timeIntervalSince1970: 3_000)
        )
        let bundle = try SupportBundleCodec.decode(data)

        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertEqual(bundle.application, .init(version: "2.7.0", build: "32"))
        XCTAssertEqual(bundle.system.operatingSystem, "macOS 15.6")
        XCTAssertEqual(bundle.configuration.jobCount, 1)
        XCTAssertEqual(bundle.configuration.enabledJobCount, 1)
        XCTAssertEqual(bundle.configuration.metadataPresetCount, 3)
        XCTAssertEqual(bundle.configuration.photographerCount, 2)
        XCTAssertEqual(bundle.configuration.jobs.first?.left.kind, .sftp)
        XCTAssertEqual(bundle.configuration.jobs.first?.right.kind, .local)
        XCTAssertEqual(bundle.configuration.jobs.first?.customExtensionCount, 2)
        XCTAssertEqual(bundle.configuration.jobs.first?.cleanupEnabled, true)
        XCTAssertEqual(bundle.configuration.jobs.first?.metadataAutomationEnabled, true)
        XCTAssertEqual(bundle.recentErrors, [
            .init(
                occurredAt: failure.occurredAt,
                jobNumber: 1,
                category: "sync-run-failure"
            ),
        ])
    }

    func testBundleNeverCopiesSensitiveConfigurationOrErrorStrings() throws {
        var job = SyncJob()
        job.name = "SECRET_JOB_NAME"
        job.left = Endpoint(
            kind: .ftp,
            localPath: "SECRET_LOCAL_PATH",
            bookmark: Data("SECRET_BOOKMARK".utf8),
            host: "SECRET_HOST",
            username: "SECRET_USERNAME",
            remotePath: "/SECRET_REMOTE_PATH",
            credentialID: "SECRET_CREDENTIAL",
            hostKeyFingerprint: "SECRET_FINGERPRINT"
        )
        job.filter = FileFilter(preset: .custom, customExtensions: "SECRET_EXTENSION")
        let failure = SyncFailureRecord(
            jobID: job.id,
            message: "SECRET_ERROR_MESSAGE SECRET_FILENAME.JPG"
        )

        let data = try SupportBundleCodec.encode(
            jobs: [job],
            metadataPresetCount: 0,
            photographerCount: 0,
            failures: [job.id: [failure]],
            applicationVersion: "2.7.0",
            build: "32",
            operatingSystem: "macOS"
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        for secret in [
            "SECRET_JOB_NAME", "SECRET_LOCAL_PATH", "SECRET_BOOKMARK", "SECRET_HOST",
            "SECRET_USERNAME", "SECRET_REMOTE_PATH", "SECRET_CREDENTIAL", "SECRET_FINGERPRINT",
            "SECRET_EXTENSION", "SECRET_ERROR_MESSAGE", "SECRET_FILENAME", job.id.uuidString,
            failure.id.uuidString,
        ] {
            XCTAssertFalse(text.contains(secret), "Support bundle leaked \(secret)")
        }
    }

    func testBundleKeepsOnlyFiftyNewestErrorsAndMarksDeletedJobs() throws {
        let job = SyncJob()
        let deletedJobID = UUID()
        let failures = (0..<55).map { index in
            SyncFailureRecord(
                jobID: deletedJobID,
                occurredAt: Date(timeIntervalSince1970: Double(index)),
                message: "private error \(index)"
            )
        }

        let data = try SupportBundleCodec.encode(
            jobs: [job],
            metadataPresetCount: 0,
            photographerCount: 0,
            failures: [deletedJobID: failures],
            applicationVersion: "2.7.0",
            build: "32",
            operatingSystem: "macOS"
        )
        let bundle = try SupportBundleCodec.decode(data)

        XCTAssertEqual(bundle.recentErrors.count, SupportBundleCodec.maximumRecentErrors)
        XCTAssertEqual(bundle.recentErrors.first?.occurredAt, Date(timeIntervalSince1970: 54))
        XCTAssertEqual(bundle.recentErrors.last?.occurredAt, Date(timeIntervalSince1970: 5))
        XCTAssertTrue(bundle.recentErrors.allSatisfy { $0.jobNumber == nil })
    }
}
