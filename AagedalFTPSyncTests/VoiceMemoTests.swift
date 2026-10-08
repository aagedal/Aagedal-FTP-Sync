import AppKit
import AVFAudio
import CryptoKit
import MetadataTemplates
import Network
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class VoiceMemoTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func jpeg(in folder: URL) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 100, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let url = folder.appendingPathComponent("photo.JPG")
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
        return url
    }

    private func assignment(policy: MetadataExistingFieldPolicy = .overwrite) throws -> MetadataAssignment {
        let photographer = PhotographerProfile(name: "Test", filenamePrefix: "photo", creator: "", copyrightNotice: "")
        var fields = ScheduledMetadataFields()
        fields.setDescription(try .activated("{existingDescription}\n{voiceMemoTranscript}"))
        let clip = MetadataScheduleClip(photographerID: photographer.id, name: "Test",
            startsAt: .distantPast, endsAt: .distantFuture, fields: fields)
        return MetadataAssignment(photographer: photographer, clip: clip, existingFieldPolicy: policy)
    }

    func testMatchingRequiresExactStemAndDirectoryButAcceptsWAVCase() throws {
        XCTAssertEqual(try VoiceMemoCompanion.match(imagePath: "dir/photo.JPG",
            paths: ["dir/photo.WaV", "else/photo.wav", "dir/photo2.wav"]), "dir/photo.WaV")
        XCTAssertNil(try VoiceMemoCompanion.match(imagePath: "dir/photo.JPG", paths: ["dir/PHOTO.wav"]))
        XCTAssertNil(try VoiceMemoCompanion.match(imagePath: "photo.wav", paths: ["photo.wav"]))
        XCTAssertThrowsError(try VoiceMemoCompanion.match(imagePath: "photo.JPG", paths: ["photo.wav", "photo.WAV"]))
    }

    func testRenamedImagesMatchOriginalCompanionNotUnrelatedLocalStem() throws {
        let date = Date()
        let image = SyncFile(relativePath: "new.jpg", size: 10, modifiedAt: date, originalRelativePath: "old.jpg")
        let memo = SyncFile(relativePath: "new-audio.wav", size: 20, modifiedAt: date, originalRelativePath: "old.WAV")
        let unrelated = SyncFile(relativePath: "new.wav", size: 20, modifiedAt: date)
        XCTAssertEqual(try VoiceMemoCompanion.file(for: image, in: [memo.relativePath: memo, unrelated.relativePath: unrelated]), memo)
        XCTAssertNotEqual(VoiceMemoCompanion.receipt(image: image, memo: memo).relativePath, memo.relativePath)
    }

    func testReceiptMatchesAtPersistedTimestampPrecision() {
        let original = Date(timeIntervalSinceReferenceDate: 800_000_000.0000001)
        let restored = Date(timeIntervalSince1970: original.timeIntervalSince1970)
        let file = SyncFile(relativePath: "photo.WAV", size: 100, modifiedAt: original)
        let signature = SourceFileSignature(size: 100, modifiedAt: restored)
        XCTAssertTrue(signature.matches(file, timestampTolerance: 0))
        XCTAssertFalse(signature.matches(SyncFile(relativePath: file.relativePath, size: 100,
            modifiedAt: original.addingTimeInterval(0.001)), timestampTolerance: 0))
    }

    func testWAVSizeGuardRejectsEmptyAndOversizedBeforeRead() throws {
        XCTAssertThrowsError(try VoiceMemoCompanion.validateSize(0))
        XCTAssertThrowsError(try VoiceMemoCompanion.validateSize(VoiceMemoCompanion.maximumBytes + 1))
        XCTAssertNoThrow(try VoiceMemoCompanion.validateSize(VoiceMemoCompanion.maximumBytes))
    }

    func testClippingActuallyWritesAtMostThirtySeconds() throws {
        let directory = try folder()
        for seconds in [1, 30, 45] {
            let source = directory.appendingPathComponent("input-\(seconds).wav")
            let target = directory.appendingPathComponent("clipped-\(seconds).wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            do {
                let file = try AVAudioFile(forWriting: source, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
                buffer.frameLength = 16_000
                try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: 16_000)
                for _ in 0..<seconds { try file.write(from: buffer) }
            }
            XCTAssertEqual(try VoiceMemoTranscriptionService.clip(source, to: target), seconds > 30)
            let clipped = try AVAudioFile(forReading: target)
            XCTAssertEqual(clipped.length, AVAudioFramePosition(min(seconds, 30) * 16_000))
        }
    }

    func testEntireExpandedCaptionUsesUTF8ByteBudget() throws {
        let request = try MetadataProcessingRequest(assignment: assignment())
        func resolve(_ text: String) -> MetadataProcessingResult {
            MetadataProcessingCoordinator.resolve(request,
                context: .init(processingDate: Date(), processingTimeZone: TimeZone(secondsFromGMT: 0)!,
                               voiceMemoTranscript: text, existingDescription: "Caption"),
                writableFields: Set(MetadataWritableField.allCases))
        }
        let fits = resolve(String(repeating: "ø", count: 996))
        XCTAssertEqual(fits.changes.description.utf8.count, 2000)
        let oversized = resolve(String(repeating: "ø", count: 997))
        XCTAssertEqual(oversized.changes.description, "")
        XCTAssertEqual(oversized.fields[.description], .omitted(.writerByteLimit(maximum: 2000)))
        XCTAssertFalse(oversized.resolutionComplete)
    }

    func testMissingMemoPreservesCaptionAndRecordsReason() async throws {
        let image = try jpeg(in: folder())
        try MetadataWriter.apply(.init(description: "Original", existingFieldPolicy: .overwrite), to: image)
        let result = try await MetadataProcessingCoordinator.prepare(assignment: assignment(), geocoding: nil,
            services: .init(transcribeVoiceMemo: { _ in XCTFail("Missing WAV must not start inference"); throw CancellationError() }),
            fileURL: image, relativePath: image.lastPathComponent, processingDate: Date(),
            processingTimeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(result.changes.description, "")
        XCTAssertFalse(result.resolutionComplete)
        XCTAssertTrue(result.voiceMemoNote?.contains("No matching WAV") == true)
        XCTAssertEqual(try ImageMetadata.read(from: image).iptc.caption, "Original")
    }

    func testFillEmptyNeverCallsTranscriberForExistingCaption() async throws {
        let image = try jpeg(in: folder())
        try MetadataWriter.apply(.init(description: "Original", existingFieldPolicy: .overwrite), to: image)
        let result = try await MetadataProcessingCoordinator.prepare(assignment: assignment(policy: .fillEmpty), geocoding: nil,
            services: .init(transcribeVoiceMemo: { _ in XCTFail("Preserved field must not start inference"); throw CancellationError() }),
            fileURL: image, relativePath: image.lastPathComponent, processingDate: Date(),
            processingTimeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(result.fields[.description], .preservedByPolicy)
        XCTAssertNil(result.voiceMemoNote)
    }

    func testReprocessingRetainsOriginalCaptionAndExternalEditsBecomeNewBaseline() throws {
        for isRaw in [false, true] {
            let directory = try folder()
            let image = isRaw ? directory.appendingPathComponent("photo.NEF") : try jpeg(in: directory)
            if isRaw { try Data("opaque RAW".utf8).write(to: image) }
            _ = try MetadataWriter.apply(.init(description: "Original", existingFieldPolicy: .overwrite),
                                         to: image, relativePath: image.lastPathComponent)
            for memo in ["Første notat", "Første notat", "Oppdatert notat"] {
                let result = try MetadataProcessingCoordinator.preparePerImage(assignment: assignment(),
                    fileURL: image, relativePath: image.lastPathComponent, processingDate: Date(),
                    processingTimeZone: TimeZone(secondsFromGMT: 0)!, voiceMemoTranscript: memo)
                XCTAssertEqual(result.changes.description, "Original\n" + memo)
                _ = try MetadataWriter.apply(result.changes, to: image, relativePath: image.lastPathComponent)
                XCTAssertEqual(try MetadataWriter.descriptionForTemplate(at: image, relativePath: image.lastPathComponent), "Original")
            }
            _ = try MetadataWriter.apply(.init(description: "Edited caption", existingFieldPolicy: .overwrite),
                                         to: image, relativePath: image.lastPathComponent)
            XCTAssertEqual(try MetadataWriter.descriptionForTemplate(at: image, relativePath: image.lastPathComponent), "Edited caption")
        }
    }

    func testDownloadProgressSamplesRateAndShowsWaitingInsteadOfStaleSpeed() {
        var sampler = WhisperDownloadProgressSampler(expectedBytes: 1_000, now: 0)
        XCTAssertNil(sampler.sample(bytes: 50, now: 0.1))
        let first = sampler.sample(bytes: 200, now: 0.5)!
        XCTAssertEqual(first.bytesPerSecond, 400)
        let second = sampler.sample(bytes: 500, now: 1)!
        XCTAssertEqual(second.bytesPerSecond, 600)
        XCTAssertEqual(second.fraction, 0.5)
        XCTAssertEqual(second.speed(at: second.updatedAt.addingTimeInterval(4)), 0)
        XCTAssertTrue(second.isWaiting(at: second.updatedAt.addingTimeInterval(11)))
        let verifying = WhisperDownloadProgress(receivedBytes: 1_000, expectedBytes: 1_000, phase: .verifying)
        XCTAssertFalse(verifying.isWaiting(at: verifying.updatedAt.addingTimeInterval(60)))
    }

    @MainActor
    func testRealDownloadReportsBytesAndVerificationBeforeInstalling() async throws {
        let payload = Data(repeating: 42, count: 262_144)
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Model fixture listening")
        let queue = DispatchQueue(label: "whisper-download-fixture")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: headers + payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let model = WhisperModel(id: "fixture", name: "Fixture", bytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            source: "http://127.0.0.1:\(port.rawValue)/model")
        let bytes = expectation(description: "Download delegate reports bytes")
        bytes.assertForOverFulfill = false
        let verifying = expectation(description: "Verification phase")
        let installed = expectation(description: "Installed phase")
        let store = WhisperModelStore(directory: try folder())
        try await store.download(model) { progress in
            if progress.phase == .downloading && progress.receivedBytes > 0 { bytes.fulfill() }
            if progress.phase == .verifying { verifying.fulfill() }
            if progress.phase == .complete { installed.fulfill() }
        }
        await fulfillment(of: [bytes, verifying, installed], timeout: 3, enforceOrder: true)
        let path = try await store.verifiedURL(for: model)
        XCTAssertEqual(try Data(contentsOf: path), payload)
    }

    @MainActor
    func testCancellingAStalledModelDownloadDoesNotInstallAPartialFile() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Listening")
        let requested = expectation(description: "Download requested")
        let queue = DispatchQueue(label: "whisper-cancel-fixture")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    requested.fulfill()
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
                })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let model = WhisperModel(id: "cancelled", name: "Cancelled", bytes: 1000,
            sha256: String(repeating: "0", count: 64), source: "http://127.0.0.1:\(port.rawValue)/model")
        let store = WhisperModelStore(directory: try folder())
        let task = Task { try await store.download(model) { _ in } }
        await fulfillment(of: [requested], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let path = await store.path(for: model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testModelVerificationRejectsCorruptionWithSameSize() throws {
        let path = try folder().appendingPathComponent("model.bin")
        let data = Data("known model fixture".utf8)
        try data.write(to: path)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let model = WhisperModel(id: "fixture", name: "Fixture", bytes: Int64(data.count), sha256: hash, source: "https://example.com/model")
        XCTAssertTrue(try WhisperModelStore.verify(path, model: model))
        try Data(repeating: 0, count: data.count).write(to: path)
        XCTAssertFalse(try WhisperModelStore.verify(path, model: model))
    }

    func testExternalCaptionEditInvalidatesSavedBaseline() throws {
        let image = try jpeg(in: folder())
        try MetadataWriter.apply(ResolvedMetadataChanges(description: "Original\nMemo",
            existingFieldPolicy: .overwrite, descriptionBaseline: "Original"), to: image)
        var metadata = try ImageMetadata.read(from: image)
        try metadata.iptc.setValue("External edit", for: .captionAbstract)
        metadata.xmp?.description = "External edit"
        try metadata.write(to: image)
        XCTAssertEqual(try MetadataWriter.descriptionForTemplate(at: image, relativePath: image.lastPathComponent), "External edit")
        try metadata.iptc.setValue("Conflicting IPTC", for: .captionAbstract)
        try metadata.write(to: image)
        XCTAssertNil(try MetadataWriter.descriptionForTemplate(at: image, relativePath: image.lastPathComponent))
    }

    func testBundledWhisperHelperLaunches() async throws {
        let executable = try XCTUnwrap(Bundle.main.url(forResource: "ffmpeg", withExtension: nil,
                                                       subdirectory: "WhisperRuntime"))
        let directory = try folder()
        let output = directory.appendingPathComponent("unused.txt")
        try Data().write(to: output)
        try await VoiceMemoTranscriptionService.run(executable: executable, directory: directory,
            arguments: ["-version"], output: output, timeout: .seconds(10))
    }

    func testProcessDeadlineStopsChildAndReturnsPromptly() async throws {
        let directory = try folder()
        let start = ContinuousClock.now
        do {
            try await VoiceMemoTranscriptionService.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                directory: directory, arguments: ["20"], output: directory.appendingPathComponent("unused.txt"),
                timeout: .milliseconds(100))
            XCTFail("A stalled child must time out")
        } catch is VoiceMemoError {
            XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        }
    }

    func testTranscriptionFailureAndCancellationDoNotBecomeCaptionText() async throws {
        let directory = try folder()
        let image = try jpeg(in: directory)
        try Data([1]).write(to: directory.appendingPathComponent("photo.WAV"))
        let result = try await MetadataProcessingCoordinator.prepare(assignment: assignment(), geocoding: nil,
            services: .init(transcribeVoiceMemo: { _ in throw VoiceMemoError.unavailable("Model unavailable") }),
            fileURL: image, relativePath: image.lastPathComponent, processingDate: Date(),
            processingTimeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(result.changes.description, "")
        XCTAssertTrue(result.voiceMemoNote?.contains("Model unavailable") == true)
        do {
            _ = try await MetadataProcessingCoordinator.prepare(assignment: assignment(), geocoding: nil,
                services: .init(transcribeVoiceMemo: { _ in throw CancellationError() }),
                fileURL: image, relativePath: image.lastPathComponent, processingDate: Date(),
                processingTimeZone: TimeZone(secondsFromGMT: 0)!)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
