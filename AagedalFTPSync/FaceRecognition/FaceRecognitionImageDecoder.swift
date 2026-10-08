import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Query decoding only. RAW pixels come from the camera sensor decoder rather
/// than an embedded camera JPEG. This does not change reference-vector identity.
/// Apple RAW decoder versions are OS-dependent; diagnostic identities must also
/// include the OS build alongside queryPreprocessingRevision.
enum FaceRecognitionImageDecoder {
    static let maximumWorkingImageDimension = 4_096
    static let queryPreprocessingRevision = "photo-agent-eyes112-rgb-v3+apple-ciraw-sdr-srgb4096-v1"

    static func decode(imageURL: URL, source: CGImageSource) -> CGImage? {
        if usesRAWDecoder(source: source) { return decodeRAW(imageURL: imageURL, source: source) }
        return makeWorkingImage(from: source)
    }

    static func usesRAWDecoder(source: CGImageSource) -> Bool {
        isRAWTypeIdentifier(CGImageSourceGetType(source) as String?)
    }

    static func isRAWTypeIdentifier(_ identifier: String?) -> Bool {
        guard let identifier, let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// No ImageIO thumbnail fallback is allowed after RAW admission. Internal
    /// visibility supports malformed-input checks without private RAW fixtures.
    static func decodeRAW(imageURL: URL, source: CGImageSource? = nil) -> CGImage? {
        guard imageURL.isFileURL, let raw = CIRAWFilter(imageURL: imageURL),
              let nativeScale = scale(for: raw.nativeSize),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        raw.exposure = 0
        raw.extendedDynamicRangeAmount = 0
        raw.isDraftModeEnabled = false
        raw.linearSpaceFilter = nil
        raw.scaleFactor = Float(nativeScale)
        if let source {
            guard let orientation = CGImagePropertyOrientation(rawValue: orientationValue(in: source)) else { return nil }
            // CIRAWFilter performs orientation once. Do not add a transformed
            // ImageIO thumbnail or a second orientation to the decoded pixels.
            raw.orientation = orientation
        }
        guard var image = raw.outputImage, validExtent(image.extent),
              let outputScale = scale(for: image.extent.size) else { return nil }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Decoder rounding can exceed scaleFactor's requested cap slightly.
        if outputScale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: outputScale, y: outputScale)) }
        guard validExtent(image.extent) else { return nil }
        let width = min(maximumWorkingImageDimension, Int(image.extent.width.rounded(.down)))
        let height = min(maximumWorkingImageDimension, Int(image.extent.height.rounded(.down)))
        guard width > 0, height > 0 else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let result = context.createCGImage(image,
                from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace),
              result.width == width, result.height == height, result.bitsPerComponent == 8 else { return nil }
        return result
    }

    static func scale(for size: CGSize) -> CGFloat? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let value = min(1, CGFloat(maximumWorkingImageDimension) / max(size.width, size.height))
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func validExtent(_ extent: CGRect) -> Bool {
        !extent.isNull && !extent.isInfinite && extent.origin.x.isFinite && extent.origin.y.isFinite
            && scale(for: extent.size) != nil
    }

    // Preserve the established non-RAW ImageIO path and orientation helpers.
    private static func makeWorkingImage(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumWorkingImageDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return applyOrientation(to: image, value: orientationValue(in: source))
    }

    private static func orientedPixelWidth(from source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return [5, 6, 7, 8].contains(orientationValue(in: properties)) ? height : width
    }

    private static func orientationValue(in source: CGImageSource) -> UInt32 {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 1 }
        return orientationValue(in: properties)
    }

    private static func orientationValue(in properties: [CFString: Any]) -> UInt32 {
        func number(_ value: Any?) -> UInt32? { (value as? NSNumber)?.uint32Value }
        if let direct = number(properties[kCGImagePropertyOrientation]), direct != 1 { return direct }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = number(tiff[kCGImagePropertyTIFFOrientation]), value != 1 { return value }
        if let heic = properties[kCGImagePropertyHEICSDictionary] as? [CFString: Any],
           let value = number(heic[kCGImagePropertyOrientation]) { return value }
        return 1
    }

    private static func applyOrientation(to image: CGImage, value: UInt32) -> CGImage {
        guard value != 1 else { return image }
        let width = image.width
        let height = image.height
        var outputWidth = width
        var outputHeight = height
        var transform = CGAffineTransform.identity
        switch value {
        case 2:
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(width), y: 0)
        case 3:
            transform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case 4:
            transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height))
        case 5:
            outputWidth = height; outputHeight = width
            transform = CGAffineTransform(translationX: CGFloat(outputWidth), y: CGFloat(outputHeight))
                .rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case 6:
            outputWidth = height; outputHeight = width
            transform = CGAffineTransform(translationX: 0, y: CGFloat(outputHeight)).rotated(by: -.pi / 2)
        case 7:
            outputWidth = height; outputHeight = width
            transform = CGAffineTransform(rotationAngle: -.pi / 2).scaledBy(x: -1, y: 1)
                .translatedBy(x: -CGFloat(outputWidth), y: 0)
        case 8:
            outputWidth = height; outputHeight = width
            transform = CGAffineTransform(translationX: CGFloat(outputWidth), y: 0).rotated(by: .pi / 2)
        default:
            return image
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return image }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
