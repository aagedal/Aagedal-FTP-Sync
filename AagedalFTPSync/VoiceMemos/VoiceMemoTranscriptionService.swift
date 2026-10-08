import AVFAudio
import CryptoKit
import Foundation

enum VoiceMemoCompanion {
    static let maximumBytes: Int64 = 64 * 1024 * 1024
    static let maximumSeconds: Double = 30

    /// Exact stem and directory, case-insensitive extension. Ambiguous WAVs are refused.
    static func match(imagePath: String, paths: [String]) throws -> String? {
        guard FilterPreset.photos.extensions?.contains((imagePath as NSString).pathExtension.lowercased()) == true else { return nil }
        let stem = (imagePath as NSString).deletingPathExtension
        let matches = paths.filter {
            ($0 as NSString).pathExtension.lowercased() == "wav"
                && ($0 as NSString).deletingPathExtension == stem
        }
        guard matches.count <= 1 else {
            throw VoiceMemoError.unavailable("More than one WAV matches this image. Keep only one matching voice memo.")
        }
        return matches.first
    }

    static func index(_ files: [String: SyncFile]) -> [String: [SyncFile]] {
        var index: [String: [SyncFile]] = [:]
        for file in files.values {
            let path = file.originalRelativePath ?? file.relativePath
            guard (path as NSString).pathExtension.lowercased() == "wav" else { continue }
            index[(path as NSString).deletingPathExtension, default: []].append(file)
        }
        return index
    }

    static func file(for image: SyncFile, index: [String: [SyncFile]]) throws -> SyncFile? {
        let original = image.originalRelativePath ?? image.relativePath
        guard FilterPreset.photos.extensions?.contains((original as NSString).pathExtension.lowercased()) == true else { return nil }
        let matches = index[(original as NSString).deletingPathExtension] ?? []
        guard matches.count <= 1 else {
            throw VoiceMemoError.unavailable("More than one WAV matches this image. Keep only one matching voice memo.")
        }
        return matches.first
    }

    static func file(for image: SyncFile, in files: [String: SyncFile]) throws -> SyncFile? {
        try file(for: image, index: index(files))
    }

    static func receipts(in files: [String: SyncFile]) -> [SyncFile] {
        let index = index(files)
        return files.values.compactMap { image in
            guard let memo = try? file(for: image, index: index) else { return nil }
            return receipt(image: image, memo: memo)
        }
    }

