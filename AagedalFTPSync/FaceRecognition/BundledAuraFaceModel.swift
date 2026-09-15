import CryptoKit
import Foundation

/// Admits the single Core ML payload shipped with the app. Its weights must
/// match the reviewed AuraFace-v1 conversion; the application signature covers
/// the remaining compiled graph and this admission code in release builds.
enum BundledAuraFaceModel {
    static let resourceName = "AuraFaceR100"
    static let expectedWeightsSHA256 =
        "c189aaf7d6758dafb1603b4ea7f7c2161b69639434ddbce800e0cc632b26d7e0"

    enum Failure: Error, Equatable {
        case missingModel
        case invalidWeights
    }

    static func admit(from bundle: Bundle = .main) throws -> AuraFaceRecognitionRuntime {
        guard let modelURL = bundle.url(forResource: resourceName, withExtension: "mlmodelc"),
              modelURL.isFileURL else { throw Failure.missingModel }
        let weights = modelURL.appendingPathComponent("weights/weight.bin")
        guard try verifiedWeights(at: weights, within: modelURL) else {
            throw Failure.invalidWeights
        }
        return try AuraFaceRecognitionRuntime(
            compiledModelURL: modelURL,
            runtimeRevision: expectedWeightsSHA256
        )
    }

    static func verifiedWeights(at weights: URL, within model: URL) throws -> Bool {
        let files = FileManager.default
        let weightsDirectory = weights.deletingLastPathComponent()
        guard let modelValues = try? model.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              modelValues.isDirectory == true, modelValues.isSymbolicLink != true,
              let directoryValues = try? weightsDirectory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey
              ]),
              directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
              let weightValues = try? weights.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
              ]),
              weightValues.isRegularFile == true,
              weightValues.isSymbolicLink != true,
              let size = weightValues.fileSize,
              size > 100_000_000 && size < 200_000_000,
              weights.standardizedFileURL.path.hasPrefix(model.standardizedFileURL.path + "/"),
              weights.resolvingSymlinksInPath().path.hasPrefix(model.standardizedFileURL.path + "/"),
              files.fileExists(atPath: weights.path) else { return false }
        let handle = try FileHandle(forReadingFrom: weights)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == expectedWeightsSHA256
    }
}
