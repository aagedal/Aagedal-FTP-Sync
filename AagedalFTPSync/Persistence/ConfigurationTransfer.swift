import CommonCrypto
import CryptoKit
import Foundation

enum ConfigurationTransferScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case jobs
    case metadata
    case package

    var id: Self { self }

    var title: String {
        switch self {
        case .jobs: "Sync Jobs"
        case .metadata: "Metadata Programming"
        case .package: "Jobs and Metadata Package"
        }
    }

    var defaultFilename: String {
        switch self {
        case .jobs: "Aagedal Sync Jobs"
        case .metadata: "Aagedal Metadata Programming"
        case .package: "Aagedal FTP Sync Package"
        }
    }
}

struct MetadataProgrammingTransfer: Codable, Equatable, Sendable {
    let jobID: UUID
    let jobName: String
    let automation: MetadataAutomation
}

struct ConfigurationTransfer: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let minimumSupportedVersion = 1
    static let formatIdentifier = "aagedal-ftp-sync-configuration"

    let format: String
    let version: Int
    let scope: ConfigurationTransferScope
    let exportedAt: Date
    let jobs: [SyncJob]
    let serverProfiles: [ServerProfile]
    let metadataProgramming: [MetadataProgrammingTransfer]
    let metadataPresets: [MetadataPreset]
    let photographers: [PhotographerProfile]

    init(
        scope: ConfigurationTransferScope,
        jobs: [SyncJob],
        serverProfiles: [ServerProfile] = [],
        metadataPresets: [MetadataPreset],
        photographers: [PhotographerProfile],
        exportedAt: Date = Date()
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.scope = scope
        self.exportedAt = exportedAt

        switch scope {
        case .jobs:
            let portableProfiles = Self.portableProfiles(referencedBy: jobs, from: serverProfiles)
            self.jobs = Self.portableJobs(jobs, using: portableProfiles)
            self.serverProfiles = portableProfiles
            metadataProgramming = []
            self.metadataPresets = []
            self.photographers = []
        case .metadata:
            self.jobs = []
            self.serverProfiles = []
            metadataProgramming = jobs.compactMap { job in
                job.metadataAutomation.map {
                    MetadataProgrammingTransfer(jobID: job.id, jobName: job.name, automation: $0)
                }
            }
            self.metadataPresets = metadataPresets
            self.photographers = photographers
        case .package:
            let portableProfiles = Self.portableProfiles(referencedBy: jobs, from: serverProfiles)
            self.jobs = Self.portableJobs(jobs, using: portableProfiles)
            self.serverProfiles = portableProfiles
            metadataProgramming = jobs.compactMap { job in
                job.metadataAutomation.map {
                    MetadataProgrammingTransfer(jobID: job.id, jobName: job.name, automation: $0)
                }
            }
            self.metadataPresets = metadataPresets
            self.photographers = photographers
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, scope, exportedAt, jobs, serverProfiles
        case metadataProgramming, metadataPresets, photographers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        scope = try container.decode(ConfigurationTransferScope.self, forKey: .scope)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        jobs = try container.decode([SyncJob].self, forKey: .jobs)
        serverProfiles = try container.decodeIfPresent([ServerProfile].self, forKey: .serverProfiles) ?? []
        metadataProgramming = try container.decode(
            [MetadataProgrammingTransfer].self,
            forKey: .metadataProgramming
        )
        metadataPresets = try container.decode([MetadataPreset].self, forKey: .metadataPresets)
        photographers = try container.decode([PhotographerProfile].self, forKey: .photographers)
    }

    private static func portableProfiles(
        referencedBy jobs: [SyncJob],
        from profiles: [ServerProfile]
    ) -> [ServerProfile] {
        let referencedIDs = Set(jobs.flatMap { job in
            [job.left.serverProfileID, job.right.serverProfileID, job.processedFolder?.serverProfileID]
                .compactMap { $0 }
        })
        return profiles
            .filter { referencedIDs.contains($0.id) }
            .map { $0.portableCopy() }
    }

    private static func portableJobs(
        _ jobs: [SyncJob],
        using profiles: [ServerProfile]
    ) -> [SyncJob] {
        var profilesByID: [UUID: ServerProfile] = [:]
        for profile in profiles {
            profilesByID[profile.id] = profile
        }
        return jobs.map { job in
            var portable = job.portableCopy(includeMetadata: false)
            portable.left = portableEndpoint(portable.left, profilesByID: profilesByID)
            portable.right = portableEndpoint(portable.right, profilesByID: profilesByID)
            if let processedFolder = portable.processedFolder {
                portable.processedFolder = portableEndpoint(
                    processedFolder,
                    profilesByID: profilesByID
                )
            }
            return portable
        }
    }

    private static func portableEndpoint(
        _ endpoint: Endpoint,
        profilesByID: [UUID: ServerProfile]
    ) -> Endpoint {
        guard let profileID = endpoint.serverProfileID,
              let profile = profilesByID[profileID] else {
            return endpoint
        }
        return profile.endpoint(remotePath: endpoint.remotePath)
    }
}