    /// A receipt belongs to an image/memo pair, not to a separately transferred WAV.
    static func receipt(image: SyncFile, memo: SyncFile) -> SyncFile {
        let identity = SHA256.hash(data: Data((memo.originalRelativePath ?? memo.relativePath).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return SyncFile(relativePath: image.relativePath + "/.voice-memo-" + identity,
                        size: memo.size, modifiedAt: memo.modifiedAt)
    }

    static func localURL(for image: URL) throws -> URL? {
        let folder = image.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try match(imagePath: image.lastPathComponent, paths: names).map { folder.appendingPathComponent($0) }
    }

    static func validateSize(_ bytes: Int64) throws {
        guard bytes > 0, bytes <= maximumBytes else {
            throw VoiceMemoError.unavailable("The matching WAV is empty or exceeds the 64 MiB voice-memo limit.")
        }
    }
}

struct VoiceMemoTranscript: Equatable, Sendable {
    let text: String
    let limitedToThirtySeconds: Bool
    let revision: String
    var note: String {
        limitedToThirtySeconds
            ? "Voice memo: only the first 30 seconds were transcribed."
            : "Voice memo transcribed locally (up to 30 seconds)."
    }
}

/// Serial inference, bounded audio/output, cancellable child process, and an in-memory cache.
/// Cache identity includes WAV bytes, selected model bytes, language and clipping policy.
actor VoiceMemoTranscriptionService {
    static let shared = VoiceMemoTranscriptionService()
    private var busy = false
    private var cache: [String: VoiceMemoTranscript] = [:]
    private let models: WhisperModelStore
    private let executable: URL?

    init(models: WhisperModelStore = .shared, executable: URL? = Bundle.main.url(
        forResource: "ffmpeg", withExtension: nil, subdirectory: "WhisperRuntime")) {
        self.models = models
        self.executable = executable
    }

    func transcribe(_ audio: URL, settings: VoiceMemoSettings = .current) async throws -> VoiceMemoTranscript {
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        guard settings.isValid, let model = settings.model else {
            throw VoiceMemoError.unavailable("Choose a compatible Whisper model and language in Settings → Voice Memos.")
        }
        let values = try audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VoiceMemoError.unavailable("The matching WAV must be a regular file, not a symbolic link.")
        }
        try VoiceMemoCompanion.validateSize(Int64(values.fileSize ?? 0))
        let audioHash = try WhisperModelStore.digest(audio)
        let key = audioHash + ":" + model.sha256 + ":" + settings.language + ":first30-v1"
        if let cached = cache[key] { return cached }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw VoiceMemoError.unavailable("The bundled Whisper runtime is missing. Reinstall the application.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-memo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelURL = try await models.verifiedURL(for: model)
        let modelSnapshot = directory.appendingPathComponent("model.bin")
        try FileManager.default.copyItem(at: modelURL, to: modelSnapshot)
        guard try WhisperModelStore.verify(modelSnapshot, model: model) else {
            throw VoiceMemoError.unavailable("The Whisper model changed. Re-download it before transcribing.")
        }
        let clipped = try Self.clip(audio, to: directory.appendingPathComponent("input.wav"))
        guard try WhisperModelStore.digest(audio) == audioHash else {
            throw VoiceMemoError.unavailable("The WAV changed while it was being read. Retry after recording has finished.")
        }
        let output = directory.appendingPathComponent("transcript.txt")
        try await Self.run(executable: executable, directory: directory,
                           arguments: Self.arguments(language: settings.language), output: output)
        let data = try Data(contentsOf: output)
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceMemoError.unavailable("No usable speech was found in the first 30 seconds of the WAV.")
        }
        try Task.checkCancellation()
        guard try WhisperModelStore.digest(audio) == audioHash else {
            throw VoiceMemoError.unavailable("The WAV changed during transcription. Its result was discarded.")
        }
        let transcript = VoiceMemoTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                            limitedToThirtySeconds: clipped, revision: key)
        if cache.count >= 128 { cache.removeAll() }
        cache[key] = transcript
        return transcript
    }

    /// The decoder reads at most 30 seconds of frames; the original WAV never reaches Whisper.
    static func clip(_ source: URL, to destination: URL) throws -> Bool {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
              (1...8).contains(format.channelCount), input.length > 0 else {
            throw VoiceMemoError.unavailable("The voice memo has an unsupported audio format or contains no samples.")
        }
        let limit = AVAudioFramePosition(format.sampleRate * VoiceMemoCompanion.maximumSeconds)
        let count = min(input.length, limit)
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw VoiceMemoError.unavailable("Could not allocate an audio buffer.")
        }
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
            guard buffer.frameLength > 0 else {
                throw VoiceMemoError.unavailable("The WAV ended before its declared audio length.")
            }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return input.length > limit
    }

    static func arguments(language: String) -> [String] {
        ["-hide_banner", "-nostdin", "-xerror", "-loglevel", "error", "-protocol_whitelist", "file",
         "-format_whitelist", "wav", "-f", "wav", "-i", "input.wav", "-map", "0:a:0", "-vn", "-sn", "-dn",
         "-af", "whisper=model=model.bin:language=\(language):translate=false:queue=30:use_gpu=true:max_len=0:destination=transcript.txt:format=text",
         "-f", "null", "-"]
    }

    static func run(executable: URL, directory: URL, arguments: [String], output: URL,
                    timeout: Duration = .seconds(180)) async throws {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "HOME": directory.path, "TMPDIR": directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw VoiceMemoError.unavailable("Whisper exceeded its three-minute time limit. Try a smaller model.")
                }
                let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 65_536 else { throw VoiceMemoError.unavailable("Whisper produced too much text.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw VoiceMemoError.unavailable("Whisper could not transcribe this WAV. Try a smaller model or check the audio file.")
            }
            guard ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 65_536 else {
                throw VoiceMemoError.unavailable("Whisper produced no output or too much text.")
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning {
                await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
            }
            throw error
        }
    }
}
