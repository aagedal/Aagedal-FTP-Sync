import Foundation
import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataCalendarProtocol3ClientTests: XCTestCase {
    private struct Reply: Sendable {
        let data: Data
        let status: Int
    }
    private enum FixtureError: Error { case unexpectedRequest }
    private actor Transport {
        var requests: [URLRequest] = []
        var replies: [Reply]
        init(_ replies: [Reply]) { self.replies = replies }
        func send(_ request: URLRequest) throws -> (Data, Int) {
            requests.append(request)
            guard !replies.isEmpty else { throw FixtureError.unexpectedRequest }
            let reply = replies.removeFirst()
            return (reply.data, reply.status)
        }
        func captured() -> [URLRequest] { requests }
    }

    private let deviceID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let calendarID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let key = String(repeating: "a", count: 64)

    private func document(active: Bool = true) throws -> SharedMetadataDocument {
        var profile = PhotographerProfile(name: "Fixture", filenamePrefix: "CN", creator: "Fixture", copyrightNotice: "Literal {date:YYYY}")
        if active { profile.setCopyright(try .activated("Copyright {date:YYYY-MM-DD}")) }
        return SharedMetadataDocument(.init(photographers: [profile], photographerTracks: [], clips: []))
    }

    private func bytes(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func capabilityEnvelope() -> [String: Any] {
        ["service": "aagedal-metadata-sync", "protocolVersion": 3,
         "capabilities": ["metadata-templates-v1"], "documentSchemaVersions": [1, 3], "templateLanguageVersions": [1]]
    }

    private func calendarReply(status: Int = 200, active: Bool = true) throws -> Reply {
        let snapshot = SharedMetadataCalendar(id: calendarID, name: "Fixture", timeZone: "Etc/UTC", revision: 2,
            role: "editor", document: try document(active: active), compatibility: .templates)
        var envelope = capabilityEnvelope()
        envelope["calendar"] = try JSONSerialization.jsonObject(with: MetadataCalendarClient.encoder().encode(snapshot))
        if status == 409 { envelope["error"] = "revision_conflict" }
        return .init(data: try bytes(envelope), status: status)
    }

    private func request() throws -> MetadataCalendarRequest {
        var request = MetadataCalendarRequest(action: "putCalendar", calendarID: calendarID,
            document: try document(), expectedRevision: 1)
        request.documentSchemaVersion = 3
        return request
    }

    private func actions(_ requests: [URLRequest]) throws -> [String] {
        try requests.map {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any])
            return try XCTUnwrap(value["action"] as? String)
        }
    }

    func testEveryDocumentSendRequiresFreshAuthenticatedProbeOnSameEndpoint() async throws {
        let capability = Reply(data: try bytes(capabilityEnvelope()), status: 200)
        let transport = Transport([capability, try calendarReply(), capability, try calendarReply()])
        let client = MetadataCalendarClient(transport: { try await transport.send($0) })
        for _ in 0..<2 {
            _ = try await client.send(request(), address: "https://calendar.example.test/sync/", deviceID: deviceID,
                key: key, protocolVersion: .templates)
        }
        let captured = await transport.captured()
        XCTAssertEqual(try actions(captured), ["getCapabilities", "putCalendar", "getCapabilities", "putCalendar"])
        XCTAssertEqual(Set(captured.compactMap(\.url)).count, 1)
        for request in captured {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Aagedal-Protocol"), "3")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Aagedal-Device-ID"), deviceID.uuidString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Aagedal-Device-Key"), key)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            if body["action"] as? String == "getCapabilities" {
                XCTAssertNil(body["document"])
            } else {
                XCTAssertEqual(body["documentSchemaVersion"] as? Int, 3)
                XCTAssertEqual(body["capabilities"] as? [String], ["metadata-templates-v1"])
            }
        }
    }

    func testIncompatibleCapabilityProbeNeverSendsDocumentOrFallsBack() async throws {
        for invalidField in ["capabilities", "documentSchemaVersions", "templateLanguageVersions"] {
            var incompatible = capabilityEnvelope()
            incompatible[invalidField] = []
            let transport = Transport([.init(data: try bytes(incompatible), status: 200)])
            let client = MetadataCalendarClient(transport: { try await transport.send($0) })
            do {
                _ = try await client.send(request(), address: "https://calendar.example.test/", deviceID: deviceID,
                    key: key, protocolVersion: .templates)
                XCTFail("Unsupported peer must stop before receiving a document")
            } catch { XCTAssertEqual(error as? MetadataSyncServerError, .unsupportedProtocol) }
            let captured = await transport.captured()
            XCTAssertEqual(try actions(captured), ["getCapabilities"])
            XCTAssertFalse(String(decoding: try XCTUnwrap(captured.first?.httpBody), as: UTF8.self).contains("Copyright"))
        }
    }

    func testMissingRequestSchemaFailsBeforeTransport() async throws {
        let transport = Transport([])
        let client = MetadataCalendarClient(transport: { try await transport.send($0) })
        let missing = MetadataCalendarRequest(action: "putCalendar", calendarID: calendarID,
            document: try document(), expectedRevision: 1)
        do {
            _ = try await client.send(missing, address: "https://calendar.example.test/", deviceID: deviceID,
                key: key, protocolVersion: .templates)
            XCTFail("Active documents require an explicit schema")
        } catch { XCTAssertEqual(error as? MetadataSyncServerError, .unsupportedProtocol) }
        let captured = await transport.captured()
        XCTAssertTrue(captured.isEmpty)
    }

    func testBadEnvelopeIsRejectedBeforeMalformedCalendarDecode() throws {
        for version in [2, 99] {
            var envelope = capabilityEnvelope()
            envelope["protocolVersion"] = version
            envelope["calendar"] = ["document": "malformed sensitive fixture"]
            XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(bytes(envelope), statusCode: 200,
                calendarID: calendarID, protocolVersion: .templates)) { error in
                XCTAssertFalse(error is DecodingError)
                XCTAssertFalse(error.localizedDescription.contains("sensitive fixture"))
            }
        }
        var missingCapability = capabilityEnvelope()
        missingCapability["capabilities"] = []
        missingCapability["calendar"] = ["document": "malformed"]
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(bytes(missingCapability), statusCode: 200,
            calendarID: calendarID, protocolVersion: .templates)) { XCTAssertFalse($0 is DecodingError) }
    }

    func testValidProtocol3RevisionConflictRetainsActiveSourcePair() throws {
        let reply = try calendarReply(status: 409)
        let result = try MetadataCalendarClient.decodeResponse(reply.data, statusCode: reply.status,
            calendarID: calendarID, protocolVersion: .templates)
        XCTAssertEqual(result.error, "revision_conflict")
        XCTAssertEqual(result.calendar?.revision, 2)
        XCTAssertEqual(result.calendar?.document.photographers.first?.copyrightTemplateVersion, 1)
        XCTAssertEqual(result.calendar?.document.photographers.first?.copyrightNotice, "Copyright {date:YYYY-MM-DD}")
    }

    func testUpgradeRequiredDoesNotExposeArbitraryServerDetail() throws {
        var envelope = capabilityEnvelope()
        envelope["error"] = "client_upgrade_required"
        envelope["detail"] = "server-private-token-DO-NOT-DISPLAY"
        envelope["calendar"] = ["document": "malformed"]
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(bytes(envelope), statusCode: 426,
            calendarID: calendarID, protocolVersion: .templates)) { error in
                XCTAssertFalse(error is DecodingError)
                XCTAssertFalse(error.localizedDescription.contains("server-private-token"))
        }
    }

    func testLegacyRequestKeepsProtocol2AndHasNoCapabilityProbe() async throws {
        let response = try bytes(["service": "aagedal-metadata-sync", "protocolVersion": 2, "calendars": []])
        let transport = Transport([.init(data: response, status: 200)])
        let client = MetadataCalendarClient(transport: { try await transport.send($0) })
        _ = try await client.send(.init(action: "listCalendars"), address: "https://calendar.example.test/",
            deviceID: deviceID, key: key)
        let captured = await transport.captured()
        XCTAssertEqual(try actions(captured), ["listCalendars"])
        XCTAssertEqual(captured.first?.value(forHTTPHeaderField: "X-Aagedal-Protocol"), "2")
    }
}

