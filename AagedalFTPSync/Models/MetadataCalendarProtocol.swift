import Foundation

/// The namespace is selected explicitly; removing templates never downgrades it.
enum MetadataCalendarProtocol: Int, Codable, Hashable, Sendable {
    case legacy = 2
    case templates = 3
}

struct MetadataCalendarCompatibility: Equatable, Hashable, Sendable {
    static let templateCapability = "metadata-templates-v1"
    static let legacy = Self(protocolVersion: .legacy)
    static let templates = Self(protocolVersion: .templates)

    let protocolVersion: MetadataCalendarProtocol
    private init(protocolVersion: MetadataCalendarProtocol) { self.protocolVersion = protocolVersion }
    var documentSchemaVersion: Int { protocolVersion == .legacy ? 1 : 3 }
    var minimumClientProtocol: Int { protocolVersion.rawValue }
    var requiredCapabilities: [String] { protocolVersion == .legacy ? [] : [Self.templateCapability] }

    private enum CodingKeys: String, CodingKey {
        case documentSchemaVersion, minimumClientProtocol, requiredCapabilities
    }

    /// Reads flattened snapshot headers before any document/domain decoding.
    static func decodeHeaders(from decoder: Decoder) throws -> Self {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let presence = [values.contains(.documentSchemaVersion), values.contains(.minimumClientProtocol), values.contains(.requiredCapabilities)]
            if presence.allSatisfy({ !$0 }) { return .legacy }
            guard presence.allSatisfy({ $0 }),
                  try values.decode(Int.self, forKey: .documentSchemaVersion) == 3,
                  try values.decode(Int.self, forKey: .minimumClientProtocol) == 3,
                  try values.decode([String].self, forKey: .requiredCapabilities) == [templateCapability] else {
                throw MetadataTemplateRecordError.invalidSource
            }
            return .templates
        } catch { throw MetadataTemplateRecordError.invalidSource }
    }

    func encodeHeaders(to encoder: Encoder) throws {
        guard self == .templates else { return }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(documentSchemaVersion, forKey: .documentSchemaVersion)
        try values.encode(minimumClientProtocol, forKey: .minimumClientProtocol)
        try values.encode(requiredCapabilities, forKey: .requiredCapabilities)
    }
}

/// An explicit retained-field transition, separate from normal record deletion.
struct MetadataTemplateDeactivation: Codable, Hashable, Sendable {
    enum RecordKind: String, Codable, Sendable { case clip, photographer }
    enum Field: String, Codable, Sendable { case headline, description, keywords, copyrightNotice }
    let recordKind: RecordKind
    let recordID: UUID
    let field: Field
    let previousVersion: Int

    init(recordKind: RecordKind, recordID: UUID, field: Field, previousVersion: Int = 1) throws {
        guard previousVersion == 1,
              (recordKind == .photographer ? field == .copyrightNotice : field != .copyrightNotice) else {
            throw MetadataTemplateRecordError.invalidSource
        }
        self.recordKind = recordKind; self.recordID = recordID
        self.field = field; self.previousVersion = previousVersion
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: Key.self)
            guard Set(values.allKeys.map(\.stringValue)) == ["recordKind", "recordID", "field", "previousVersion"] else {
                throw MetadataTemplateRecordError.invalidSource
            }
            try self.init(recordKind: values.decode(RecordKind.self, forKey: Key("recordKind")),
                recordID: values.decode(UUID.self, forKey: Key("recordID")),
                field: values.decode(Field.self, forKey: Key("field")),
                previousVersion: values.decode(Int.self, forKey: Key("previousVersion")))
        } catch { throw MetadataTemplateRecordError.invalidSource }
    }

    static func required(from previous: SharedMetadataDocument, to proposed: SharedMetadataDocument) throws -> [Self] {
        // Validate pairs without normalizing source strings or the document.
        for document in [previous, proposed] {
            guard Set(document.clips.map(\.id)).count == document.clips.count,
                  Set(document.photographers.map(\.id)).count == document.photographers.count else {
                throw MetadataTemplateRecordError.invalidSource
            }
            for clip in document.clips {
                _ = try clip.fields.validatedHeadline
                _ = try clip.fields.validatedDescription
                _ = try clip.fields.validatedKeywords
            }
            for profile in document.photographers { _ = try profile.validatedCopyright }
        }
        let clips = Dictionary(uniqueKeysWithValues: proposed.clips.map { ($0.id, $0) })
        let photographers = Dictionary(uniqueKeysWithValues: proposed.photographers.map { ($0.id, $0) })
        var result: [Self] = []
        for old in previous.clips {
            guard let new = clips[old.id] else { continue }
            for field in [Field.headline, .description, .keywords] {
                if let version = old.fields.templateVersions[field.rawValue], new.fields.templateVersions[field.rawValue] == nil {
                    result.append(try Self(recordKind: .clip, recordID: old.id, field: field, previousVersion: version))
                }
            }
        }
        for old in previous.photographers {
            if let new = photographers[old.id], let version = old.copyrightTemplateVersion, new.copyrightTemplateVersion == nil {
                result.append(try Self(recordKind: .photographer, recordID: old.id, field: .copyrightNotice, previousVersion: version))
            }
        }
        return result.sorted {
            [$0.recordKind.rawValue, $0.recordID.uuidString, $0.field.rawValue].lexicographicallyPrecedes(
                [$1.recordKind.rawValue, $1.recordID.uuidString, $1.field.rawValue])
        }
    }

    static func validate(_ declarations: [Self], from previous: SharedMetadataDocument, to proposed: SharedMetadataDocument) throws {
        let expected = try required(from: previous, to: proposed)
        guard Set(declarations).count == declarations.count, Set(declarations) == Set(expected) else {
            throw MetadataSyncFailure(message: "A template activation changed without an exact explicit conversion declaration.", diagnosticCode: "template_activation_lost")
        }
    }
}
