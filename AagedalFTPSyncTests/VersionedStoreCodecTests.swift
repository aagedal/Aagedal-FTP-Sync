import Foundation
import XCTest
@testable import AagedalFTPSync

final class VersionedStoreCodecTests: XCTestCase {
    private struct Value: Codable, Equatable {
        let text: String
        let date: Date
    }

    func testVersionedPayloadPreservesConfiguredDatesAndLiteralTemplates() throws {
        let codec = VersionedStoreCodec(format: .version3, store: .jobs)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = Value(text: "{gps:city} malformed {photographer", date: Date(timeIntervalSince1970: 1234.5))
        let data = try codec.encode(value, encoder: encoder)
        XCTAssertEqual(try codec.decode(Value.self, from: data, decoder: decoder), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "AagedalFTPSync.store")
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        XCTAssertEqual(object["store"] as? String, "jobs")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["date"] as? Double, 1_234_500)
        XCTAssertEqual(payload["text"] as? String, value.text)
    }

    func testLegacyCodecIsByteIdenticalToConfiguredEncoder() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = Value(text: "{{literal}} / {unknown}", date: Date(timeIntervalSince1970: 1_700_000_000))
        let codec = VersionedStoreCodec(format: .legacy, store: .jobs)
        let bytes = try codec.encode(value, encoder: encoder)
        XCTAssertEqual(bytes, try encoder.encode(value))
        XCTAssertEqual(try codec.decode(Value.self, from: bytes, decoder: decoder), value)
    }

    func testInvalidHeaderIsRejectedBeforePayloadDecodingAndCannotRecover() throws {
        enum PayloadVisited: Error { case visited }
        struct Trap: Decodable {
            init(from decoder: Decoder) throws { throw PayloadVisited.visited }
        }
        let codec = VersionedStoreCodec(format: .version3, store: .jobs)
        let headers = [
            "[]", "{}", "null", "{",
            #"{"format":"other","schemaVersion":3,"store":"jobs","payload":{}}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":4,"store":"jobs","payload":{}}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":2,"store":"jobs","payload":{}}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":null,"store":"jobs","payload":{}}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":true,"store":"jobs","payload":{}}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":"3","store":"jobs","payload":{}}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":3,"store":"serverProfiles","payload":{}}"#,
            #"{"format":"AagedalFTPSync.store","schemaVersion":3,"store":"jobs","future":1,"payload":{}}"#
        ]
        for json in headers {
            XCTAssertThrowsError(try codec.decode(Trap.self, from: Data(json.utf8), decoder: JSONDecoder())) { error in
                XCTAssertTrue(error is VersionedStoreCodec.HeaderError, json)
                XCTAssertFalse(VersionedStoreCodec.permitsBackupRecovery(after: error))
            }
        }
    }

    func testSupportedHeaderWithDamagedPayloadRemainsRecoverable() throws {
        let codec = VersionedStoreCodec(format: .version3, store: .jobs)
        for payload in ["null", "{}", "42"] {
            let json = "{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":3,\"store\":\"jobs\",\"payload\":\(payload)}"
            XCTAssertThrowsError(try codec.decode([String].self, from: Data(json.utf8), decoder: JSONDecoder())) { error in
                XCTAssertTrue(error is DecodingError)
                XCTAssertTrue(VersionedStoreCodec.permitsBackupRecovery(after: error))
            }
        }
    }
}
