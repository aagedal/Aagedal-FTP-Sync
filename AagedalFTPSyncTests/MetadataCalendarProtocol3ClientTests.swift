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
