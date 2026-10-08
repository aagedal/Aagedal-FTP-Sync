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

enum PhotographerLibraryTransferError: LocalizedError, Equatable {
    case invalidFormat
    case unsupportedVersion(Int)
    case activatedTemplatesRequireConfigurationPackage

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This is not an Aagedal FTP Sync photographer list."
        case .activatedTemplatesRequireConfigurationPackage:
            "Photographers with Copyright variables require a version 3 configuration package. Use Export Metadata Programming instead."
        case .unsupportedVersion(let version):
            "This photographer list uses unsupported format version \(version)."
        }
    }
}

enum PhotographerLibraryTransferCodec {
    static func encode(_ photographers: [PhotographerProfile]) throws -> Data {
        guard !photographers.contains(where: \.hasActivatedTemplates) else {
            throw PhotographerLibraryTransferError.activatedTemplatesRequireConfigurationPackage
        }
        return try JSONEncoder.photographerProfileConfigured.encode(
            PhotographerLibraryTransfer(photographers: photographers)
        )
    }

    static func decode(_ data: Data) throws -> [PhotographerProfile] {
        let decoder = JSONDecoder.photographerProfileConfigured
        // The standalone list remains a literal-only v1 interchange contract.
        // Scan before either domain decoder so malformed/ignored markers cannot be
        // stripped, including in the legacy raw-array path.
        do { try VersionedStoreCodec.rejectLegacyTemplateMarkers(in: data) }
        catch VersionedStoreCodec.HeaderError.requiresVersion3Storage {
            throw PhotographerLibraryTransferError.activatedTemplatesRequireConfigurationPackage
        } catch { throw PhotographerLibraryTransferError.invalidFormat }
        struct Header: Decodable { let format: String; let version: Int }
        guard let header = try? decoder.decode(Header.self, from: data) else {
            if let photographers = try? decoder.decode([PhotographerProfile].self, from: data) {
                return photographers
            }
            throw PhotographerLibraryTransferError.invalidFormat
        }
        guard header.format == PhotographerLibraryTransfer.formatIdentifier else {
            throw PhotographerLibraryTransferError.invalidFormat
        }
        guard header.version == PhotographerLibraryTransfer.currentVersion else {
            throw PhotographerLibraryTransferError.unsupportedVersion(header.version)
        }
        let transfer: PhotographerLibraryTransfer
        do { transfer = try decoder.decode(PhotographerLibraryTransfer.self, from: data) }
        catch { throw PhotographerLibraryTransferError.invalidFormat }
        return transfer.photographers
    }
}

struct PhotographerProfileRepository: Sendable {
    private let codec: VersionedStoreCodec
    private let fileURL: URL

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL? = nil, storage: AppStorageLayout = .legacy) {
        self.codec = VersionedStoreCodec(format: storage.storageFormat, store: .photographers)
        self.fileURL = fileURL ?? storage.photographers
    }

    func load() throws -> [PhotographerProfile] {
        try loadResult().photographers
    }

    func loadResult() throws -> PhotographerProfileLoadResult {
        try codec.validateExistingStore(at: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try codec.validateExistingStore(at: fileURL)
            return PhotographerProfileLoadResult(photographers: [], recoveredFromBackup: false)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let photographers = try codec.decode([PhotographerProfile].self, from: data, decoder: JSONDecoder.photographerProfileConfigured)
            return PhotographerProfileLoadResult(
                photographers: photographers,
                recoveredFromBackup: false
            )
        } catch let primaryError {
            guard VersionedStoreCodec.permitsBackupRecovery(after: primaryError) else { throw primaryError }
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                let backupData = try Data(contentsOf: backupURL)
                let photographers = try codec.decode([PhotographerProfile].self, from: backupData, decoder: JSONDecoder.photographerProfileConfigured)
                return PhotographerProfileLoadResult(
                    photographers: photographers,
                    recoveredFromBackup: true
                )
            } catch {
                guard VersionedStoreCodec.permitsBackupRecovery(after: error) else { throw error }
                throw primaryError
            }
        }
    }

    func save(_ photographers: [PhotographerProfile]) throws {
        try codec.validateExistingStore(at: fileURL)
        try codec.validateExistingStore(at: backupURL, required: false)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try codec.encode(photographers, encoder: JSONEncoder.photographerProfileConfigured)

        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? codec.decode([PhotographerProfile].self, from: existingData, decoder: JSONDecoder.photographerProfileConfigured)) != nil {
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
