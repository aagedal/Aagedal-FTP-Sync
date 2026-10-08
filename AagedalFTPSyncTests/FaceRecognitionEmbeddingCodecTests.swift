import Foundation
import XCTest
@testable import AagedalFTPSync

final class FaceRecognitionEmbeddingCodecTests: XCTestCase {
    /// Construct independently of the production encoder. Header bytes are NOT
    /// ASCII "FEM2": Photo Agent writes the integer 0x46454D32 little-endian.
    private func fixture(first: [UInt8] = [0, 0, 128, 63]) -> Data {
        Data([0x32, 0x4D, 0x45, 0x46, 0, 2, 0, 0] + first + Array(repeating: 0, count: 511 * 4))
    }

    func testPinnedLittleEndianFixtureAndEncoding() throws {
        let data = fixture()
        let embedding = try FaceRecognitionEmbeddingCodec.decode(data)
        XCTAssertEqual(embedding.values.count, 512)
        XCTAssertEqual(embedding.values[0], 1)
        XCTAssertTrue(embedding.values.dropFirst().allSatisfy { $0 == 0 })
        XCTAssertEqual(FaceRecognitionEmbeddingCodec.encode(embedding), data)
    }

    func testRejectsTruncationTrailingBytesAndUntrustedCount() {
        XCTAssertThrowsError(try FaceRecognitionEmbeddingCodec.decode(Data()))
        XCTAssertThrowsError(try FaceRecognitionEmbeddingCodec.decode(fixture().dropLast()))
        XCTAssertThrowsError(try FaceRecognitionEmbeddingCodec.decode(fixture() + Data([0])))
        var data = fixture()
        data.replaceSubrange(4..<8, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try FaceRecognitionEmbeddingCodec.decode(data))
        data.replaceSubrange(4..<8, with: [0, 0, 2, 0]) // big-endian count
        XCTAssertThrowsError(try FaceRecognitionEmbeddingCodec.decode(data))
    }

    func testRejectsLegacyMagicAndInvalidNumbers() {
        var asciiMagic = fixture()
        asciiMagic.replaceSubrange(0..<4, with: Array("FEM2".utf8))
        XCTAssertThrowsError(try FaceRecognitionEmbeddingCodec.decode(asciiMagic))
        let invalidValues: [[UInt8]] = [
            [0, 0, 0, 0],       // zero norm
            [0, 0, 0, 64],      // unnormalized 2.0
            [0, 0, 128, 127],   // infinity
            [0, 0, 192, 127],   // NaN
        ]
        for first in invalidValues {
            XCTAssertThrowsError(try FaceRecognitionEmbeddingCodec.decode(fixture(first: first)))
        }
    }

    func testUnalignedDataSliceDecodesWithoutNativeAlignmentAssumptions() throws {
        let padded = Data([42]) + fixture()
        let sliced = padded.dropFirst()
        XCTAssertEqual(try FaceRecognitionEmbeddingCodec.decode(sliced).values[0], 1)
    }
}
