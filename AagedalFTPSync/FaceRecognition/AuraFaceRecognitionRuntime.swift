import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// The admitted, in-memory AuraFace inference runtime. The installer constructs
/// this value only while holding its component lock and after revalidating the
/// signed descriptor, package hashes, and compiled-model directory. Loading the
/// `MLModel` before releasing that lock makes an operation independent of a
/// later component update or removal.
///
/// The image pipeline is derived from Aagedal Photo Agent's GPL-3.0 face
/// pipeline at revision 78f0209, reduced to decode, detection, alignment, and
/// embedding. It deliberately excludes clustering, thumbnails, and editor data.
final class AuraFaceRecognitionRuntime: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case incompatibleIdentity
        case incompatibleModelInterface
        case unreadableImage
        case invalidModelInput
        case invalidModelOutput
    }

    static let modelID = "AuraFace-v1/glintr100"
    static let preprocessingRevision = "photo-agent-eyes112-rgb-v3"
    static let embeddingSpaceVersion = 3
    static let maximumWorkingImageDimension = 4_096
    static let minimumDetectionConfidence: VNConfidence = 0.7
    static let minimumOriginalFaceWidth = 50

    let componentID: String
    let modelID: String
    let preprocessingRevision: String
    let embeddingSpaceVersion: Int
    let runtimeRevision: String

    private let model: MLModel

    init(
        admittedDescriptor descriptor: AuraFaceDistributionDescriptor,
        compiledModelURL: URL,
        runtimeRevision: String
    ) throws {
        try Self.validateIdentity(descriptor)
        guard runtimeRevision.utf8.count == 64,
              runtimeRevision.utf8.allSatisfy({
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
              }) else { throw Failure.incompatibleIdentity }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        } catch {
            throw Failure.incompatibleModelInterface
        }
        try Self.validateInterface(loaded.modelDescription)

        componentID = descriptor.componentID
        modelID = descriptor.modelVersion
        preprocessingRevision = Self.preprocessingRevision
        embeddingSpaceVersion = descriptor.embeddingVersion
        self.runtimeRevision = runtimeRevision
        model = loaded
    }

    static func validateIdentity(_ descriptor: AuraFaceDistributionDescriptor) throws {
        guard descriptor.componentID == PeopleLibraryManifest.EmbeddingContract.auraFaceV1.componentID,
              descriptor.modelVersion == PeopleLibraryManifest.EmbeddingContract.auraFaceV1.modelID,
              descriptor.embeddingVersion == PeopleLibraryManifest.EmbeddingContract.auraFaceV1.embeddingSpaceVersion,
              Self.preprocessingRevision == PeopleLibraryManifest.EmbeddingContract.auraFaceV1.preprocessingRevision
        else { throw Failure.incompatibleIdentity }
    }

    private static func validateInterface(_ description: MLModelDescription) throws {
        guard Set(description.inputDescriptionsByName.keys) == ["input"],
              let input = description.inputDescriptionsByName["input"],
              input.type == .multiArray,
              let inputConstraint = input.multiArrayConstraint,
              inputConstraint.dataType == .float32,
              inputConstraint.shape.map(\.intValue) == [1, 3, 112, 112],
              Set(description.outputDescriptionsByName.keys) == ["embedding"],
              let output = description.outputDescriptionsByName["embedding"],
              output.type == .multiArray,
              let outputConstraint = output.multiArrayConstraint,
              outputConstraint.dataType == .float16 || outputConstraint.dataType == .float32,
              outputConstraint.shape.map(\.intValue).reduce(1, *) == FaceRecognitionEmbedding.dimension
        else { throw Failure.incompatibleModelInterface }
    }

    func analyze(imageURL: URL, maximumFaces: Int) async throws
        -> [FaceRecognitionAnalysisObservation] {
        try Task.checkCancellation()
        guard maximumFaces > 0,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = Self.makeWorkingImage(from: source)
        else { throw Failure.unreadableImage }

        let originalWidth = Self.orientedPixelWidth(from: source) ?? image.width
        let detected = try Self.detectFaces(in: image)
            .filter {
                $0.confidence >= Self.minimumDetectionConfidence
                    && Int($0.boundingBox.width * CGFloat(originalWidth)) >= Self.minimumOriginalFaceWidth
            }
            .sorted(by: Self.precedes)
        guard detected.count <= maximumFaces else {
            throw FaceRecognitionAnalysisError.faceLimitExceeded(
                maximum: maximumFaces,
                actual: detected.count
            )
        }

        let qualities = Self.captureQualities(for: detected, in: image)
        var observations: [FaceRecognitionAnalysisObservation] = []
        observations.reserveCapacity(detected.count)
        for (ordinal, face) in detected.enumerated() {
            try Task.checkCancellation()
            guard let fallback = Self.cropFace(
                from: image,
                normalizedRect: Self.expanded(face.boundingBox, by: 0.15)
            ) else { throw Failure.unreadableImage }

            var modelInput = fallback
            if let eyes = Self.eyeCenters(from: face) {
                let preCropRect = Self.expanded(face.boundingBox, by: 2)
                if let preCrop = Self.cropFace(from: image, normalizedRect: preCropRect) {
                    let width = CGFloat(image.width)
                    let height = CGFloat(image.height)
                    let first = CGPoint(
                        x: (eyes.0.x - preCropRect.minX) * width,
                        y: (eyes.0.y - preCropRect.minY) * height
                    )
                    let second = CGPoint(
                        x: (eyes.1.x - preCropRect.minX) * width,
                        y: (eyes.1.y - preCropRect.minY) * height
                    )
                    if hypot(second.x - first.x, second.y - first.y) >= 20,
                       let aligned = Self.arcFaceAlignedCrop(
                           from: preCrop,
                           firstEye: first,
                           secondEye: second
                       ) {
                        modelInput = aligned
                    }
                }
            }

            let embedding = try await embedding(from: modelInput)
            try Task.checkCancellation()
            observations.append(.init(
                ordinal: ordinal,
                embedding: embedding,
                captureQuality: qualities[face.uuid].map(Double.init)
            ))
        }
        return observations
    }

    /// Internal visibility supports an opt-in reference-vector check against an
    /// operator-supplied, hash-pinned model without bundling that large model.
    func embedding(from image: CGImage) async throws -> FaceRecognitionEmbedding {
        let input = try Self.makeInput(from: image)
        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: input),
            ])
        } catch {
            throw Failure.invalidModelInput
        }
        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.invalidModelOutput
        }
        guard let array = prediction.featureValue(for: "embedding")?.multiArrayValue,
              array.count == FaceRecognitionEmbedding.dimension else {
            throw Failure.invalidModelOutput
        }
        let values = (0..<array.count).map { array[$0].floatValue }
        do {
            return try FaceRecognitionEmbedding(normalizing: values)
        } catch {
            throw Failure.invalidModelOutput
        }
    }

    /// Exact production RGB preprocessing, exposed internally so a compact
    /// channel-asymmetric fixture can guard the contract without shipping the
    /// optional model in the application or test bundle.
    static func makeInput(from image: CGImage) throws -> MLMultiArray {
        let size = 112
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.invalidModelInput
        }
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn,
              let array = try? MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32)
        else { throw Failure.invalidModelInput }

        let output = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        let plane = size * size
        for pixel in 0..<plane {
            let source = pixel * 4
            output[pixel] = (Float(pixels[source]) - 127.5) / 127.5
            output[plane + pixel] = (Float(pixels[source + 1]) - 127.5) / 127.5
            output[2 * plane + pixel] = (Float(pixels[source + 2]) - 127.5) / 127.5
        }
        return array
    }

    private static func detectFaces(in image: CGImage) throws -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    private static func captureQualities(
        for faces: [VNFaceObservation],
        in image: CGImage
    ) -> [UUID: VNConfidence] {
        guard !faces.isEmpty else { return [:] }
        let request = VNDetectFaceCaptureQualityRequest()
        request.inputFaceObservations = faces
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [:] }
        return Dictionary(uniqueKeysWithValues: (request.results ?? []).compactMap {
            guard let quality = $0.faceCaptureQuality else { return nil }
            return ($0.uuid, quality)
        })
    }

    private static func precedes(_ lhs: VNFaceObservation, _ rhs: VNFaceObservation) -> Bool {
        let left = lhs.boundingBox
        let right = rhs.boundingBox
        if left.maxY != right.maxY { return left.maxY > right.maxY }
        if left.minX != right.minX { return left.minX < right.minX }
        if left.width != right.width { return left.width > right.width }
        return left.height > right.height
    }

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

    private static func expanded(_ rectangle: CGRect, by factor: CGFloat) -> CGRect {
        let width = rectangle.width * factor
        let height = rectangle.height * factor
        let x = max(0, rectangle.minX - width / 2)
        let y = max(0, rectangle.minY - height / 2)
        return CGRect(
            x: x,
            y: y,
            width: min(rectangle.width + width, 1 - x),
            height: min(rectangle.height + height, 1 - y)
        )
    }

    private static func cropFace(from image: CGImage, normalizedRect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return image.cropping(to: CGRect(
            x: normalizedRect.minX * width,
            y: (1 - normalizedRect.maxY) * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        ))
    }

    private static func eyeCenters(from face: VNFaceObservation) -> (CGPoint, CGPoint)? {
        guard let left = face.landmarks?.leftEye?.normalizedPoints,
              let right = face.landmarks?.rightEye?.normalizedPoints,
              !left.isEmpty,
              !right.isEmpty else { return nil }
        func center(_ points: [CGPoint]) -> CGPoint {
            let sum = points.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
            }
            return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
        }
        let box = face.boundingBox
        func projected(_ point: CGPoint) -> CGPoint {
            CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
        }
        return (projected(center(left)), projected(center(right)))
    }

    private static func arcFaceAlignedCrop(
        from image: CGImage,
        firstEye: CGPoint,
        secondEye: CGPoint
    ) -> CGImage? {
        let imageLeft = firstEye.x <= secondEye.x ? firstEye : secondEye
        let imageRight = firstEye.x <= secondEye.x ? secondEye : firstEye
        let templateLeft = CGPoint(x: 38.2946, y: 112 - 51.6963)
        let templateRight = CGPoint(x: 73.5318, y: 112 - 51.5014)
        let sourceDelta = CGPoint(x: imageRight.x - imageLeft.x, y: imageRight.y - imageLeft.y)
        let targetDelta = CGPoint(x: templateRight.x - templateLeft.x, y: templateRight.y - templateLeft.y)
        let sourceDistance = hypot(sourceDelta.x, sourceDelta.y)
        guard sourceDistance > 0 else { return nil }
        let scale = hypot(targetDelta.x, targetDelta.y) / sourceDistance
        let rotation = atan2(targetDelta.y, targetDelta.x) - atan2(sourceDelta.y, sourceDelta.x)
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: templateLeft.x, y: templateLeft.y)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.rotated(by: rotation)
        transform = transform.translatedBy(x: -imageLeft.x, y: -imageLeft.y)

        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 112,
            height: 112,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
