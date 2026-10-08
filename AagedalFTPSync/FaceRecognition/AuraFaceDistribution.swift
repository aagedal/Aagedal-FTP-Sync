import CryptoKit
import Darwin
import Foundation

struct AuraFaceDistributionDescriptor: Codable, Equatable, Sendable {
    struct FileDeclaration: Codable, Equatable, Sendable {
        let byteCount: Int
        let sha256: String
    }

    struct ArchiveDeclaration: Codable, Equatable, Sendable {
        let fileName: String
        let byteCount: Int
        let sha256: String
    }

    let schemaVersion: Int
    let componentID: String
    let modelVersion: String
    let embeddingVersion: Int
    let packageDirectory: String
    let packageFiles: [String: FileDeclaration]
    let archive: ArchiveDeclaration
    let downloadURL: URL
}

struct AuraFaceDistributionOrigin: Hashable, Sendable {
    let host: String
    let port: Int?

    init(host: String, port: Int? = nil) throws {
        let normalized = host.lowercased()
        guard !normalized.isEmpty, normalized == host,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
              }), port == nil || (1...65_535).contains(port!) else {
            throw AuraFaceComponentError.invalidTrustConfiguration
        }
        self.host = normalized
        self.port = port
    }

    func contains(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == host && url.port == port &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
            !url.path.isEmpty && !url.path.hasSuffix("/")
    }
}

struct AuraFaceDistributionTrust: Sendable {
    let descriptorURL: URL
    let signatureURL: URL
    let allowedOrigins: Set<AuraFaceDistributionOrigin>
    let publicKeyData: Data
    let supportedEmbeddingVersion: Int

    init(descriptorURL: URL, signatureURL: URL,
         allowedOrigins: Set<AuraFaceDistributionOrigin>, publicKeyData: Data,
         supportedEmbeddingVersion: Int) throws {
        guard publicKeyData.count == 32, supportedEmbeddingVersion > 0,
              !allowedOrigins.isEmpty,
              allowedOrigins.contains(where: { $0.contains(descriptorURL) }),
              allowedOrigins.contains(where: { $0.contains(signatureURL) }) else {
            throw AuraFaceComponentError.invalidTrustConfiguration
        }
        self.descriptorURL = descriptorURL
        self.signatureURL = signatureURL
        self.allowedOrigins = allowedOrigins
        self.publicKeyData = publicKeyData
        self.supportedEmbeddingVersion = supportedEmbeddingVersion
    }
}

enum AuraFaceComponentError: LocalizedError, Equatable {
    case invalidTrustConfiguration
    case invalidServerResponse
    case redirectedResponse
    case responseTooLarge
    case invalidDescriptorSignature
    case nonCanonicalDescriptor
    case invalidDescriptor
    case incompatibleEmbeddingVersion(required: Int, supported: Int)
    case archiveSizeMismatch
    case archiveHashMismatch
    case invalidArchive
    case unsafeArchive
    case packageFileSetMismatch
    case packageSizeMismatch(String)
    case packageHashMismatch(String)
    case invalidInstalledComponent
    case installationFailed
    case io

    var errorDescription: String? {
        switch self {
        case .invalidTrustConfiguration: "AuraFace distribution trust is not configured."
        case .invalidServerResponse: "The AuraFace server returned an invalid response."
        case .redirectedResponse: "The AuraFace server redirected a fixed distribution URL."
        case .responseTooLarge: "An AuraFace response exceeded its allowed size."
        case .invalidDescriptorSignature: "The AuraFace descriptor signature is invalid."
        case .nonCanonicalDescriptor: "The AuraFace descriptor is not canonically encoded."
        case .invalidDescriptor: "The AuraFace descriptor is invalid."
        case .incompatibleEmbeddingVersion(let required, let supported):
            "AuraFace embedding version \(required) is incompatible with version \(supported)."
        case .archiveSizeMismatch: "The AuraFace archive size is invalid."
        case .archiveHashMismatch: "The AuraFace archive hash is invalid."
        case .invalidArchive: "The AuraFace archive structure is invalid."
        case .unsafeArchive: "The AuraFace archive contains an unsafe entry."
        case .packageFileSetMismatch: "The AuraFace package file set is invalid."
        case .packageSizeMismatch(let path): "The AuraFace package size is invalid for \(path)."
        case .packageHashMismatch(let path): "The AuraFace package hash is invalid for \(path)."
        case .invalidInstalledComponent: "The installed AuraFace component is invalid."
        case .installationFailed: "AuraFace could not be installed; the previous version was retained."
        case .io: "AuraFace component storage could not be accessed safely."
        }
    }
}

enum AuraFaceDistributionContract {
    static let componentID = "auraface-r100-coreml"
    static let packageDirectory = "AuraFaceR100.mlpackage"
    static let compiledDirectory = "AuraFaceR100.mlmodelc"
    static let descriptorFile = "distribution.json"
    static let signatureFile = "distribution.json.sig"
    static let archiveFile = "AuraFaceR100.mlpackage.zip"
    static let packagePaths: Set<String> = [
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
        "Manifest.json",
    ]
    static let maximumDescriptorBytes = 16_384
    static let maximumSignatureBytes = 256
    static let maximumArchiveBytes = 256 * 1_048_576
    static let maximumPackageFileBytes = 192 * 1_048_576

