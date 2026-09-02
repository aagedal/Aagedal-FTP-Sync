import Foundation

struct ServerProfileLoadResult: Sendable {
    let profiles: [ServerProfile]
    let recoveredFromBackup: Bool
}

enum ServerProfileRepositoryError: LocalizedError, Equatable {
    case invalidProfile(String)
    case duplicateID
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let message):
            "A saved server profile is invalid: \(message)"
        case .duplicateID:
            "The server profile library contains the same profile more than once."
        case .duplicateName(let name):
            "A server profile named \(name) already exists."
        }
    }
}

struct ServerProfileRepository: Sendable {
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
                .appendingPathComponent("server-profiles-v1.json")
        }
    }

    func load() throws -> [ServerProfile] {
        try loadResult().profiles
    }

    func loadResult() throws -> ServerProfileLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ServerProfileLoadResult(profiles: [], recoveredFromBackup: false)
        }

        do {
            return ServerProfileLoadResult(
                profiles: try decode(Data(contentsOf: fileURL)),
                recoveredFromBackup: false
            )
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: backupURL.path) else {
                throw primaryError
            }
            do {
                return ServerProfileLoadResult(
                    profiles: try decode(Data(contentsOf: backupURL)),
                    recoveredFromBackup: true
                )
            } catch {
                throw primaryError
            }
        }
    }

    func save(_ profiles: [ServerProfile]) throws {
        try Self.validate(profiles)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.serverProfileConfigured.encode(profiles)

        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? decode(existingData)) != nil {
            // Atomic Data replacement keeps a valid previous backup visible even
            // if writing the next backup fails.
            try existingData.write(to: backupURL, options: .atomic)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    private func decode(_ data: Data) throws -> [ServerProfile] {
        let profiles = try JSONDecoder.serverProfileConfigured.decode([ServerProfile].self, from: data)
        try Self.validate(profiles)
        return profiles
    }

    private static func validate(_ profiles: [ServerProfile]) throws {
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw ServerProfileRepositoryError.duplicateID
        }

        var names = Set<String>()
        for profile in profiles {
            if let message = profile.validationMessage {
                throw ServerProfileRepositoryError.invalidProfile(message)
            }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let foldedName = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard names.insert(foldedName).inserted else {
                throw ServerProfileRepositoryError.duplicateName(name)
            }
        }
    }
}

private extension JSONEncoder {
    static var serverProfileConfigured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var serverProfileConfigured: JSONDecoder {
        JSONDecoder()
    }
}
