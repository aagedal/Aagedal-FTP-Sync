import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AagedalFTPSync

final class FaceRecognitionImageDecoderTests: XCTestCase {
    func testOrdinaryJPEGOrientationAndPixelsPreserveLegacyImageIOPath() throws {
        for orientation in 1...8 {
            let bytes = try jpeg(width: 192, height: 96, orientation: orientation)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let expected = try XCTUnwrap(legacyThumbnail(source))
            // The extension must not redirect JPEG content to the RAW decoder.
            let actual = try XCTUnwrap(FaceRecognitionImageDecoder.decode(
                imageURL: URL(fileURLWithPath: "/disposable/misleading.ARW"), source: source))
            XCTAssertFalse(FaceRecognitionImageDecoder.usesRAWDecoder(source: source))
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(try pixels(actual), try pixels(expected))
            XCTAssertEqual(actual.width, orientation >= 5 ? 96 : 192)
            XCTAssertEqual(actual.height, orientation >= 5 ? 192 : 96)
        }
    }

    func testOrdinaryJPEGDownsamplingPreservesLegacySizeAndPixels() throws {
        let bytes = try jpeg(width: 6_000, height: 80, orientation: 6)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let expected = try XCTUnwrap(legacyThumbnail(source))
        let actual = try XCTUnwrap(FaceRecognitionImageDecoder.decode(
            imageURL: URL(fileURLWithPath: "/disposable/large.jpg"), source: source))
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        XCTAssertEqual(max(actual.width, actual.height), 4_096)
        XCTAssertEqual(try pixels(actual), try pixels(expected))
    }

    func testRAWClassificationUsesContentTypeAndInvalidRAWCannotFallBack() throws {
        XCTAssertTrue(FaceRecognitionImageDecoder.isRAWTypeIdentifier(UTType.rawImage.identifier))
        XCTAssertFalse(FaceRecognitionImageDecoder.isRAWTypeIdentifier(UTType.jpeg.identifier))
        XCTAssertFalse(FaceRecognitionImageDecoder.isRAWTypeIdentifier(UTType.heic.identifier))
        XCTAssertFalse(FaceRecognitionImageDecoder.isRAWTypeIdentifier(nil))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-raw-\(UUID()).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Not a camera RAW payload".utf8).write(to: url)
        XCTAssertNil(FaceRecognitionImageDecoder.decodeRAW(imageURL: url))
        XCTAssertNil(FaceRecognitionImageDecoder.decodeRAW(imageURL: URL(fileURLWithPath: "/nonexistent/raw.ARW")))
    }

    func testRAWScaleRejectsInvalidBoundsAndCapsWithoutUpscaling() throws {
        for size in [CGSize.zero, CGSize(width: -1, height: 20), CGSize(width: 20, height: 0),
                     CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan)] {
            XCTAssertNil(FaceRecognitionImageDecoder.scale(for: size))
        }
        XCTAssertEqual(try XCTUnwrap(FaceRecognitionImageDecoder.scale(for: .init(width: 800, height: 600))), 1)
        let scale = try XCTUnwrap(FaceRecognitionImageDecoder.scale(for: .init(width: 8_192, height: 5_464)))
        XCTAssertEqual(scale, 0.5)
        XCTAssertEqual(8_192 * scale, 4_096)
    }

    private func legacyThumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private func jpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.65, blue: 0.30, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.10, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 3, height: height / 2))
        let image = try XCTUnwrap(context.makeImage()), bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
