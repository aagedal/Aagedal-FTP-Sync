import Foundation

enum MetadataFaceRecognitionSettingsError: LocalizedError, Equatable {
    case invalidSettings
    case requiresOneWayJob
    case requiresLocalDestination

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            "The saved face-recognition settings are malformed or unsupported. Choose supported face-recognition choices in version 3."
        case .requiresOneWayJob:
            "Face recognition is only available for one-way jobs."
        case .requiresLocalDestination:
            "Face recognition requires a local destination folder."
        }
    }
}

/// Job-local publication choice. Absence on a job means off. The selected
/// people library, installed model and calibrated acceptance policy are runtime
/// dependencies and are deliberately not copied into job configuration.
struct MetadataFaceRecognitionSettings: Codable, Hashable, Sendable {
    static let schemaVersion = 1

    var appendToKeywords: Bool

    init(appendToKeywords: Bool = false) {
        self.appendToKeywords = appendToKeywords
    }

    func validate() throws {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, appendToKeywords
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        do {
            let keys = try decoder.container(keyedBy: Key.self)
            let expected = Set(CodingKeys.allCases.map(\.rawValue))
            guard Set(keys.allKeys.map(\.stringValue)) == expected else {
                throw MetadataFaceRecognitionSettingsError.invalidSettings
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard try values.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
                throw MetadataFaceRecognitionSettingsError.invalidSettings
            }
            appendToKeywords = try values.decode(Bool.self, forKey: .appendToKeywords)
            try validate()
        } catch {
            throw MetadataFaceRecognitionSettingsError.invalidSettings
        }
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(appendToKeywords, forKey: .appendToKeywords)
    }
}

extension SyncJob {
    /// Recognition settings may be stored and transferred ahead of the runtime,
    /// but a run must never silently ignore a requested stage.
    var metadataFaceRecognitionRuntimeBlocker: String? {
        guard metadataFaceRecognition != nil else { return nil }
        return "Face recognition is saved but cannot run until the AuraFace preprocessing contract and calibrated acceptance policy are verified. Disable face recognition to run this job without it."
    }
}