// Regression coverage for the sync evaluation findings.
extension MetadataCalendarProtocol3ClientTests {
    func testActivatedCalendarConflictReviewCanBuildPlan() throws {
        let base = try document()
        var local = base
        var remoteDocument = base
        local.photographers[0].name = "Local edit"
        remoteDocument.photographers[0].name = "Remote edit"
        let snapshot = SharedMetadataCalendar(id: calendarID, name: "Audit", timeZone: "Etc/UTC", revision: 1,
            role: "owner", document: base, compatibility: .templates)
        var remote = snapshot
        remote.revision = 2
        remote.document = remoteDocument
        let binding = MetadataCalendarBinding(accountID: deviceID, jobID: UUID(), snapshot: snapshot, conflict: remote)
        let review = MetadataCalendarConflictReview(binding: binding, local: local, remote: remote)
        XCTAssertEqual(try MetadataCalendarMerge.plan(base: base, local: local, remote: remoteDocument).conflicts.count, 1)
        XCTAssertNoThrow(try review.plan())
    }

    func testProtocol3MissingConfigurationRemainsActionable() throws {
        let body = try bytes(["service": "aagedal-metadata-sync", "protocolVersion": 3,
                              "stage": "calendar-sync", "checks": [], "error": "not_configured"])
        XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(body, statusCode: 503,
            calendarID: nil, protocolVersion: .templates)) { error in
            XCTAssertTrue(error.localizedDescription.contains("config.php"), error.localizedDescription)
        }
    }
}

