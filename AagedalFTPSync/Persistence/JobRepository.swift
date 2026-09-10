import Foundation

struct JobLoadResult: Sendable {
    let jobs: [SyncJob]
    let recoveredFromBackup: Bool
}

struct JobRepository: Sendable {
    private let codec: VersionedStoreCodec
    private let fileURL: URL
    private let beforeSave: @Sendable () throws -> Void

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(
        fileURL: URL? = nil,
        storage: AppStorageLayout = .legacy,
        beforeSave: @escaping @Sendable () throws -> Void = {}
    ) {
        self.codec = VersionedStoreCodec(format: storage.storageFormat, store: .jobs)
        self.fileURL = fileURL ?? storage.jobs
        self.beforeSave = beforeSave
    }

    func load() throws -> [SyncJob] {
        try loadResult().jobs
    }

    func loadResult() throws -> JobLoadResult {
        try codec.validateExistingStore(at: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try codec.validateExistingStore(at: fileURL)
            return JobLoadResult(jobs: [], recoveredFromBackup: false)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let jobs = try codec.decode([SyncJob].self, from: data, decoder: JSONDecoder.configured)
            return JobLoadResult(jobs: jobs, recoveredFromBackup: false)
        } catch let primaryError {
            guard VersionedStoreCodec.permitsBackupRecovery(after: primaryError) else { throw primaryError }
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            do {
                let backupData = try Data(contentsOf: backupURL)
                let jobs = try codec.decode([SyncJob].self, from: backupData, decoder: JSONDecoder.configured)
                return JobLoadResult(jobs: jobs, recoveredFromBackup: true)
            } catch {
                guard VersionedStoreCodec.permitsBackupRecovery(after: error) else { throw error }
                throw primaryError
            }
        }
    }

    func save(_ jobs: [SyncJob]) throws {
        try beforeSave()
        try codec.validateExistingStore(at: fileURL)
        try codec.validateExistingStore(at: backupURL, required: false)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try codec.encode(jobs, encoder: JSONEncoder.configured)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           (try? codec.decode([SyncJob].self, from: existingData, decoder: JSONDecoder.configured)) != nil {
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
