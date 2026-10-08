import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AagedalFTPSync

/// Private operator fixtures and all observations stay in the ignored build tree.
/// This scan supplies diagnostic crops for subsequent visual labels; it is not accuracy evidence.
final class AuthorizedFaceEvaluationTests: XCTestCase {
    private struct Manifest: Decodable {
        let mode: String
        let files: [String]
        let outputRoot: String
        let maximumFaces: Int?
        let retainWorkingImages: Bool?
    }
    private struct Face: Codable {
        let ordinal: Int
        let embedding: [Float]
        let captureQuality: Double?
        let boundingBox: [Double]
        let diagnosticCrop: String
        let diagnosticCropSHA256: String
    }
    private struct Scan: Codable {
        let boundingBoxSource: String
        let schemaVersion: Int
        let modelID: String
        let preprocessingRevision: String
        let embeddingSpaceVersion: Int
        let runtimeRevision: String
        let modelRevision: String
        let queryPreprocessingRevision: String
        let index: Int
        let sourcePath: String
        let sourceSHA256: String?
        let elapsedSeconds: Double
        let inferenceSeconds: Double?
        let faces: [Face]
        let failure: String?
    }
    private struct Summary: Codable {
        let schemaVersion: Int
        let mode: String
        let modelID: String
        let preprocessingRevision: String
        let embeddingSpaceVersion: Int
        let runtimeRevision: String
        let modelRevision: String
        let queryPreprocessingRevision: String
        let filesCompleted: Int
        let failedFiles: Int
        let detectedFaces: Int
        let modelAdmissionSeconds: Double
        let elapsedSeconds: Double
        let accuracyEvaluated: Bool
    }
    private enum Failure: Error {
        case invalidManifest, unsafeOutput, unreadableImage, invalidBoundingBox
        case originalChanged, invalidEmbedding, cropEncoding
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    func testOptInAuthorizedFaceScan() async throws {
        guard let path = ProcessInfo.processInfo.environment["AAGEDAL_FACE_EVALUATION_MANIFEST"] else {
            throw XCTSkip("Set AAGEDAL_FACE_EVALUATION_MANIFEST for private face diagnostics")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard manifest.mode == "scan", !manifest.files.isEmpty,
              manifest.files.allSatisfy({ $0.hasPrefix("/") }), manifest.outputRoot.hasPrefix("/"),
              (1...512).contains(manifest.maximumFaces ?? 64) else { throw Failure.invalidManifest }
        let root = URL(fileURLWithPath: manifest.outputRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let ignoredBuild = checkout.appendingPathComponent("build", isDirectory: true).standardizedFileURL
        guard ignoredBuild.path == ignoredBuild.resolvingSymlinksInPath().path,
              root.path.hasPrefix(ignoredBuild.path + "/"),
              !FileManager.default.fileExists(atPath: root.path) else { throw Failure.unsafeOutput }
        let inputs = manifest.files.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        guard Set(inputs.map(\.path)).count == inputs.count,
              inputs.allSatisfy({ !$0.path.hasPrefix(root.path + "/") && $0.path != root.path }) else {
            throw Failure.unsafeOutput
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let started = Date()
        let admittedAt = Date()
        let runtime = try BundledAuraFaceModel.admit()
        let admissionSeconds = Date().timeIntervalSince(admittedAt)
        var failures = 0, faceCount = 0
        for (index, input) in inputs.enumerated() {
            let begin = Date()
            var before: String?
            var inferenceSeconds: Double?
            var records: [Face] = []
            var failure: String?
            do {
                before = try digest(input)
                let inferenceStart = Date()
                let observations = try await runtime.analyze(imageURL: input, maximumFaces: manifest.maximumFaces ?? 64)
                inferenceSeconds = Date().timeIntervalSince(inferenceStart)
                guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                      let image = FaceRecognitionImageDecoder.decode(imageURL: input, source: source) else { throw Failure.unreadableImage }
                if manifest.retainWorkingImages == true {
                    let output = root.appendingPathComponent(String(format: "working-image-%05d.jpg", index))
                    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                        throw Failure.cropEncoding
                    }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw Failure.cropEncoding }
                }
                guard observations.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else {
                    throw Failure.invalidBoundingBox
                }
                for observation in observations {
                    guard observation.embedding.values.allSatisfy(\.isFinite) else { throw Failure.invalidEmbedding }
                    guard let box = observation.normalizedBoundingBox else { throw Failure.invalidBoundingBox }
                    let visible = try Self.visibleBoundingBox(box)
                    let pixelRect = CGRect(x: visible.minX * CGFloat(image.width),
                        y: (1 - visible.maxY) * CGFloat(image.height),
                        width: visible.width * CGFloat(image.width), height: visible.height * CGFloat(image.height)).integral
                    guard let crop = image.cropping(to: pixelRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else {
                        throw Failure.unreadableImage
                    }
                    let filename = String(format: "image-%05d-face-%03d.jpg", index, observation.ordinal)
                    let bytes = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
                        throw Failure.cropEncoding
                    }
                    CGImageDestinationAddImage(destination, crop, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw Failure.cropEncoding }
                    try (bytes as Data).write(to: root.appendingPathComponent(filename), options: .atomic)
                    records.append(Face(ordinal: observation.ordinal, embedding: observation.embedding.values,
                        captureQuality: observation.captureQuality,
                        boundingBox: [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)],
                        diagnosticCrop: filename, diagnosticCropSHA256: try digest(root.appendingPathComponent(filename))))
                }
                guard try digest(input) == before else { throw Failure.originalChanged }
            } catch {
                failure = String(describing: error)
                failures += 1
                // Even an inference/decode failure must leave the authorized input untouched.
                if let before, (try? digest(input)) != before { failure = "originalChanged; " + (failure ?? "") }
            }
            faceCount += records.count
            try write(Scan(boundingBoxSource: "production-analysis", schemaVersion: 1, modelID: runtime.modelID,
                preprocessingRevision: runtime.preprocessingRevision, embeddingSpaceVersion: runtime.embeddingSpaceVersion,
                runtimeRevision: runtime.runtimeRevision, modelRevision: runtime.modelRevision,
                queryPreprocessingRevision: runtime.queryPreprocessingRevision, index: index, sourcePath: input.path, sourceSHA256: before,
                elapsedSeconds: Date().timeIntervalSince(begin), inferenceSeconds: inferenceSeconds, faces: records, failure: failure),
                to: root.appendingPathComponent(String(format: "image-%05d.json", index)))
            try write(Summary(schemaVersion: 1, mode: "scan", modelID: runtime.modelID,
                preprocessingRevision: runtime.preprocessingRevision, embeddingSpaceVersion: runtime.embeddingSpaceVersion,
                runtimeRevision: runtime.runtimeRevision, modelRevision: runtime.modelRevision,
                queryPreprocessingRevision: runtime.queryPreprocessingRevision, filesCompleted: index + 1, failedFiles: failures,
                detectedFaces: faceCount, modelAdmissionSeconds: admissionSeconds,
                elapsedSeconds: Date().timeIntervalSince(started), accuracyEvaluated: false),
                to: root.appendingPathComponent("summary.json"))
            print("AUTHORIZED_FACE_SCAN_PROGRESS completed=\(index + 1) faces=\(faceCount) failed=\(failures)")
        }
        XCTAssertEqual(failures, 0, "Inspect ignored per-image diagnostic failures before labeling")
    }

