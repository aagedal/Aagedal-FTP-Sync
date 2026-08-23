import Foundation

struct JobLoadResult: Sendable {
    let jobs: [SyncJob]
    let recoveredFromBackup: Bool
}

struct JobRepository: Sendable {
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
                .appendingPathComponent("jobs-v2.json")
        }
    }

    func load() throws -> [SyncJob] {
        try loadResult().jobs
    }

    func loadResult() throws -> JobLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return JobLoadResult(jobs: [], recoveredFromBackup: false)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let jobs = try JSONDecoder.configured.decode([SyncJob].self, from: data)
            return JobLoadResult(jobs: jobs, recoveredFromBackup: false)
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                let backupData = try Data(contentsOf: backupURL)
                let jobs = try JSONDecoder.configured.decode([SyncJob].self, from: backupData)
                return JobLoadResult(jobs: jobs, recoveredFromBackup: true)
            } catch {
                throw primaryError
            }
        }
    }

    func save(_ jobs: [SyncJob]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.configured.encode(jobs)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? JSONDecoder.configured.decode([SyncJob].self, from: existingData)) != nil {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
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
