import Foundation

struct MetadataPresetLoadResult: Sendable {
    let presets: [MetadataPreset]
    let recoveredFromBackup: Bool
}

struct MetadataPresetRepository: Sendable {
    private let codec: VersionedStoreCodec
    private let fileURL: URL

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil, storage: AppStorageLayout = .legacy) {
        self.codec = VersionedStoreCodec(format: storage.storageFormat, store: .metadataPresets)
        self.fileURL = fileURL ?? storage.metadataPresets
    }

    func load() throws -> [MetadataPreset] {
        try loadResult().presets
    }

    func loadResult() throws -> MetadataPresetLoadResult {
        try codec.validateExistingStore(at: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try codec.validateExistingStore(at: fileURL)
            return MetadataPresetLoadResult(presets: [], recoveredFromBackup: false)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let presets = try codec.decode([MetadataPreset].self, from: data, decoder: JSONDecoder.metadataPresetConfigured)
            return MetadataPresetLoadResult(presets: presets, recoveredFromBackup: false)
        } catch let primaryError {
            guard VersionedStoreCodec.permitsBackupRecovery(after: primaryError) else { throw primaryError }
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                let backupData = try Data(contentsOf: backupURL)
                let presets = try codec.decode([MetadataPreset].self, from: backupData, decoder: JSONDecoder.metadataPresetConfigured)
                return MetadataPresetLoadResult(presets: presets, recoveredFromBackup: true)
            } catch {
                guard VersionedStoreCodec.permitsBackupRecovery(after: error) else { throw error }
                throw primaryError
            }
        }
    }

    func save(_ presets: [MetadataPreset]) throws {
        try codec.validateExistingStore(at: fileURL)
        try codec.validateExistingStore(at: backupURL, required: false)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try codec.encode(presets, encoder: JSONEncoder.metadataPresetConfigured)

        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? codec.decode([MetadataPreset].self, from: existingData, decoder: JSONDecoder.metadataPresetConfigured)) != nil {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }

        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var metadataPresetConfigured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var metadataPresetConfigured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
