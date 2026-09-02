import Foundation
import XCTest
@testable import AagedalFTPSync

final class SyncEventLoggerTests: XCTestCase {
    func testFormattedEventContainsOnlyTypedDiagnosticFields() throws {
        let runID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let jobID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let event = SyncLogEvent(
            runID: runID,
            jobID: jobID,
            stage: .protocolOperation,
            operation: .listing,
            outcome: .failed,
            endpointRole: .left,
            endpointKind: .sftp,
            itemCount: nil,
            transferred: nil,
            deleted: nil,
            processed: nil,
            conflictCount: nil,
            failureCategory: .hostKeyTrust
        )

        XCTAssertEqual(
            event.formattedMessage,
            "event=sync-pipeline run_id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "
                + "job_id=11111111-2222-3333-4444-555555555555 stage=protocol "
                + "operation=listing outcome=failed endpoint_role=left endpoint_kind=sftp "
                + "failure_category=host-key-trust"
        )
    }

    func testFailureClassificationNeverCopiesSensitiveErrorText() {
        let sensitiveText = "reporter:password@example.test/private/IMG_0001.JPG"
        let category = SyncLogFailureCategory.classify(AppError.transferFailed(sensitiveText))
        let event = SyncLogEvent(
            runID: UUID(),
            jobID: UUID(),
            stage: .run,
            operation: .sync,
            outcome: .failed,
            endpointRole: nil,
            endpointKind: nil,
            itemCount: nil,
            transferred: 0,
            deleted: 0,
            processed: 0,
            conflictCount: 0,
            failureCategory: category
        )

        XCTAssertEqual(category, .transfer)
        XCTAssertFalse(event.formattedMessage.contains(sensitiveText))
        XCTAssertFalse(event.formattedMessage.contains("reporter"))
        XCTAssertFalse(event.formattedMessage.contains("IMG_0001"))
    }

    func testEngineEmitsRunProtocolAndPublicationEventsWithOneCorrelationID() async throws {
        let file = SyncFile(relativePath: "PRIVATE_NEWSROOM_NAME.JPG", size: 4, modifiedAt: Date())
        let source = SyncLoggingSession(files: [file.relativePath: file])
        let destination = SyncLoggingSession()
        let logger = LockedSyncEventLogger()
        let job = loggingJob()
        let engine = SyncEngine(eventLogger: logger) { endpoint, _, _ in
            endpoint.kind.isRemote ? source : destination
        }

        let result = try await engine.run(job: job, leftPassword: "do-not-log", rightPassword: nil)

        XCTAssertEqual(result.transferred, 1)
        let events = logger.events
        XCTAssertEqual(Set(events.map(\.runID)).count, 1)
        XCTAssertEqual(Set(events.map(\.jobID)), Set([job.id]))
        XCTAssertTrue(events.contains { $0.stage == .run && $0.outcome == .started })
        XCTAssertTrue(events.contains { $0.stage == .run && $0.outcome == .succeeded })
        XCTAssertTrue(events.contains {
            $0.stage == .protocolOperation && $0.operation == .listing
                && $0.endpointRole == .left && $0.endpointKind == .ftp
                && $0.outcome == .succeeded && $0.itemCount == 1
        })
        XCTAssertTrue(events.contains {
            $0.stage == .protocolOperation && $0.operation == .sourceRead
                && $0.endpointRole == .left && $0.endpointKind == .ftp
                && $0.outcome == .succeeded && $0.itemCount == 1
        })
        XCTAssertTrue(events.contains {
            $0.stage == .publication && $0.operation == .destinationOutput
                && $0.endpointRole == .right && $0.endpointKind == .local
                && $0.outcome == .succeeded && $0.itemCount == 1
        })

        let output = events.map(\.formattedMessage).joined(separator: "\n")
        XCTAssertFalse(output.contains(file.relativePath))
        XCTAssertFalse(output.contains("do-not-log"))
        XCTAssertFalse(output.contains(job.left.host))
        XCTAssertFalse(output.contains(job.left.username))
        XCTAssertFalse(output.contains(job.left.remotePath))
    }

    func testEngineLogsFailureCategoryWithoutRawPublicationError() async {
        let file = SyncFile(relativePath: "SECRET.JPG", size: 4, modifiedAt: Date())
        let source = SyncLoggingSession(files: [file.relativePath: file])
        let sensitiveError = "Upload failed for ftp://reporter:password@private.example/SECRET.JPG"
        let destination = SyncLoggingSession(importError: sensitiveError)
        let logger = LockedSyncEventLogger()
        let job = loggingJob()
        let engine = SyncEngine(eventLogger: logger) { endpoint, _, _ in
            endpoint.kind.isRemote ? source : destination
        }

        do {
            _ = try await engine.run(job: job, leftPassword: "password", rightPassword: nil)
            XCTFail("The injected publication failure should be reported.")
        } catch {
            // Expected.
        }

        let events = logger.events
        XCTAssertTrue(events.contains {
            $0.stage == .publication && $0.outcome == .failed && $0.failureCategory == .transfer
        })
        XCTAssertTrue(events.contains {
            $0.stage == .run && $0.outcome == .failed && $0.failureCategory == .transfer
        })
        XCTAssertFalse(events.map(\.formattedMessage).joined().contains(sensitiveError))
    }

    func testEngineLogsProtocolReadFailureWithoutRawError() async {
        let file = SyncFile(relativePath: "SECRET.JPG", size: 4, modifiedAt: Date())
        let sensitiveError = "Download failed for ftp://reporter:password@private.example/SECRET.JPG"
        let source = SyncLoggingSession(
            files: [file.relativePath: file],
            exportError: sensitiveError
        )
        let destination = SyncLoggingSession()
        let logger = LockedSyncEventLogger()
        let job = loggingJob()
        let engine = SyncEngine(eventLogger: logger) { endpoint, _, _ in
            endpoint.kind.isRemote ? source : destination
        }

        do {
            _ = try await engine.run(job: job, leftPassword: "password", rightPassword: nil)
            XCTFail("The injected protocol failure should be reported.")
        } catch {
            // Expected.
        }

        let events = logger.events
        XCTAssertTrue(events.contains {
            $0.stage == .protocolOperation && $0.operation == .sourceRead
                && $0.outcome == .failed && $0.failureCategory == .transfer
        })
        XCTAssertFalse(events.map(\.formattedMessage).joined().contains(sensitiveError))
    }

    private func loggingJob() -> SyncJob {
        var job = SyncJob()
        job.left = Endpoint(
            kind: .ftp,
            host: "private.example",
            username: "reporter",
            remotePath: "/embargoed"
        )
        job.right = Endpoint(
            kind: .local,
            localPath: "/private/downloads",
            bookmark: Data("mock-bookmark".utf8)
        )
        job.direction = .leftToRight
        job.filter = FileFilter(preset: .photos)
        job.isEnabled = false
        job.startsOnAppLaunch = false
        return job
    }
}

private final class LockedSyncEventLogger: SyncEventLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [SyncLogEvent] = []

    var events: [SyncLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: SyncLogEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }
}

private actor SyncLoggingSession: EndpointSession {
    private let files: [String: SyncFile]
    private let importError: String?
    private let exportError: String?

    init(
        files: [String: SyncFile] = [:],
        importError: String? = nil,
        exportError: String? = nil
    ) {
        self.files = files
        self.importError = importError
        self.exportError = exportError
    }

    func listFiles() async throws -> [String: SyncFile] { files }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        if let exportError { throw AppError.transferFailed(exportError) }
        try Data(repeating: 7, count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        if let importError { throw AppError.transferFailed(importError) }
    }
}