    /// Vision may place part of a detected face beyond the frame. Preserve its
    /// authoritative box in JSON and clip only the display crop to visible pixels.
    private static func visibleBoundingBox(_ box: CGRect) throws -> CGRect {
        guard [box.origin.x, box.origin.y, box.size.width, box.size.height, box.maxX, box.maxY].allSatisfy(\.isFinite),
              box.size.width > 0, box.size.height > 0 else { throw Failure.invalidBoundingBox }
        let visible = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visible.isNull, !visible.isEmpty, visible.width > 0, visible.height > 0 else {
            throw Failure.invalidBoundingBox
        }
        return visible
    }

    func testDiagnosticCropClipsAuthoritativeBoxAtFrameEdges() throws {
        let box = CGRect(x: -0.2, y: 0.8, width: 0.5, height: 0.4)
        let visible = try Self.visibleBoundingBox(box)
        XCTAssertEqual(visible.minX, 0, accuracy: 0.000001)
        XCTAssertEqual(visible.minY, 0.8, accuracy: 0.000001)
        XCTAssertEqual(visible.width, 0.3, accuracy: 0.000001)
        XCTAssertEqual(visible.height, 0.2, accuracy: 0.000001)
        XCTAssertEqual(try Self.visibleBoundingBox(CGRect(x: -1, y: -1, width: 3, height: 3)),
                       CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(box.origin.x, -0.2) // Validation does not replace the recorded box.
    }

    func testDiagnosticCropRejectsInvisibleAndInvalidBoxes() {
        for box in [CGRect(x: 1, y: 0, width: 0.2, height: 0.2),
                    CGRect(x: -0.4, y: 0, width: 0.2, height: 0.2),
                    CGRect(x: 0, y: 0, width: 0, height: 0.2),
                    CGRect(x: 0, y: 0, width: -0.2, height: 0.2),
                    CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.2),
                    CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 0.2)] {
            XCTAssertThrowsError(try Self.visibleBoundingBox(box))
        }
    }

}