enum ConfigurationTransferError: LocalizedError, Equatable {
    case passwordTooShort
    case passwordRequired
    case fileTooLarge
    case invalidFormat
    case unsupportedVersion(Int)
    case unsupportedEncryption
    case wrongPasswordOrDamagedFile
    case keyDerivationFailed(Int32)
    case inconsistentContents

    var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            "Use a password with at least 12 characters."
        case .passwordRequired:
            "This package is encrypted. Enter its password to continue."
        case .fileTooLarge:
            "This configuration package is larger than the supported 50 MB limit."
        case .invalidFormat:
            "This is not an Aagedal FTP Sync configuration package."
        case .unsupportedVersion(let version):
            "This package uses unsupported format version \(version)."
        case .unsupportedEncryption:
            "This package uses an unsupported encryption method."
        case .wrongPasswordOrDamagedFile:
            "The password is incorrect, or the package has been changed or damaged."
        case .keyDerivationFailed(let status):
            "The encryption key could not be derived (\(status))."
        case .inconsistentContents:
            "The package contents do not match the type declared by the package."
        }
    }
}

enum ConfigurationTransferProtection: Equatable, Sendable {
    case encrypted
    case unencrypted
}

enum ConfigurationTransferCodec {
    static let minimumPasswordLength = 12
    static let maximumFileSize = 50 * 1_024 * 1_024

    private static let envelopeFormat = "aagedal-ftp-sync-encrypted"
    private static let envelopeVersion = 1
    private static let iterations = 600_000
    private static let saltLength = 16
    private static let keyLength = 32

    static func encode(_ transfer: ConfigurationTransfer, password: String?) throws -> Data {
        try validate(transfer)
        guard let password else {
            return try configuredEncoder.encode(transfer)
        }
        guard password.count >= minimumPasswordLength else {
            throw ConfigurationTransferError.passwordTooShort
        }
        let payload = try configuredEncoder.encode(transfer)
        let salt = randomData(count: saltLength)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let aad = authenticatedMetadata(salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw ConfigurationTransferError.invalidFormat
        }
        return try configuredEncoder.encode(
            EncryptedEnvelope(
                format: envelopeFormat,
                version: envelopeVersion,
                encryption: "AES-256-GCM",
                keyDerivation: "PBKDF2-HMAC-SHA256",
                iterations: iterations,
                salt: salt,
                sealedPayload: combined
            )
        )
    }

    static func protection(of data: Data) throws -> ConfigurationTransferProtection {
        guard data.count <= maximumFileSize else { throw ConfigurationTransferError.fileTooLarge }
        let probe: FormatProbe
        do {
            probe = try configuredDecoder.decode(FormatProbe.self, from: data)
        } catch {
            throw ConfigurationTransferError.invalidFormat
        }
        switch probe.format {
        case envelopeFormat:
            guard probe.version == envelopeVersion else {
                throw ConfigurationTransferError.unsupportedVersion(probe.version)
            }
            return .encrypted
        case ConfigurationTransfer.formatIdentifier:
            guard (ConfigurationTransfer.minimumSupportedVersion ... ConfigurationTransfer.currentVersion)
                .contains(probe.version) else {
                throw ConfigurationTransferError.unsupportedVersion(probe.version)
            }
            return .unencrypted
        default:
            throw ConfigurationTransferError.invalidFormat
        }
    }

    static func decode(_ data: Data, password: String?) throws -> ConfigurationTransfer {
        switch try protection(of: data) {
        case .unencrypted:
            do {
                let transfer = try configuredDecoder.decode(ConfigurationTransfer.self, from: data)
                try validate(transfer)
                return transfer
            } catch let error as ConfigurationTransferError {
                throw error
            } catch {
                throw ConfigurationTransferError.invalidFormat
            }
        case .encrypted:
            guard let password, !password.isEmpty else {
                throw ConfigurationTransferError.passwordRequired
            }
            return try decodeEncrypted(data, password: password)
        }
    }

