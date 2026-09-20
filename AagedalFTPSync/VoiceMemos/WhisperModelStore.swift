import CryptoKit
import Foundation

enum VoiceMemoError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

actor WhisperModelStore {
    static let shared = WhisperModelStore()
    let directory: URL
    private var downloading: Set<String> = []

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AagedalFTPSync/VoiceMemoModels", isDirectory: true)) {
        self.directory = directory
    }

    func path(for model: WhisperModel) -> URL { directory.appendingPathComponent(model.id + ".bin") }

    func installedIDs() -> Set<String> {
        Set(WhisperModel.catalogue.filter { model in
            let values = try? path(for: model).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
                && values?.fileSize == Int(model.bytes)
        }.map(\.id))
    }

    func verifiedURL(for model: WhisperModel) throws -> URL {
        let url = path(for: model)
        guard try Self.verify(url, model: model) else {
            throw VoiceMemoError.unavailable("Download or re-download \(model.name) in Settings → Voice Memos.")
        }
        return url
    }

    func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard downloading.insert(model.id).inserted else { return }
        defer { downloading.remove(model.id) }
        let delegate = ModelDownloadProgress(expectedBytes: model.bytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: model.downloadURL, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              try Self.verify(temporary, model: model) else {
            throw VoiceMemoError.unavailable("The downloaded model failed verification. Please try again.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: temporary, to: staged)
        try Task.checkCancellation()
        let destination = path(for: model)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        progress(1)
    }

    func delete(_ model: WhisperModel) throws {
        guard !downloading.contains(model.id) else { return }
        let url = path(for: model)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func verify(_ url: URL, model: WhisperModel) throws -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == Int(model.bytes) else { return false }
        return try digest(url) == model.sha256
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let expectedBytes: Int64
    let progress: @Sendable (Double) -> Void
    init(expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes,
              totalBytesExpectedToWrite <= expectedBytes else { downloadTask.cancel(); return }
        progress(min(0.99, Double(totalBytesWritten) / Double(expectedBytes)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
