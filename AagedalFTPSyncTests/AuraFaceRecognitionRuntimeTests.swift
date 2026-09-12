import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import AagedalFTPSync

final class AuraFaceRecognitionRuntimeTests: XCTestCase {
    func testProductionInputPackingUsesRGBNCHWNormalization() throws {
        let width = 112
        let height = 112
        let rgb = Data((0..<(width * height)).flatMap { pixel -> [UInt8] in
            // Spatially asymmetric values also catch accidental plane overlap.
            [UInt8(pixel % 251), UInt8((pixel * 3 + 17) % 251), UInt8((pixel * 7 + 41) % 251)]
        })
        let provider = try XCTUnwrap(CGDataProvider(data: rgb as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let input = try AuraFaceRecognitionRuntime.makeInput(from: image)
        XCTAssertEqual(input.shape.map(\.intValue), [1, 3, 112, 112])
        let plane = width * height
        for pixel in [0, 1, 173, plane - 1] {
            for channel in 0..<3 {
                let expected = (Float(rgb[pixel * 3 + channel]) - 127.5) / 127.5
                XCTAssertEqual(input[channel * plane + pixel].floatValue, expected, accuracy: 0.000_001)
            }
        }
    }

    func testRuntimeIdentityMatchesPeopleLibraryContractExactly() throws {
        let descriptor = makeDescriptor()
        XCTAssertNoThrow(try AuraFaceRecognitionRuntime.validateIdentity(descriptor))

        let wrongModel = makeDescriptor(modelVersion: "AuraFace-v1/other")
        XCTAssertThrowsError(try AuraFaceRecognitionRuntime.validateIdentity(wrongModel)) {
            XCTAssertEqual($0 as? AuraFaceRecognitionRuntime.Failure, .incompatibleIdentity)
        }

        let wrongEmbedding = makeDescriptor(embeddingVersion: 4)
        XCTAssertThrowsError(try AuraFaceRecognitionRuntime.validateIdentity(wrongEmbedding)) {
            XCTAssertEqual($0 as? AuraFaceRecognitionRuntime.Failure, .incompatibleIdentity)
        }
    }

    func testAnalysisServiceKeepsTypedRuntimeResourceRejection() async throws {
        let service = FaceRecognitionAnalysisService { _, _ in
            throw FaceRecognitionAnalysisError.faceLimitExceeded(maximum: 2, actual: 3)
        }
        let result = await service.analyze(
            stagedInput: FaceRecognitionStagedInputLease(
                imageURL: URL(fileURLWithPath: "/fixture.jpg"),
                exactByteCount: 1
            ),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try FaceRecognitionAcceptancePolicy(
                maximumCosineDistance: 0.2,
                minimumRunnerUpGap: 0.1,
                minimumCaptureQuality: 0.5,
                unavailableQualityPolicy: .reject
            )
        )
        XCTAssertEqual(result, .rejected(.faceLimitExceeded(maximum: 2, actual: 3)))
    }

    func testOptInPinnedModelMatchesCompanionRGBReferenceAndBGRNegative() async throws {
        struct Reference: Decodable {
            let bgrMaximumCosineSimilarityToRGB: Double
            let embeddingDimension: Int
            let fixtureDecodedSHA256: String
            let modelFileSHA256: String
            let referenceEncoding: String
            let rgbMinimumCosineSimilarity: Double
            let rgbNormalizedEmbedding: String
            let schemaVersion: Int
        }

        let environment = ProcessInfo.processInfo.environment
        guard let packagePath = environment["AAGEDAL_AURAFACE_PACKAGE"],
              let fixturePath = environment["AAGEDAL_AURAFACE_CHANNEL_FIXTURE"],
              let referencePath = environment["AAGEDAL_AURAFACE_CHANNEL_REFERENCE"]
        else { throw XCTSkip("Set the three AAGEDAL_AURAFACE_* paths for the optional real-model contract check.") }

        let package = URL(fileURLWithPath: packagePath)
        let reference = try JSONDecoder().decode(
            Reference.self,
            from: Data(contentsOf: URL(fileURLWithPath: referencePath))
        )
        let modelFile = package.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        XCTAssertEqual(sha256(try Data(contentsOf: modelFile)), reference.modelFileSHA256)
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let runtime = try AuraFaceRecognitionRuntime(
            admittedDescriptor: makeDescriptor(),
            compiledModelURL: compiled,
            runtimeRevision: String(repeating: "0", count: 64)
        )

        XCTAssertEqual(reference.schemaVersion, 1)
        XCTAssertEqual(reference.embeddingDimension, FaceRecognitionEmbedding.dimension)
        XCTAssertEqual(
            reference.referenceEncoding,
            "base64(float32 little-endian normalized embedding)"
        )
        let encodedFixture = try String(
            contentsOf: URL(fileURLWithPath: fixturePath),
            encoding: .utf8
        ).components(separatedBy: .whitespacesAndNewlines).joined()
        let ppm = try XCTUnwrap(Data(base64Encoded: encodedFixture))
        XCTAssertEqual(sha256(ppm), reference.fixtureDecodedSHA256)
        let header = Data("P6\n112 112\n255\n".utf8)
        guard ppm.starts(with: header) else { return XCTFail("Unexpected PPM fixture header") }
        let rgb = Data(ppm.dropFirst(header.count))
        let expectedBytes = try XCTUnwrap(Data(base64Encoded: reference.rgbNormalizedEmbedding))
        XCTAssertEqual(expectedBytes.count, reference.embeddingDimension * MemoryLayout<UInt32>.size)
        let expected = expectedBytes.withUnsafeBytes { raw in
            (0..<FaceRecognitionEmbedding.dimension).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )))
            }
        }
        let actual = try await runtime.embedding(from: try image(rgb: rgb))
        var bgr = rgb
        bgr.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 3) {
                let red = bytes[offset]
                bytes[offset] = bytes[offset + 2]
                bytes[offset + 2] = red
            }
        }
        let negative = try await runtime.embedding(from: try image(rgb: bgr))
        XCTAssertGreaterThanOrEqual(cosine(actual.values, expected), reference.rgbMinimumCosineSimilarity)
        XCTAssertLessThanOrEqual(cosine(negative.values, expected), reference.bgrMaximumCosineSimilarityToRGB)
    }

    private func makeDescriptor(
        modelVersion: String = AuraFaceRecognitionRuntime.modelID,
        embeddingVersion: Int = AuraFaceRecognitionRuntime.embeddingSpaceVersion
    ) -> AuraFaceDistributionDescriptor {
        AuraFaceDistributionDescriptor(
            schemaVersion: 2,
            componentID: AuraFaceDistributionContract.componentID,
            modelVersion: modelVersion,
            embeddingVersion: embeddingVersion,
            packageDirectory: AuraFaceDistributionContract.packageDirectory,
            packageFiles: [:],
            archive: .init(fileName: AuraFaceDistributionContract.archiveFile, byteCount: 1,
                           sha256: String(repeating: "0", count: 64)),
            downloadURL: URL(string: "https://models.invalid/AuraFaceR100.mlpackage.zip")!
        )
    }

    private func image(rgb: Data) throws -> CGImage {
        XCTAssertEqual(rgb.count, 112 * 112 * 3)
        let provider = try XCTUnwrap(CGDataProvider(data: rgb as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(
            width: 112,
            height: 112,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: 112 * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let left = lhs.reduce(0.0) { $0 + Double($1) * Double($1) }
        let right = rhs.reduce(0.0) { $0 + Double($1) * Double($1) }
        return dot / sqrt(left * right)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