    private static func decodeEncrypted(_ data: Data, password: String) throws -> ConfigurationTransfer {
        let envelope: EncryptedEnvelope
        do {
            envelope = try configuredDecoder.decode(EncryptedEnvelope.self, from: data)
        } catch {
            throw ConfigurationTransferError.invalidFormat
        }
        guard envelope.format == envelopeFormat else { throw ConfigurationTransferError.invalidFormat }
        guard envelope.version == envelopeVersion else {
            throw ConfigurationTransferError.unsupportedVersion(envelope.version)
        }
        guard envelope.encryption == "AES-256-GCM",
              envelope.keyDerivation == "PBKDF2-HMAC-SHA256",
              envelope.iterations >= 100_000,
              envelope.iterations <= 2_000_000,
              envelope.salt.count == saltLength else {
            throw ConfigurationTransferError.unsupportedEncryption
        }

        do {
            let key = try deriveKey(
                password: password,
                salt: envelope.salt,
                iterations: envelope.iterations
            )
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
            let payload = try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedMetadata(
                    salt: envelope.salt,
                    iterations: envelope.iterations
                )
            )
            let transfer = try configuredDecoder.decode(ConfigurationTransfer.self, from: payload)
            try validate(transfer)
            return transfer
        } catch let error as ConfigurationTransferError {
            throw error
        } catch {
            throw ConfigurationTransferError.wrongPasswordOrDamagedFile
        }
    }

    private static func validate(_ transfer: ConfigurationTransfer) throws {
        guard transfer.format == ConfigurationTransfer.formatIdentifier else {
            throw ConfigurationTransferError.invalidFormat
        }
        guard (ConfigurationTransfer.minimumSupportedVersion ... ConfigurationTransfer.currentVersion)
            .contains(transfer.version) else {
            throw ConfigurationTransferError.unsupportedVersion(transfer.version)
        }
        let isConsistent: Bool
        switch transfer.scope {
        case .jobs:
            isConsistent = !transfer.jobs.isEmpty
                && transfer.jobs.allSatisfy { $0.metadataAutomation == nil }
                && transfer.metadataProgramming.isEmpty
                && transfer.metadataPresets.isEmpty
                && transfer.photographers.isEmpty
        case .metadata:
            isConsistent = transfer.jobs.isEmpty
                && transfer.serverProfiles.isEmpty
        case .package:
            isConsistent = !transfer.jobs.isEmpty
                && transfer.jobs.allSatisfy { $0.metadataAutomation == nil }
        }
        let profileIDs = transfer.serverProfiles.map(\.id)
        let referencedProfileIDs = Set(transfer.jobs.flatMap { job in
            [job.left.serverProfileID, job.right.serverProfileID, job.processedFolder?.serverProfileID]
                .compactMap { $0 }
        })
        let transferredProfileIDs = Set(profileIDs)
        let profileShapeMatchesVersion = transfer.version == 1
            ? transfer.serverProfiles.isEmpty
            : referencedProfileIDs == transferredProfileIDs
        guard isConsistent,
              Set(profileIDs).count == profileIDs.count,
              transferredProfileIDs.isSubset(of: referencedProfileIDs),
              profileShapeMatchesVersion,
              transfer.serverProfiles.allSatisfy({ $0.validationMessage == nil }) else {
            throw ConfigurationTransferError.inconsistentContents
        }
    }

    private static func deriveKey(
        password: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        var derivedKey = Data(count: keyLength)
        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withCString { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes,
                        password.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw ConfigurationTransferError.keyDerivationFailed(status)
        }
        return SymmetricKey(data: derivedKey)
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func authenticatedMetadata(salt: Data, iterations: Int) -> Data {
        var data = Data("\(envelopeFormat)|\(envelopeVersion)|AES-256-GCM|PBKDF2-HMAC-SHA256|\(iterations)|".utf8)
        data.append(salt)
        return data
    }

    private static var configuredEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var configuredDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct EncryptedEnvelope: Codable {
    let format: String
    let version: Int
    let encryption: String
    let keyDerivation: String
    let iterations: Int
    let salt: Data
    let sealedPayload: Data
}

private struct FormatProbe: Decodable {
    let format: String
    let version: Int
}

extension Endpoint {
    func portableCopy() -> Endpoint {
        var result = self
        result.bookmark = nil
        // Credential IDs point to passwords in this Mac's Keychain. A portable
        // configuration deliberately never carries or references those secrets.
        result.credentialID = UUID().uuidString
        return result
    }

    func preparedForImport() -> Endpoint {
        var result = portableCopy()
        result.credentialID = UUID().uuidString
        return result
    }
}

extension SyncJob {
    func portableCopy(includeMetadata: Bool) -> SyncJob {
        var result = self
        result.left = left.portableCopy()
        result.right = right.portableCopy()
        result.processedFolder = processedFolder?.portableCopy()
        if !includeMetadata { result.metadataAutomation = nil }
        return result
    }

    func preparedForImport(id: UUID = UUID(), name: String? = nil) -> SyncJob {
        var result = self
        result.id = id
        result.name = name ?? self.name
        result.left = left.preparedForImport()
        result.right = right.preparedForImport()
        result.processedFolder = processedFolder?.preparedForImport()
        result.isEnabled = false
        result.startOnAppLaunch = false
        return result
    }
}

extension ServerProfile {
    func portableCopy() -> ServerProfile {
        var result = self
        result.credentialID = UUID().uuidString
        return result
    }

    func preparedForImport(id: UUID = UUID(), name: String? = nil) -> ServerProfile {
        var result = portableCopy()
        result.id = id
        result.name = name ?? self.name
        return result
    }
}
