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
        case requiresVersion3Storage
        case missingStore
        case invalidEnvelope
        case wrongFormat
        case unsupportedVersion(Int)
        case wrongStore(String)
    }

    let format: AppStorageFormat
    let store: Store

    private var carriesTemplateRecords: Bool {
        switch store {
        case .jobs, .metadataPresets, .photographers, .metadataCalendar: true
        default: false
        }
    }

    func encode<Value: Encodable>(_ value: Value, encoder: JSONEncoder) throws -> Data {
        switch format {
        case .legacy:
            let data = try encoder.encode(value)
            if carriesTemplateRecords { try Self.rejectLegacyTemplateMarkers(in: data) }
            return data
        case .version3: return try encoder.encode(Envelope(store: store.rawValue, payload: value))
        }
    }

    func decode<Value: Decodable>(_ type: Value.Type, from data: Data, decoder: JSONDecoder) throws -> Value {
        switch format {
        case .legacy:
            if carriesTemplateRecords { try Self.rejectLegacyTemplateMarkers(in: data) }
            return try decoder.decode(type, from: data)
        case .version3:
            try validateHeader(data)
            do { return try decoder.decode(Payload<Value>.self, from: data).payload }
            catch let error as MetadataTemplateRecordError { throw error }
            catch let error as MetadataGeocodingSettingsError { throw error }
            catch {
                // An earlier malformed sibling must not hide activation or a
                // persisted job processing zone and recover older configuration.
                if carriesTemplateRecords, (try? hasRecoverySensitiveRecords(in: data)) == true {
                    throw MetadataTemplateRecordError.invalidSource
                }
                throw error
            }
        }
    }

    /// Called before any save mutation. Payload damage in an identified supported
    /// envelope may be repaired; an unidentified or incompatible store is retained.
    func validateExistingStore(at url: URL, required: Bool = true) throws {
        guard format == .version3 else {
            if carriesTemplateRecords, let data = try? Data(contentsOf: url) {
                do { try Self.rejectLegacyTemplateMarkers(in: data) }
                catch let error as HeaderError { throw error }
                catch { /* Preserve existing legacy handling of malformed JSON. */ }
            }
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if required { throw HeaderError.missingStore }
            return
        }
        let bytes = try Data(contentsOf: url)
        try validateHeader(bytes)
        // Saves must not swallow a future/invalid active record through their
        // best-effort backup decode and replace it with cached older state.
        do {
            let decoder = JSONDecoder()
            switch store {
            case .jobs:
                decoder.dateDecodingStrategy = .iso8601
                _ = try decode([SyncJob].self, from: bytes, decoder: decoder)
            case .metadataPresets:
                decoder.dateDecodingStrategy = .iso8601
                _ = try decode([MetadataPreset].self, from: bytes, decoder: decoder)
            case .photographers:
                _ = try decode([PhotographerProfile].self, from: bytes, decoder: decoder)
            case .metadataCalendar:
                decoder.dateDecodingStrategy = .millisecondsSince1970
                _ = try decode(MetadataCalendarState.self, from: bytes, decoder: decoder)
            default: break
            }
        } catch let error as MetadataTemplateRecordError { throw error }
        catch let error as MetadataGeocodingSettingsError { throw error }
        catch { /* Other supported payload damage retains its existing recovery policy. */ }
    }

    static func permitsBackupRecovery(after error: Error) -> Bool {
        !(error is HeaderError) && !(error is MetadataTemplateRecordError) && !(error is MetadataGeocodingSettingsError)
    }

    /// Match Foundation Codable's key selection, including duplicate JSON keys.
    /// Marker presence in old storage is never a supported literal representation.
    static func rejectLegacyTemplateMarkers(in data: Data) throws {
        _ = try JSONDecoder().decode(LegacyTemplateProbe.self, from: data)
    }

    private static func hasTemplateMarkers(in data: Data) throws -> Bool {
        do { try rejectLegacyTemplateMarkers(in: data); return false }
        catch HeaderError.requiresVersion3Storage { return true }
    }

    private func hasRecoverySensitiveRecords(in data: Data) throws -> Bool {
        if try Self.hasTemplateMarkers(in: data) { return true }
        guard store == .jobs else { return false }
        do {
            _ = try JSONDecoder().decode(ProcessingZoneProbe.self, from: data)
            return false
        } catch is MetadataTemplateRecordError { return true }
    }

    /// A valid zone is allowed in literal legacy storage. Only the v3 jobs
    /// recovery check uses this probe, including when an earlier record failed.
    private struct ProcessingZoneProbe: Decodable {
        init(from decoder: Decoder) throws {
            if let object = try? decoder.container(keyedBy: Key.self) {
                for key in object.allKeys {
                    if key.stringValue == "metadataProcessingTimeZoneIdentifier" {
                        throw MetadataTemplateRecordError.invalidSource
                    }
                    _ = try object.decode(Self.self, forKey: key)
                }
            } else if var array = try? decoder.unkeyedContainer() {
                while !array.isAtEnd { _ = try array.decode(Self.self) }
            }
        }
    }

    private struct LegacyTemplateProbe: Decodable {
        init(from decoder: Decoder) throws {
            if let object = try? decoder.container(keyedBy: Key.self) {
                for key in object.allKeys {
                    if key.stringValue == "templateVersions" || key.stringValue == "copyrightTemplateVersion"
                        || key.stringValue == "metadataGeocoding" {
                        throw HeaderError.requiresVersion3Storage
                    }
                    _ = try object.decode(Self.self, forKey: key)
                }
            } else if var array = try? decoder.unkeyedContainer() {
                while !array.isAtEnd { _ = try array.decode(Self.self) }
            }
        }
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
