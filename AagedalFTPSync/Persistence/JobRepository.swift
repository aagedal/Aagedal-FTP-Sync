import Foundation

struct JobRepository: Sendable {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("AagedalFTPSync", isDirectory: true)
                .appendingPathComponent("jobs-v2.json")
        }
    }

    func load() throws -> [SyncJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.configured.decode([SyncJob].self, from: data)
    }

    func save(_ jobs: [SyncJob]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.configured.encode(jobs)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var configured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var configured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