extension MetadataCalendarProtocol3ClientTests {
    func testAllInstallationErrorsRemainActionableInBothNamespaces() throws {
        for protocolVersion in [MetadataCalendarProtocol.legacy, .templates] {
            for version in [1, 2, 3] {
                for (code, detail) in [("not_configured", "config.php"), ("runtime_unavailable", "PHP 8.2"),
                    ("invalid_configuration", "database settings"), ("live_api_missing", "Upload live.php"),
                    ("template_api_missing", "Upload templates.php")] {
                    let body = try bytes(["service": "aagedal-metadata-sync", "protocolVersion": version, "error": code])
                    XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(body, statusCode: 503,
                        calendarID: nil, protocolVersion: protocolVersion)) { error in
                        XCTAssertTrue(error.localizedDescription.contains(detail), error.localizedDescription)
                        XCTAssertEqual((error as? MetadataSyncFailure)?.isRetryable, true)
                    }
                }
            }
        }
    }

    func testInstallationErrorCannotBypassCalendarCapabilityGate() throws {
        for status in [200, 503] {
            let body = try bytes(["service": "aagedal-metadata-sync", "protocolVersion": 3,
                "error": "not_configured", "calendar": ["malformed": true]])
            XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(body, statusCode: status,
                calendarID: calendarID, protocolVersion: .templates)) { error in
                if status == 200 { XCTAssertEqual(error as? MetadataSyncServerError, .unsupportedProtocol) }
                else {
                    XCTAssertEqual((error as? MetadataSyncFailure)?.httpStatus, 503)
                    XCTAssertFalse(error.localizedDescription.contains("config.php"))
                }
            }
        }
    }

    func testServiceErrorsPreserveRetryInformationWithoutLeakingBodies() throws {
        for status in [429, 500, 502, 503, 504] {
            for body in [Data("<html>private proxy details</html>".utf8),
                         try bytes(["service": "aagedal-metadata-sync", "protocolVersion": 3,
                                    "capabilities": ["metadata-templates-v1"], "error": "sync_unavailable"])] {
                XCTAssertThrowsError(try MetadataCalendarClient.decodeResponse(body, statusCode: status,
                    calendarID: nil, protocolVersion: .templates, retryAfter: 90)) { error in
                    let failure = error as? MetadataSyncFailure
                    XCTAssertEqual(failure?.httpStatus, status)
                    XCTAssertEqual(failure?.retryAfter, 90)
                    XCTAssertEqual(failure?.isRetryable, true)
                    XCTAssertFalse(error.localizedDescription.contains("private proxy details"))
                }
            }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(MetadataCalendarClient.retryDelay("90", now: now), 90)
        XCTAssertEqual(MetadataCalendarClient.retryDelay("Fri, 15 Jan 2027 08:01:30 GMT", now: now), 90)
        for value in ["-1", "nan", "infinity", "junk"] {
            XCTAssertNil(MetadataCalendarClient.retryDelay(value, now: now))
        }
        XCTAssertEqual(MetadataCalendarClient.retryDelay("Wed, 01 Jan 2020 00:00:00 GMT", now: now), 0)
        XCTAssertFalse(MetadataSyncFailure(message: "Validation", httpStatus: 422).isRetryable)
        XCTAssertFalse(MetadataSyncFailure(message: "Unauthorized", httpStatus: 401).isRetryable)
    }
}
