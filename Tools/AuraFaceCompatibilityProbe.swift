// Local artifact/interface probe only. No downloads or private photo/library access.
// Compile: xcrun swiftc -target arm64-apple-macosx14.0 Tools/AuraFaceCompatibilityProbe.swift -o build/m0-face/probe
// Run with an external timeout: probe <Photo-Agent-checkout> <disposable-output-directory>
import Foundation
import CryptoKit
import CoreML

struct Descriptor: Decodable {
    struct Archive: Decodable { let fileName: String; let byteCount: Int; let sha256: String }
    let schemaVersion: Int
    let componentID: String
    let modelVersion: String
    let embeddingVersion: Int
    let packageDirectory: String
    let packageFiles: [String: String]
    let archive: Archive
    let downloadURL: URL
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure(message) }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func emit(_ event: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = try body()
    return (value, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
}

do {
    try require(CommandLine.arguments.count == 3, "Expected companion checkout and disposable output directory")
    let companion = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let fm = FileManager.default
    try require(!fm.fileExists(atPath: destination.path), "Output directory must not already exist")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let distribution = companion.appendingPathComponent("build/auraface", isDirectory: true)
    let descriptorBytes = try Data(contentsOf: distribution.appendingPathComponent("AuraFaceR100.distribution.json"))
    let signatureText = try String(contentsOf: distribution.appendingPathComponent("AuraFaceR100.distribution.json.sig"), encoding: .utf8)
    let plistBytes = try Data(contentsOf: companion.appendingPathComponent("Aagedal Photo Agent/Info.plist"))
    let plist = try PropertyListSerialization.propertyList(from: plistBytes, format: nil) as? [String: Any]
    guard let publicKeyText = plist?["SUPublicEDKey"] as? String,
          let publicKeyBytes = Data(base64Encoded: publicKeyText), publicKeyBytes.count == 32,
          let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64 else {
        throw ProbeFailure("Invalid public key/signature encoding")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
    try require(publicKey.isValidSignature(signature, for: descriptorBytes), "Descriptor Ed25519 signature failed")
    let descriptor = try JSONDecoder().decode(Descriptor.self, from: descriptorBytes)
    let expectedFiles: Set<String> = ["Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin", "Manifest.json"]
    try require(descriptor.schemaVersion == 1 && descriptor.componentID == "auraface-r100-coreml" && descriptor.modelVersion == "AuraFace-v1/glintr100" && descriptor.embeddingVersion == 3, "Unexpected model/space/schema identity")
    try require(descriptor.packageDirectory == "AuraFaceR100.mlpackage" && descriptor.archive.fileName == "AuraFaceR100.mlpackage.zip" && Set(descriptor.packageFiles.keys) == expectedFiles, "Unexpected package paths")
    let archive = distribution.appendingPathComponent(descriptor.archive.fileName)
    let archiveSize = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
    try require(archiveSize == descriptor.archive.byteCount && descriptor.archive.byteCount <= 500_000_000, "Archive size mismatch or limit exceeded")
    let archiveHash = try hashFile(archive)
    try require(archiveHash == descriptor.archive.sha256, "Archive SHA-256 mismatch")
    let package = companion.appendingPathComponent("Aagedal Photo Agent/Resources/Models").appendingPathComponent(descriptor.packageDirectory)
    guard let enumerator = fm.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else {
        throw ProbeFailure("Could not enumerate package")
    }
    var actualFiles = Set<String>()
    for case let file as URL in enumerator {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
        try require(values.isSymbolicLink != true, "Package contains symlink")
        if values.isDirectory == true { continue }
        try require(values.isRegularFile == true, "Package contains nonregular file")
        let prefix = package.path + "/"
        try require(file.path.hasPrefix(prefix), "Package path escaped root")
        let relative = String(file.path.dropFirst(prefix.count))
        actualFiles.insert(relative)
        guard let expectedHash = descriptor.packageFiles[relative] else { throw ProbeFailure("Unexpected package file: \(relative)") }
        try require(try hashFile(file) == expectedHash, "Package file SHA-256 mismatch: \(relative)")
    }
    try require(actualFiles == expectedFiles, "Missing package files")
    emit(["stage": "verified", "descriptorSHA256": sha256(descriptorBytes), "publicKeySHA256": sha256(publicKeyBytes), "archiveSHA256": archiveHash, "archiveBytes": descriptor.archive.byteCount, "packageFiles": descriptor.packageFiles, "embeddingVersion": descriptor.embeddingVersion, "os": ProcessInfo.processInfo.operatingSystemVersionString])

    let (temporaryCompiled, compileMS) = try measure { try MLModel.compileModel(at: package) }
    let compiled = destination.appendingPathComponent("AuraFaceR100.mlmodelc", isDirectory: true)
    try fm.moveItem(at: temporaryCompiled, to: compiled)
    emit(["stage": "compiled", "milliseconds": compileMS])
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let (model, loadMS) = try measure { try MLModel(contentsOf: compiled, configuration: configuration) }
    let inputs = model.modelDescription.inputDescriptionsByName
    let outputs = model.modelDescription.outputDescriptionsByName
    guard let input = inputs["input"], let inputConstraint = input.multiArrayConstraint,
          let output = outputs["embedding"], let outputConstraint = output.multiArrayConstraint else {
        throw ProbeFailure("Missing input/output multiarray interface")
    }
    try require(Set(inputs.keys) == ["input"] && Set(outputs.keys) == ["embedding"], "Unexpected input/output names")
    try require(inputConstraint.shape.map(\.intValue) == [1, 3, 112, 112] && inputConstraint.dataType == .float32, "Incorrect model input shape/type")
    try require(outputConstraint.shape.map(\.intValue).reduce(1, *) == 512, "Incorrect model output dimension")
    emit(["stage": "loaded", "milliseconds": loadMS, "computeUnits": "all", "inputShape": inputConstraint.shape.map(\.intValue), "inputDataType": inputConstraint.dataType.rawValue, "outputShape": outputConstraint.shape.map(\.intValue), "outputDataType": outputConstraint.dataType.rawValue])
    let array = try MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32)
    // Deterministic synthetic normalized RGB ramp; it contains no person and cannot test identity accuracy.
    for index in 0..<array.count { array[index] = NSNumber(value: (Float((index * 37 + 11) % 256) - 127.5) / 127.5) }
    let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: array)])
    for iteration in 0..<3 {
        let (prediction, inferenceMS) = try measure { try model.prediction(from: provider) }
        guard let vector = prediction.featureValue(for: "embedding")?.multiArrayValue else { throw ProbeFailure("Missing output vector") }
        let values = (0..<vector.count).map { vector[$0].doubleValue }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        try require(values.count == 512 && values.allSatisfy(\.isFinite) && norm.isFinite && norm > 1e-12, "Output is not finite nonzero 512-vector")
        let normalizedNorm = sqrt(values.reduce(0) { $0 + ($1 / norm) * ($1 / norm) })
        emit(["stage": "inference", "iteration": iteration, "condition": iteration == 0 ? "first-prediction-after-load" : "warm", "milliseconds": inferenceMS, "count": values.count, "allFinite": true, "rawL2Norm": norm, "normalizedL2Norm": normalizedNorm])
    }
    emit(["stage": "complete", "accuracyValidated": false, "macOS14RuntimeValidated": false])
} catch {
    emit(["stage": "failed", "error": String(describing: error)])
    exit(1)
}
