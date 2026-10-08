import CryptoKit
import Foundation

enum VoiceMemoError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

struct WhisperDownloadProgress: Sendable {
    enum Phase: Sendable { case connecting, downloading, verifying, installing, complete }
    var receivedBytes: Int64
    var expectedBytes: Int64
    var bytesPerSecond: Double = 0
    var updatedAt: Date = Date()
    var phase: Phase = .downloading
    var fraction: Double { min(1, max(0, Double(receivedBytes) / Double(max(1, expectedBytes)))) }
    func isWaiting(at date: Date) -> Bool {
        (phase == .connecting || phase == .downloading) && date.timeIntervalSince(updatedAt) >= 10
    }
    func speed(at date: Date) -> Double {
        phase == .downloading && date.timeIntervalSince(updatedAt) < 3 ? bytesPerSecond : 0
    }
}

/// Throttle UI updates and measure transfer rate between samples, excluding verification.
struct WhisperDownloadProgressSampler {
    let expectedBytes: Int64
    private var previousBytes: Int64 = 0
    private var previousTime: TimeInterval
    init(expectedBytes: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.expectedBytes = expectedBytes
        self.previousTime = now
    }
    mutating func sample(bytes: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> WhisperDownloadProgress? {
        let elapsed = now - previousTime
        guard elapsed >= 0.25 || bytes == expectedBytes else { return nil }
        let speed = elapsed > 0 ? Double(max(0, bytes - previousBytes)) / elapsed : 0
        previousBytes = bytes
        previousTime = now
        return WhisperDownloadProgress(receivedBytes: bytes, expectedBytes: expectedBytes, bytesPerSecond: speed)
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

    func download(_ model: WhisperModel, progress: @escaping @Sendable (WhisperDownloadProgress) -> Void) async throws {
        guard downloading.insert(model.id).inserted else {
            throw VoiceMemoError.unavailable("This model is already downloading.")
        }
        defer { downloading.remove(model.id) }
        progress(.init(receivedBytes: 0, expectedBytes: model.bytes, phase: .connecting))
        let delegate = ModelDownloadProgress(expectedBytes: model.bytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3600
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await delegate.download(from: model.downloadURL, session: session)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceMemoError.unavailable("The model server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Please try again.")
        }
        progress(.init(receivedBytes: model.bytes, expectedBytes: model.bytes, phase: .verifying))
        guard try Self.verify(temporary, model: model) else {
            throw VoiceMemoError.unavailable("The downloaded model failed verification. Please try again.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress(.init(receivedBytes: model.bytes, expectedBytes: model.bytes, phase: .installing))
        let staged = directory.appendingPathComponent(UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: temporary, to: staged)
        try Task.checkCancellation()
        let destination = path(for: model)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        progress(.init(receivedBytes: model.bytes, expectedBytes: model.bytes, phase: .complete))
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

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedBytes: Int64
    let progress: @Sendable (WhisperDownloadProgress) -> Void
    private let lock = NSLock()
    private var sampler: WhisperDownloadProgressSampler
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloaded: (URL, URLResponse)?
    private var completionError: Error?
    private var cancelled = false
    init(expectedBytes: Int64, progress: @escaping @Sendable (WhisperDownloadProgress) -> Void) {
        self.expectedBytes = expectedBytes
        self.sampler = WhisperDownloadProgressSampler(expectedBytes: expectedBytes)
        self.progress = progress
    }
    func download(from url: URL, session: URLSession) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                let shouldStart = lock.withLock {
                    guard !cancelled else { return false }
                    self.continuation = continuation
                    self.task = task
                    return true
                }
                if shouldStart { task.resume() }
                else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes,
              totalBytesExpectedToWrite <= expectedBytes else {
            lock.withLock { completionError = VoiceMemoError.unavailable("The server sent more data than the model’s expected size.") }
            downloadTask.cancel()
            return
        }
        let sample = lock.withLock { sampler.sample(bytes: totalBytesWritten) }
        if let sample { progress(sample) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // URLSession removes its temporary file when this callback returns.
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".whisper-download")
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: retained)
            lock.withLock { downloaded = (retained, response) }
        } catch { lock.withLock { completionError = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = lock.withLock { () -> (CheckedContinuation<(URL, URLResponse), Error>?, (URL, URLResponse)?, Error?) in
            let result = (continuation, downloaded, cancelled ? CancellationError() : (completionError ?? error))
            continuation = nil
            downloaded = nil
            self.task = nil
            return result
        }
        if let error = completion.2 {
            if let file = completion.1?.0 { try? FileManager.default.removeItem(at: file) }
            completion.0?.resume(throwing: error)
        } else if let downloaded = completion.1 {
            completion.0?.resume(returning: downloaded)
        } else {
            completion.0?.resume(throwing: URLError(.badServerResponse))
        }
    }
}
