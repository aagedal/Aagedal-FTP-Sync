import Foundation

public enum MetadataTemplateActivationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case keywordEntryLimitExceeded(maxEntries: Int)
}

/// An atomic text/source activation pair. Construct a replacement before assigning it to a record;
/// an invalid edit throws without changing the previous value. This codec is a core value envelope,
/// not the app's calendar or configuration wire format.
public struct MetadataTemplateText: Equatable, Sendable, Codable {
    public let source: String
    public let templateVersion: Int?
    private let template: MetadataTemplate?

    public var requiredVariables: Set<MetadataTemplateVariable> {
        template?.requiredVariables ?? []
    }

    /// Legacy text bypasses parsing, including malformed braces and escape-looking text.
    public static func literal(_ source: String) -> Self {
        Self(source: source, templateVersion: nil, template: nil)
    }

    public static func activated(_ source: String) throws -> Self {
        try Self(source: source, templateVersion: MetadataTemplate.languageVersion)
    }

    public init(source: String, templateVersion: Int?) throws {
        try validateTemplateVersion(templateVersion)
        self.source = source
        self.templateVersion = templateVersion
        self.template = try templateVersion.map { _ in try MetadataTemplate.parse(source) }
    }

    private init(source: String, templateVersion: Int?, template: MetadataTemplate?) {
        self.source = source
        self.templateVersion = templateVersion
        self.template = template
    }

    public func resolve(using context: MetadataTemplateContext) -> MetadataTemplateOutcome<String> {
        template?.resolve(using: context) ?? .resolved(source)
    }

    public init(from decoder: any Decoder) throws {
        let value = try TemplateValueEnvelope<String>(from: decoder)
        try self.init(source: value.source, templateVersion: value.templateVersion)
    }

    public func encode(to encoder: any Encoder) throws {
        try TemplateValueEnvelope(source: source, templateVersion: templateVersion).encode(to: encoder)
    }
}

/// The complete ordered Keywords array and activation are one value. Literal arrays retain their
/// original entries; activated arrays resolve and normalize together, or preserve the existing list.
public struct MetadataTemplateKeywords: Equatable, Sendable, Codable {
    public let source: [String]
    public let templateVersion: Int?
    private let templates: [MetadataTemplate]?

    public var requiredVariables: Set<MetadataTemplateVariable> {
        templates?.reduce(into: Set<MetadataTemplateVariable>()) { $0.formUnion($1.requiredVariables) } ?? []
    }

    public static func literal(_ source: [String]) -> Self {
        Self(source: source, templateVersion: nil, templates: nil)
    }

    public static func activated(_ source: [String]) throws -> Self {
        try Self(source: source, templateVersion: MetadataTemplate.languageVersion)
    }

    public init(source: [String], templateVersion: Int?) throws {
        try validateTemplateVersion(templateVersion)
        if templateVersion != nil, source.count > MetadataTemplate.maximumKeywordEntries {
            throw MetadataTemplateActivationError.keywordEntryLimitExceeded(maxEntries: MetadataTemplate.maximumKeywordEntries)
        }
        self.source = source
        self.templateVersion = templateVersion
        self.templates = try templateVersion.map { _ in try source.map(MetadataTemplate.parse) }
    }

    private init(source: [String], templateVersion: Int?, templates: [MetadataTemplate]?) {
        self.source = source
        self.templateVersion = templateVersion
        self.templates = templates
    }

    public func resolve(using context: MetadataTemplateContext) -> MetadataTemplateOutcome<[String]> {
        guard let templates else { return .resolved(source) }
        return MetadataTemplate.resolveKeywords(templates, using: context)
    }

    public init(from decoder: any Decoder) throws {
        let value = try TemplateValueEnvelope<[String]>(from: decoder)
        try self.init(source: value.source, templateVersion: value.templateVersion)
    }

    public func encode(to encoder: any Encoder) throws {
        try TemplateValueEnvelope(source: source, templateVersion: templateVersion).encode(to: encoder)
    }
}

private func validateTemplateVersion(_ version: Int?) throws {
    if let version, version != MetadataTemplate.languageVersion {
        throw MetadataTemplateActivationError.unsupportedVersion(version)
    }
}

/// Decoding a missing version is distinct from decoding an explicit null. Reject unknown keys so
/// a misspelled activation marker cannot silently turn this envelope into literal text.
private struct TemplateValueEnvelope<Source: Codable>: Codable {
    let source: Source
    let templateVersion: Int?

    init(source: Source, templateVersion: Int?) {
        self.source = source
        self.templateVersion = templateVersion
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static var source: Self { Self(stringValue: "source") }
        static var version: Self { Self(stringValue: "templateVersion") }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys where key.stringValue != Key.source.stringValue && key.stringValue != Key.version.stringValue {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Unknown template value key.")
        }
        source = try container.decode(Source.self, forKey: .source)
        // `decode`, rather than `decodeIfPresent`, rejects null and non-integer marker values.
        templateVersion = container.contains(.version) ? try container.decode(Int.self, forKey: .version) : nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(templateVersion, forKey: .version)
    }
}
