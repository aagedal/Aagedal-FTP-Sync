import Foundation

/// Opt-in local persistence envelope. Interchange/calendar wire formats are separate.
/// Header rejection must escape repository backup recovery and save replacement.
struct VersionedStoreCodec: Sendable {
    enum Store: String, Codable, Sendable {
        case jobs, metadataPresets, photographers, serverProfiles
        case metadataAudit, syncFailures, downloadManifest
        case metadataCalendar, metadataSyncEvents
        case downloadNames, downloadReplacementNames
        case downloadNameRegistry
    }

    enum HeaderError: Error, Equatable {
        case missingStore
        case invalidEnvelope
        case wrongFormat
        case unsupportedVersion(Int)
        case wrongStore(String)
    }

    let format: AppStorageFormat
    let store: Store

    func encode<Value: Encodable>(_ value: Value, encoder: JSONEncoder) throws -> Data {
        switch format {
        case .legacy: return try encoder.encode(value)
        case .version3: return try encoder.encode(Envelope(store: store.rawValue, payload: value))
        }
    }

    func decode<Value: Decodable>(_ type: Value.Type, from data: Data, decoder: JSONDecoder) throws -> Value {
        switch format {
        case .legacy: return try decoder.decode(type, from: data)
        case .version3:
            try validateHeader(data)
            return try decoder.decode(Payload<Value>.self, from: data).payload
        }
    }

    /// Called before any save mutation. Payload damage in an identified supported
    /// envelope may be repaired; an unidentified or incompatible store is retained.
    func validateExistingStore(at url: URL, required: Bool = true) throws {
        guard format == .version3 else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if required { throw HeaderError.missingStore }
            return
        }
        try validateHeader(Data(contentsOf: url))
    }

    static func permitsBackupRecovery(after error: Error) -> Bool {
        !(error is HeaderError)
    }

    private func validateHeader(_ data: Data) throws {
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch { throw HeaderError.invalidEnvelope }
        guard header.format == "AagedalFTPSync.store" else { throw HeaderError.wrongFormat }
        guard header.schemaVersion == 3 else { throw HeaderError.unsupportedVersion(header.schemaVersion) }
        guard header.store == store.rawValue else { throw HeaderError.wrongStore(header.store) }
    }

    private struct Header: Decodable {
        let format: String
        let schemaVersion: Int
        let store: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard Set(container.allKeys.map(\.stringValue)).isSubset(of: ["format", "schemaVersion", "store", "payload"]) else {
                throw HeaderError.invalidEnvelope
            }
            format = try container.decode(String.self, forKey: Key("format"))
            schemaVersion = try container.decode(Int.self, forKey: Key("schemaVersion"))
            store = try container.decode(String.self, forKey: Key("store"))
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    private struct Envelope<Value: Encodable>: Encodable {
        let format = "AagedalFTPSync.store"
        let schemaVersion = 3
        let store: String
        let payload: Value
    }

    private struct Payload<Value: Decodable>: Decodable {
        let payload: Value
    }
}
