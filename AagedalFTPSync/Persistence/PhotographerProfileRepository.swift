import Foundation

struct PhotographerProfileLoadResult: Sendable {
    let photographers: [PhotographerProfile]
    let recoveredFromBackup: Bool
}

struct PhotographerLibraryTransfer: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let formatIdentifier = "aagedal-ftp-sync-photographers"

    let format: String
    let version: Int
    let photographers: [PhotographerProfile]

    init(photographers: [PhotographerProfile]) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.photographers = photographers
    }
}

enum PhotographerLibraryTransferError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This is not an Aagedal FTP Sync photographer list."
        case .unsupportedVersion(let version):
            "This photographer list uses unsupported format version \(version)."
        }
    }
}

enum PhotographerLibraryTransferCodec {
    static func encode(_ photographers: [PhotographerProfile]) throws -> Data {
        try JSONEncoder.photographerProfileConfigured.encode(
            PhotographerLibraryTransfer(photographers: photographers)
        )
    }

    static func decode(_ data: Data) throws -> [PhotographerProfile] {
        let decoder = JSONDecoder.photographerProfileConfigured
        let transfer: PhotographerLibraryTransfer
        do {
            transfer = try decoder.decode(PhotographerLibraryTransfer.self, from: data)
        } catch {
            // Accept the raw array used by the on-disk v1 repository as a legacy
            // interchange format, while all new exports use the versioned envelope.
            if let photographers = try? decoder.decode([PhotographerProfile].self, from: data) {
                return photographers
            }
            throw PhotographerLibraryTransferError.invalidFormat
        }

        guard transfer.format == PhotographerLibraryTransfer.formatIdentifier else {
            throw PhotographerLibraryTransferError.invalidFormat
        }
        guard transfer.version == PhotographerLibraryTransfer.currentVersion else {
            throw PhotographerLibraryTransferError.unsupportedVersion(transfer.version)
        }
        return transfer.photographers
    }
}

struct PhotographerProfileRepository: Sendable {
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
                .appendingPathComponent("photographers-v1.json")
        }
    }

    func load() throws -> [PhotographerProfile] {
        try loadResult().photographers
    }

    func loadResult() throws -> PhotographerProfileLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PhotographerProfileLoadResult(photographers: [], recoveredFromBackup: false)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let photographers = try JSONDecoder.photographerProfileConfigured.decode(
                [PhotographerProfile].self,
                from: data
            )
            return PhotographerProfileLoadResult(
                photographers: photographers,
                recoveredFromBackup: false
            )
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                let backupData = try Data(contentsOf: backupURL)
                let photographers = try JSONDecoder.photographerProfileConfigured.decode(
                    [PhotographerProfile].self,
                    from: backupData
                )
                return PhotographerProfileLoadResult(
                    photographers: photographers,
                    recoveredFromBackup: true
                )
            } catch {
                throw primaryError
            }
        }
    }

    func save(_ photographers: [PhotographerProfile]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.photographerProfileConfigured.encode(photographers)

        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? JSONDecoder.photographerProfileConfigured.decode(
               [PhotographerProfile].self,
               from: existingData
           )) != nil {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }

        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var photographerProfileConfigured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var photographerProfileConfigured: JSONDecoder {
        JSONDecoder()
    }
}