    static func canonicalData(for descriptor: AuraFaceDistributionDescriptor) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(descriptor)
    }

    static func verify(descriptorData: Data, signatureData: Data,
                       trust: AuraFaceDistributionTrust) throws -> AuraFaceDistributionDescriptor {
        guard descriptorData.count <= maximumDescriptorBytes,
              signatureData.count <= maximumSignatureBytes else { throw AuraFaceComponentError.responseTooLarge }
        let signatureText = String(decoding: signatureData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.publicKeyData),
              key.isValidSignature(signature, for: descriptorData) else {
            throw AuraFaceComponentError.invalidDescriptorSignature
        }
        try validateSchema(descriptorData)
        guard let descriptor = try? JSONDecoder().decode(AuraFaceDistributionDescriptor.self, from: descriptorData),
              try canonicalData(for: descriptor) == descriptorData else {
            throw AuraFaceComponentError.nonCanonicalDescriptor
        }
        try validate(descriptor, trust: trust)
        return descriptor
    }

    static func validate(_ descriptor: AuraFaceDistributionDescriptor,
                         trust: AuraFaceDistributionTrust) throws {
        guard descriptor.schemaVersion == 2,
              descriptor.componentID == componentID,
              !descriptor.modelVersion.isEmpty, descriptor.modelVersion.utf8.count <= 128,
              descriptor.embeddingVersion > 0,
              descriptor.packageDirectory == packageDirectory,
              descriptor.archive.fileName == archiveFile,
              descriptor.archive.byteCount > 0,
              descriptor.archive.byteCount <= maximumArchiveBytes,
              isDigest(descriptor.archive.sha256),
              Set(descriptor.packageFiles.keys) == packagePaths,
              descriptor.packageFiles.values.allSatisfy({
                  $0.byteCount > 0 && $0.byteCount <= maximumPackageFileBytes && isDigest($0.sha256)
              }),
              descriptor.packageFiles.values.reduce(0, { $0 + $1.byteCount }) <= maximumArchiveBytes,
              trust.allowedOrigins.contains(where: { $0.contains(descriptor.downloadURL) }) else {
            throw AuraFaceComponentError.invalidDescriptor
        }
        guard descriptor.embeddingVersion == trust.supportedEmbeddingVersion else {
            throw AuraFaceComponentError.incompatibleEmbeddingVersion(
                required: descriptor.embeddingVersion, supported: trust.supportedEmbeddingVersion)
        }
    }

    static func digest(file: URL, maximumBytes: Int) throws -> (bytes: Int, sha256: String) {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AuraFaceComponentError.io }
        defer { close(descriptor) }
        let before = try stableRegularFile(descriptor, maximumBytes: maximumBytes)
        var count = 0
        var hasher = SHA256()
        while count < Int(before.st_size) {
            try Task.checkCancellation()
            let data = try read(descriptor, offset: count,
                                count: min(65_536, Int(before.st_size) - count))
            hasher.update(data: data)
            count += data.count
        }
        let after = try stableRegularFile(descriptor, maximumBytes: maximumBytes)
        guard sameFile(before, after) else { throw AuraFaceComponentError.io }
        return (count, Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined())
    }

    static func read(file: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AuraFaceComponentError.io }
        defer { close(descriptor) }
        let before = try stableRegularFile(descriptor, maximumBytes: maximumBytes)
        let data = try read(descriptor, offset: 0, count: Int(before.st_size))
        let after = try stableRegularFile(descriptor, maximumBytes: maximumBytes)
        guard sameFile(before, after) else { throw AuraFaceComponentError.io }
        return data
    }

    private static func validateSchema(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              Set(root.keys) == ["archive", "componentID", "downloadURL", "embeddingVersion",
                                  "modelVersion", "packageDirectory", "packageFiles", "schemaVersion"],
              let archive = root["archive"] as? [String: Any],
              Set(archive.keys) == ["byteCount", "fileName", "sha256"],
              let files = root["packageFiles"] as? [String: Any],
              Set(files.keys) == packagePaths,
              files.values.allSatisfy({ value in
                  guard let declaration = value as? [String: Any] else { return false }
                  return Set(declaration.keys) == ["byteCount", "sha256"]
              }) else { throw AuraFaceComponentError.invalidDescriptor }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) ||
                (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    private static func stableRegularFile(_ descriptor: Int32, maximumBytes: Int) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_size >= 0, value.st_size <= maximumBytes else {
            throw AuraFaceComponentError.responseTooLarge
        }
        return value
    }

    private static func read(_ descriptor: Int32, offset: Int, count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
            var consumed = 0
            while consumed < count {
                try Task.checkCancellation()
                let amount = pread(descriptor, buffer.baseAddress!.advanced(by: consumed),
                                   min(65_536, count - consumed), off_t(offset + consumed))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw AuraFaceComponentError.io }
                consumed += amount
            }
        }
        return result
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
            lhs.st_nlink == 1 && rhs.st_nlink == 1 &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
