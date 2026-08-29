import Foundation

struct MetadataPresetLoadResult: Sendable {
    let presets: [MetadataPreset]
    let recoveredFromBackup: Bool
}

struct MetadataPresetRepository: Sendable {
    private let fileURL: URL

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("AagedalFTPSync", isDirectory: true)
                .appendingPathComponent("metadata-presets-v1.json")
        }
    }

    func load() throws -> [MetadataPreset] {
        try loadResult().presets
    }

    func loadResult() throws -> MetadataPresetLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MetadataPresetLoadResult(presets: [], recoveredFromBackup: false)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let presets = try JSONDecoder.metadataPresetConfigured.decode([MetadataPreset].self, from: data)
            return MetadataPresetLoadResult(presets: presets, recoveredFromBackup: false)
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                let backupData = try Data(contentsOf: backupURL)
                let presets = try JSONDecoder.metadataPresetConfigured.decode([MetadataPreset].self, from: backupData)
                return MetadataPresetLoadResult(presets: presets, recoveredFromBackup: true)
            } catch {
                throw primaryError
            }
        }
    }

    func save(_ presets: [MetadataPreset]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.metadataPresetConfigured.encode(presets)

        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? JSONDecoder.metadataPresetConfigured.decode([MetadataPreset].self, from: existingData)) != nil {
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
