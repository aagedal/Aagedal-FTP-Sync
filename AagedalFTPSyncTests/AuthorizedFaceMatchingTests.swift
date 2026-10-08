import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AagedalFTPSync

/// Operator labels are deliberately independent of model predictions. Keep the
/// manifest, scanner records and report beneath an ignored, disposable directory.
/// Xcode forwards TEST_RUNNER_AAGEDAL_FACE_MATCHING_MANIFEST to this environment key.
final class AuthorizedFaceMatchingTests: XCTestCase {
    func testOptInExportAuthorizedReferenceLibrary() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["AAGEDAL_FACE_MATCHING_MANIFEST"],
              let outputPath = environment["AAGEDAL_FACE_REFERENCE_OUTPUT"] else {
            throw XCTSkip("No private reference-library export requested")
        }
        guard let commit = environment["AAGEDAL_FACE_REFERENCE_SOURCE_COMMIT"] else {
            throw FaceEvaluation.Invalid("Reference export requires an actual source commit")
        }
        try FaceEvaluation.validateCommit(commit)
        let manifestURL = try FaceEvaluation.privateBuildURL(manifestPath)
        let manifestBytes = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FaceEvaluation.Manifest.self, from: manifestBytes)
        let loaded = try FaceEvaluation.load(manifest)
        let references = loaded.filter { $0.label.role == .reference }
        let output = try FaceEvaluation.privateBuildURL(outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw FaceEvaluation.Invalid("Reference export needs a fresh ignored output directory")
        }
        let source = output.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("embeddings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("upgrade_sources"), withIntermediateDirectories: true)
        var files: [PeopleLibraryManifest.FileDeclaration] = []
        var examples: [UUID: [PeopleLibraryPayload.Example]] = [:]
        var provenance: [FaceEvaluation.ReferenceProvenance] = []
        for row in references {
            let cropURL = try FaceEvaluation.reviewedCropURL(row)
            let (cropBytes, before) = try FaceEvaluation.verifiedCropData(cropURL, reviewedHash: row.label.cropSHA256)
            let jpeg = try FaceEvaluation.upgradeJPEG(cropBytes)
            guard try FaceEvaluation.fileDigest(cropURL.path) == before else { throw FaceEvaluation.Invalid("Diagnostic crop changed during rendering") }
            let id = UUID(), vector = FaceRecognitionEmbeddingCodec.encode(row.embedding)
            let embeddingPath = "embeddings/\(id.uuidString.lowercased()).fem2"
            let upgradePath = "upgrade_sources/\(id.uuidString.lowercased()).jpg"
            for (path, bytes) in [(embeddingPath, vector), (upgradePath, jpeg)] {
                try bytes.write(to: source.appendingPathComponent(path), options: .atomic)
                files.append(try .init(path: path, byteCount: bytes.count, sha256: FaceEvaluation.digest(bytes)))
            }
            examples[row.label.personID!, default: []].append(try .init(id: id,
                embeddingPath: embeddingPath, upgradeSourcePath: upgradePath))
            provenance.append(.init(exampleID: id, personID: row.label.personID!,
                recordPath: row.recordPath, recordSHA256: row.recordSHA256, imageSHA256: row.sourceSHA256,
                ordinal: row.label.ordinal, cropPath: cropURL.path, cropSHA256: before,
                upgradeSourceSHA256: FaceEvaluation.digest(jpeg)))
        }
        let people = try examples.map { id, examples in
            try PeopleLibraryPayload.Person(id: id,
                name: references.first(where: { $0.label.personID == id })!.label.pseudonym!, examples: examples)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let payload = try PeopleLibraryPayload(people: people)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payloadBytes = try encoder.encode(payload)
        try payloadBytes.write(to: source.appendingPathComponent(PeopleLibraryManifest.payloadFileName), options: .atomic)
        files.append(try .init(path: PeopleLibraryManifest.payloadFileName, byteCount: payloadBytes.count,
            sha256: FaceEvaluation.digest(payloadBytes)))
        let date = ISO8601DateFormatter(); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let libraryManifest = try PeopleLibraryManifest(libraryID: UUID(), exportedAt: date.string(from: Date()),
            exporter: .init(app: "Authorized reference generator", version: "3.0-development", sourceRevision: commit),
            peopleCount: people.count, embeddingCount: references.count, files: files)
        try libraryManifest.validate(payload: payload)
        try encoder.encode(libraryManifest).write(to: source.appendingPathComponent(PeopleLibraryManifest.fileName), options: .atomic)
        let snapshot = try PeopleLibraryRepository(root: output.appendingPathComponent("Admitted")).importSnapshot(from: source)
        XCTAssertEqual(snapshot.manifest.schemaVersion, 3)
        let package = output.appendingPathComponent("Pseudonym Reference Library.photoagentpeople")
        _ = try PeopleLibraryPackageService().export(snapshot, to: package)
        let imported = try PeopleLibraryPackageService().importPackage(at: package,
            into: PeopleLibraryRepository(root: output.appendingPathComponent("Reimported")))
        XCTAssertEqual(imported.manifest.schemaVersion, 3)
        XCTAssertEqual(imported.manifest.embeddingCount, references.count)
        let importedPayload = try PeopleLibraryPayload.decode(Data(contentsOf:
            imported.directoryURL.appendingPathComponent(PeopleLibraryManifest.payloadFileName)))
        XCTAssertEqual(importedPayload.people.map(\.name).sorted(), people.map(\.name).sorted())
        XCTAssertEqual(importedPayload.people.flatMap(\.examples).count, references.count)
        let originalGallery = try FaceRecognitionGallery(people:
            Dictionary(grouping: references, by: { $0.label.personID! }).map { id, rows in
                try .init(id: id, name: rows[0].label.pseudonym!, examples: rows.map(\.embedding))
            })
        let policy = try XCTUnwrap(ProductionFaceRecognitionAdmission.Configuration.load(
            from: try XCTUnwrap(Bundle.main.infoDictionary))).policy
        for row in loaded where row.label.role != .reference {
            let original = FaceRecognitionMatcher.match(embedding: row.embedding, quality: row.quality,
                gallery: originalGallery, policy: policy)
            let roundTrip = FaceRecognitionMatcher.match(embedding: row.embedding, quality: row.quality,
                gallery: imported.gallery, policy: policy)
            FaceEvaluation.assertEquivalent(original, roundTrip)
        }
        try FaceEvaluation.checkSources(loaded)
        guard try Data(contentsOf: manifestURL) == manifestBytes else { throw FaceEvaluation.Invalid("Manifest changed during export") }
        for item in provenance {
            guard try FaceEvaluation.fileDigest(item.cropPath) == item.cropSHA256 else { throw FaceEvaluation.Invalid("Reviewed crop changed during export") }
        }
        try FaceEvaluation.validateCommit(commit)
        let report = FaceEvaluation.ReferenceExportProvenance(schemaVersion: 1,
            producer: "FTP test helper; not native Photo Agent producer exchange",
            sourceCommit: commit, manifestSHA256: FaceEvaluation.digest(manifestBytes),
            libraryRevision: imported.manifest.revision, referenceExamples: references.count,
            queryOutcomesCompared: loaded.count - references.count, examples: provenance)
        try encoder.encode(report).write(to: output.appendingPathComponent("reference-package-provenance.json"), options: .atomic)
    }

    func testOptInVisuallyVerifiedHeldOutMatching() throws {
        guard let path = ProcessInfo.processInfo.environment["AAGEDAL_FACE_MATCHING_MANIFEST"],
              !path.isEmpty else { throw XCTSkip("No operator-reviewed matching manifest supplied") }
        let manifestURL = try FaceEvaluation.privateBuildURL(path)
        let manifestBytes = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FaceEvaluation.Manifest.self, from: manifestBytes)
        let loaded = try FaceEvaluation.load(manifest)
        let configuration = try XCTUnwrap(ProductionFaceRecognitionAdmission.Configuration.load(
            from: try XCTUnwrap(Bundle.main.infoDictionary)))
        let references = loaded.filter { $0.label.role == .reference }
        let people = try Dictionary(grouping: references, by: { $0.label.personID! }).map { id, rows in
            try FaceRecognitionPerson(id: id, name: rows[0].label.pseudonym!, examples: rows.map(\.embedding))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let gallery = try FaceRecognitionGallery(people: people)
        var cases: [FaceEvaluation.CaseResult] = []
        var summaries: [String: FaceEvaluation.Counts] = [:]
        for role in [FaceEvaluation.Role.calibration, .heldOut] {
            var counts = FaceEvaluation.Counts()
            for row in loaded where row.label.role == role {
                let outcome = FaceRecognitionMatcher.match(embedding: row.embedding, quality: row.quality,
                    gallery: gallery, policy: configuration.policy)
                cases.append(counts.record(row: row, outcome: outcome))
            }
            summaries[role.rawValue] = counts
        }
        // Reject edits made during evaluation as well as changes since scanning.
        try FaceEvaluation.checkSources(loaded)
        guard try Data(contentsOf: manifestURL) == manifestBytes else {
            throw FaceEvaluation.Invalid("Operator manifest changed during evaluation")
        }
        let heldOut = summaries[FaceEvaluation.Role.heldOut.rawValue]!
        let criteriaMet = manifest.heldOutCriteria.map { $0.accepts(heldOut) }
        let report = FaceEvaluation.Report(schemaVersion: 1,
            manifestSHA256: FaceEvaluation.digest(manifestBytes),
            runtimeRevision: BundledAuraFaceModel.expectedWeightsSHA256,
            referencePeople: people.count, referenceExamples: references.count,
            policy: .init(configuration.policy), thresholdCheckPerformed: criteriaMet != nil,
            heldOutCriteria: manifest.heldOutCriteria, heldOutCriteriaMet: criteriaMet,
            detectionAccuracyEvaluated: false, releaseGatePassed: false, summaries: summaries, cases: cases)
        let output = try FaceEvaluation.privateBuildURL(manifest.outputRoot)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw FaceEvaluation.Invalid("Output root already exists; choose a fresh ignored directory")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("matching-results.json"), options: .atomic)
        if let criteriaMet { XCTAssertTrue(criteriaMet, "Explicit held-out criteria failed; see private matching-results.json") }
    }

    func testSplitValidationRejectsDuplicateFacesAndCrossRoleCaptureLeakage() throws {
        let first = FaceEvaluation.SplitEntry(faceKey: "sha:0", imageSHA: "sha", captureGroup: "burst", role: .reference)
        XCTAssertThrowsError(try FaceEvaluation.validateSplits([first, first]))
        XCTAssertThrowsError(try FaceEvaluation.validateSplits([first,
            .init(faceKey: "sha:1", imageSHA: "sha", captureGroup: "other", role: .heldOut)]))
        XCTAssertThrowsError(try FaceEvaluation.validateSplits([first,
            .init(faceKey: "other:0", imageSHA: "other", captureGroup: "burst", role: .calibration)]))
        XCTAssertNoThrow(try FaceEvaluation.validateSplits([first,
            .init(faceKey: "other:0", imageSHA: "other", captureGroup: "other", role: .heldOut)]))
    }

    func testReferenceExportRejectsStaleSourceRevisionDirtySourceAndUnpinnedCrop() throws {
        let commit = String(repeating: "a", count: 40)
        XCTAssertNoThrow(try FaceEvaluation.validateSourceState(commit: commit, head: commit,
            trackedChanges: Data(), untrackedSource: Data()))
        XCTAssertThrowsError(try FaceEvaluation.validateSourceState(commit: commit, head: String(repeating: "b", count: 40),
            trackedChanges: Data(), untrackedSource: Data()))
        XCTAssertThrowsError(try FaceEvaluation.validateSourceState(commit: commit, head: commit,
            trackedChanges: Data("AagedalFTPSync/FaceRecognition/AuraFaceRecognitionRuntime.swift\0".utf8), untrackedSource: Data()))
        XCTAssertThrowsError(try FaceEvaluation.validateSourceState(commit: commit, head: commit,
            trackedChanges: Data(), untrackedSource: Data("AagedalFTPSyncTests/NewGenerator.swift\0".utf8)))
        XCTAssertThrowsError(try FaceEvaluation.requiredCropHash(nil))
        XCTAssertThrowsError(try FaceEvaluation.requiredCropHash("unreviewed"))
        XCTAssertEqual(try FaceEvaluation.requiredCropHash(String(repeating: "c", count: 64)), String(repeating: "c", count: 64))
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("reviewed-crop-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let reviewed = Data("synthetic reviewed crop bytes".utf8)
        try reviewed.write(to: fixture)
        let hash = FaceEvaluation.digest(reviewed)
        XCTAssertEqual(try FaceEvaluation.verifiedCropData(fixture, reviewedHash: hash).0, reviewed)
        try Data("replacement after visual review".utf8).write(to: fixture)
        XCTAssertThrowsError(try FaceEvaluation.verifiedCropData(fixture, reviewedHash: hash))
    }

    func testLabelValidationRejectsUnverifiedConflictingAndUnknownReferences() throws {
        let a = UUID(), b = UUID()
        func label(_ id: UUID?, _ name: String?, _ role: FaceEvaluation.Role = .reference,
                   verified: Bool = true) -> FaceEvaluation.Label {
            .init(recordPath: "/fixture.json", recordSHA256: String(repeating: "0", count: 64), ordinal: 0, captureGroup: "fixture", personID: id,
                  pseudonym: name, role: role, visuallyVerified: verified)
        }
        XCTAssertThrowsError(try FaceEvaluation.validateLabels([label(nil, nil)]))
        XCTAssertThrowsError(try FaceEvaluation.validateLabels([label(a, "Person A", verified: false)]))
        XCTAssertThrowsError(try FaceEvaluation.validateLabels([label(a, "Person A"), label(a, "Person B", .heldOut)]))
        XCTAssertThrowsError(try FaceEvaluation.validateLabels([label(a, "Person A"), label(b, "Person A")]))
        XCTAssertThrowsError(try FaceEvaluation.validateLabels([label(a, "Person A"), label(b, "Person B", .heldOut)]))
        XCTAssertNoThrow(try FaceEvaluation.validateLabels([label(a, "Person A"), label(b, "Person B"), label(nil, nil, .heldOut)]))
    }
}

private enum FaceEvaluation {
    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    enum Role: String, Codable { case reference, calibration, heldOut }
    struct Label: Codable {
        let recordPath: String
        let recordSHA256: String
        let ordinal: Int
        let captureGroup: String
        let personID: UUID?
        let pseudonym: String?
        let role: Role
        let visuallyVerified: Bool
        let cropSHA256: String?
        init(recordPath: String, recordSHA256: String, ordinal: Int, captureGroup: String,
             personID: UUID?, pseudonym: String?, role: Role, visuallyVerified: Bool, cropSHA256: String? = nil) {
            self.recordPath = recordPath; self.recordSHA256 = recordSHA256; self.ordinal = ordinal
            self.captureGroup = captureGroup; self.personID = personID; self.pseudonym = pseudonym
            self.role = role; self.visuallyVerified = visuallyVerified; self.cropSHA256 = cropSHA256
        }
    }
    struct Criteria: Codable {
        let maximumFalseNames: Int
        let maximumMissedKnown: Int
        let minimumKnownQueries: Int
        let minimumUnknownQueries: Int
        func accepts(_ counts: Counts) -> Bool {
            counts.falseNames <= maximumFalseNames && counts.missedKnown <= maximumMissedKnown
                && counts.knownQueries >= minimumKnownQueries && counts.unknownQueries >= minimumUnknownQueries
        }
    }
    struct Manifest: Decodable {
        let schemaVersion: Int
        let outputRoot: String
        let examples: [Label]
        let heldOutCriteria: Criteria?
    }
    struct ScanRecord: Decodable {
        let schemaVersion: Int
        let index: Int
        let sourcePath: String
        let sourceSHA256: String?
        let modelID: String
        let preprocessingRevision: String
        let embeddingSpaceVersion: Int
        let runtimeRevision: String
        let boundingBoxSource: String
        let faces: [ScanFace]
        let failure: String?
    }
    struct ScanFace: Decodable {
        let ordinal: Int
        let embedding: [Float]
        let captureQuality: Double?
        let diagnosticCrop: String
        let diagnosticCropSHA256: String?
    }
    struct Loaded {
        let label: Label
        let sourcePath: String
        let sourceSHA256: String
        let recordPath: String
        let recordSHA256: String
        let embedding: FaceRecognitionEmbedding
        let quality: Double?
        let diagnosticCrop: String
    }
    struct SplitEntry {
        let faceKey: String
        let imageSHA: String
        let captureGroup: String
        let role: Role
    }
    static func validateSplits(_ rows: [SplitEntry]) throws {
        var faces = Set<String>(), images: [String: Role] = [:], groups: [String: Role] = [:]
        for row in rows {
            guard faces.insert(row.faceKey).inserted else { throw Invalid("Duplicate face example") }
            guard images[row.imageSHA] == nil || images[row.imageSHA] == row.role,
                  groups[row.captureGroup] == nil || groups[row.captureGroup] == row.role else {
                throw Invalid("An image or capture group crosses reference/calibration/held-out splits")
            }
            images[row.imageSHA] = row.role; groups[row.captureGroup] = row.role
        }
    }
    static func validateLabels(_ rows: [Label]) throws {
        var names: [UUID: String] = [:], identities: [String: UUID] = [:]
        let references = Set(rows.filter { $0.role == .reference }.compactMap(\.personID))
        for row in rows {
            guard row.visuallyVerified, row.ordinal >= 0, validSHA256(row.recordSHA256),
                  !row.captureGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Invalid("Every label needs visual verification, nonnegative ordinal and capture group")
            }
            if let cropHash = row.cropSHA256, !validSHA256(cropHash) { throw Invalid("Invalid reviewed crop hash") }
            if let id = row.personID {
                guard let name = row.pseudonym, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      names[id] == nil || names[id] == name,
                      identities[name] == nil || identities[name] == id else {
                    throw Invalid("Known identity pseudonyms must be present, consistent and unique")
                }
                guard row.role == .reference || references.contains(id) else {
                    throw Invalid("Known query identity has no reference example")
                }
                names[id] = name; identities[name] = id
            } else {
                guard row.role != .reference, row.pseudonym == nil else {
                    throw Invalid("Unknown examples must be queries with null personID and pseudonym")
                }
            }
        }
    }
    static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw Invalid("Paths must be absolute") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    /// The compiler's source path identifies this checkout, independently of the
    /// XCTest host's working directory. Resolve aliases before comparing ancestry.
    static func privateBuildURL(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("build")
        let url = try absoluteURL(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else {
            throw Invalid("Manifest, scanner records and output must be inside this checkout's ignored build directory")
        }
        return url
    }
    static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fileDigest(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: absoluteURL(path)); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func load(_ manifest: Manifest) throws -> [Loaded] {
        guard manifest.schemaVersion == 1, !manifest.examples.isEmpty else { throw Invalid("Invalid matching manifest schema") }
        try validateLabels(manifest.examples)
        let ids = Set(manifest.examples.filter { $0.role == .reference }.compactMap(\.personID))
        guard ids.count >= 2, manifest.examples.contains(where: { $0.role == .heldOut }) else {
            throw Invalid("Need at least two reference identities and a held-out query")
        }
        if let criteria = manifest.heldOutCriteria {
            guard criteria.maximumFalseNames >= 0, criteria.maximumMissedKnown >= 0,
                  criteria.minimumKnownQueries > 0, criteria.minimumUnknownQueries > 0 else {
                throw Invalid("Criteria need nonnegative error limits and positive known/unknown coverage")
            }
        }
        var records: [String: (ScanRecord, String)] = [:], sourceHashes: [String: String] = [:]
        var loaded: [Loaded] = []
        for label in manifest.examples {
            let url = try privateBuildURL(label.recordPath)
            let record: ScanRecord, recordHash: String
            if let cached = records[url.path] { (record, recordHash) = cached }
            else {
                let bytes = try Data(contentsOf: url)
                recordHash = digest(bytes)
                guard recordHash == label.recordSHA256 else { throw Invalid("Visually reviewed scanner record changed") }
                record = try JSONDecoder().decode(ScanRecord.self, from: bytes)
                records[url.path] = (record, recordHash)
            }
            guard recordHash == label.recordSHA256 else { throw Invalid("Visually reviewed scanner record changed") }
            guard record.schemaVersion == 1, record.index >= 0, record.failure == nil,
                  record.modelID == AuraFaceRecognitionRuntime.modelID,
                  record.preprocessingRevision == AuraFaceRecognitionRuntime.preprocessingRevision,
                  record.embeddingSpaceVersion == AuraFaceRecognitionRuntime.embeddingSpaceVersion,
                  record.runtimeRevision == BundledAuraFaceModel.expectedWeightsSHA256,
                  record.boundingBoxSource == "production-analysis",
                  let sha = record.sourceSHA256, validSHA256(sha),
                  Set(record.faces.map(\.ordinal)).count == record.faces.count,
                  record.faces.allSatisfy({ $0.ordinal >= 0 }) else {
                throw Invalid("Scanner record failure, identity mismatch, invalid hash or duplicate ordinal")
            }
            let sourceURL = try absoluteURL(record.sourcePath).resolvingSymlinksInPath()
            guard !sourceURL.pathComponents.contains(where: { $0.hasPrefix(".") }) else {
                throw Invalid("Hidden caches and face_data crops are ineligible capture images")
            }
            let actualHash: String
            if let cached = sourceHashes[record.sourcePath] { actualHash = cached }
            else { actualHash = try fileDigest(record.sourcePath); sourceHashes[record.sourcePath] = actualHash }
            guard sha == actualHash else { throw Invalid("Source image changed since scan") }
            // Validate all vectors, including unselected faces, rather than silently
            // accepting a partly malformed scanner record.
            for face in record.faces {
                _ = try FaceRecognitionEmbedding(validatingNormalized: face.embedding)
                if let quality = face.captureQuality {
                    guard quality.isFinite, (0...1).contains(quality) else { throw Invalid("Invalid capture quality") }
                }
            }
            guard let face = record.faces.first(where: { $0.ordinal == label.ordinal }) else {
                throw Invalid("Selected face ordinal is absent from scanner record")
            }
            if let scannerHash = face.diagnosticCropSHA256 {
                guard validSHA256(scannerHash), label.cropSHA256 == nil || label.cropSHA256 == scannerHash else {
                    throw Invalid("Scanner crop hash differs from reviewed crop hash")
                }
            }
            loaded.append(.init(label: label, sourcePath: record.sourcePath, sourceSHA256: sha,
                recordPath: url.path, recordSHA256: recordHash,
                embedding: try .init(validatingNormalized: face.embedding), quality: face.captureQuality,
                diagnosticCrop: face.diagnosticCrop))
        }
        try validateSplits(loaded.map { .init(faceKey: "\($0.sourceSHA256):\($0.label.ordinal)",
            imageSHA: $0.sourceSHA256, captureGroup: $0.label.captureGroup, role: $0.label.role) })
        return loaded
    }
    static func checkSources(_ rows: [Loaded]) throws {
        for row in Dictionary(grouping: rows, by: \.sourcePath).values {
            guard try fileDigest(row[0].sourcePath) == row[0].sourceSHA256 else { throw Invalid("Source changed during evaluation") }
        }
        for row in Dictionary(grouping: rows, by: \.recordPath).values {
            guard try fileDigest(row[0].recordPath) == row[0].recordSHA256 else { throw Invalid("Scanner record changed during evaluation") }
        }
    }
    static func validateCommit(_ commit: String) throws {
        guard commit.count == 40, commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Invalid("Source commit must be lowercase 40-hex")
        }
        let sourcePaths = ["AagedalFTPSync", "AagedalFTPSyncTests", "AagedalFTPSyncUITests",
            "Aagedal FTP Sync.xcodeproj", "project.yml", "Configuration", "Packages", "Vendor",
            "Scripts", "Tools", "Server", ".github", ".gitignore"]
        let headBytes = try git(["rev-parse", "HEAD"])
        let head = String(data: headBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let changed = try git(["diff", "--name-only", "-z", "HEAD", "--"] + sourcePaths)
        let untracked = try git(["ls-files", "--others", "--exclude-standard", "-z", "--"] + sourcePaths)
        try validateSourceState(commit: commit, head: head, trackedChanges: changed, untrackedSource: untracked)
    }
    static func validateSourceState(commit: String, head: String, trackedChanges: Data, untrackedSource: Data) throws {
        guard commit == head, trackedChanges.isEmpty, untrackedSource.isEmpty else {
            throw Invalid("Reference generator must use current HEAD with clean tracked and untracked source; ignored private outputs are allowed")
        }
    }
    static func git(_ arguments: [String]) throws -> Data {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", checkout.path] + arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Invalid("Cannot verify clean committed generator source") }
        return bytes
    }
    static func requiredCropHash(_ hash: String?) throws -> String {
        guard let hash, validSHA256(hash) else { throw Invalid("Reference export requires a visually reviewed cropSHA256") }
        return hash
    }
    static func verifiedCropData(_ url: URL, reviewedHash: String?) throws -> (Data, String) {
        let pinnedHash = try requiredCropHash(reviewedHash)
        let before = try fileDigest(url.path)
        guard before == pinnedHash else { throw Invalid("Diagnostic crop differs from visually reviewed bytes") }
        let bytes = try Data(contentsOf: url)
        guard digest(bytes) == pinnedHash, try fileDigest(url.path) == pinnedHash else {
            throw Invalid("Diagnostic crop changed during read")
        }
        return (bytes, pinnedHash)
    }
    static func reviewedCropURL(_ row: Loaded) throws -> URL {
        let name = row.diagnosticCrop
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw Invalid("Diagnostic crop must be a basename")
        }
        let directory = try privateBuildURL(row.recordPath).deletingLastPathComponent()
        let crop = try privateBuildURL(directory.appendingPathComponent(name).path)
        guard crop.deletingLastPathComponent() == directory else { throw Invalid("Diagnostic crop escapes scanner directory") }
        return crop
    }
    static func upgradeJPEG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Invalid("Cannot decode/render reference crop")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 320))
        guard let rendered = context.makeImage() else { throw Invalid("Cannot render reference crop") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Invalid("Cannot encode reference crop")
        }
        CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Invalid("Cannot finalize reference crop") }
        return bytes as Data
    }
    static func assertEquivalent(_ first: FaceRecognitionMatchOutcome, _ second: FaceRecognitionMatchOutcome) {
        func candidates(_ first: FaceRecognitionCandidate?, _ second: FaceRecognitionCandidate?) {
            XCTAssertEqual(first?.personID, second?.personID); XCTAssertEqual(first?.name, second?.name)
            if let first, let second { XCTAssertEqual(first.cosineDistance, second.cosineDistance, accuracy: 0.000001) }
        }
        switch (first, second) {
        case let (.accepted(a, b), .accepted(c, d)): candidates(a, c); candidates(b, d)
        case let (.noMatch(a, b), .noMatch(c, d)): candidates(a, c); candidates(b, d)
        case let (.ambiguous(a, b), .ambiguous(c, d)): candidates(a, c); candidates(b, d)
        default: XCTAssertEqual(first, second)
        }
    }
    struct ReferenceProvenance: Encodable {
        let exampleID: UUID
        let personID: UUID
        let recordPath: String
        let recordSHA256: String
        let imageSHA256: String
        let ordinal: Int
        let cropPath: String
        let cropSHA256: String
        let upgradeSourceSHA256: String
    }
    struct ReferenceExportProvenance: Encodable {
        let schemaVersion: Int
        let producer: String
        let sourceCommit: String
        let manifestSHA256: String
        let libraryRevision: String
        let referenceExamples: Int
        let queryOutcomesCompared: Int
        let examples: [ReferenceProvenance]
    }
    struct Candidate: Encodable {
        let personID: UUID
        let pseudonym: String
        let cosineDistance: Double
        init(_ value: FaceRecognitionCandidate) {
            personID = value.personID; pseudonym = value.name; cosineDistance = value.cosineDistance
        }
    }
    struct CaseResult: Encodable {
        let recordPath: String
        let recordSHA256: String
        let imageSHA256: String
        let ordinal: Int
        let captureGroup: String
        let role: Role
        let expectedPersonID: UUID?
        let expectedPseudonym: String?
        let captureQuality: Double?
        let outcome: String
        let acceptedCorrect: Bool
        let falseName: Bool
        let missedKnown: Bool
        let best: Candidate?
        let runnerUp: Candidate?
    }
    struct Counts: Encodable {
        var queries = 0, knownQueries = 0, unknownQueries = 0
        var acceptedTotal = 0
        var acceptedCorrect = 0, falseNames = 0, missedKnown = 0, abstainedUnknown = 0
        var ambiguous = 0, qualityRejected = 0, qualityUnavailable = 0, noMatch = 0
        mutating func record(row: Loaded, outcome: FaceRecognitionMatchOutcome) -> CaseResult {
            queries += 1
            let known = row.label.personID != nil
            if known { knownQueries += 1 } else { unknownQueries += 1 }
            var best: FaceRecognitionCandidate?, runnerUp: FaceRecognitionCandidate?
            var status: String, accepted = false
            switch outcome {
            case let .accepted(first, second): status = "accepted"; best = first; runnerUp = second; accepted = true
            case let .noMatch(first, second): status = "noMatch"; best = first; runnerUp = second; noMatch += 1
            case let .ambiguous(first, second): status = "ambiguous"; best = first; runnerUp = second; ambiguous += 1
            case .insufficientQuality: status = "qualityRejected"; qualityRejected += 1
            case .qualityUnavailable: status = "qualityUnavailable"; qualityUnavailable += 1
            case .invalidQuality: status = "invalidQuality"; qualityRejected += 1
            }
            let correct = accepted && known && best?.personID == row.label.personID
            let falseName = accepted && !correct
            let missed = known && !correct
            if accepted { acceptedTotal += 1 }
            if correct { acceptedCorrect += 1 }; if falseName { falseNames += 1 }
            if missed { missedKnown += 1 }; if !known && !accepted { abstainedUnknown += 1 }
            return .init(recordPath: row.recordPath, recordSHA256: row.recordSHA256,
                imageSHA256: row.sourceSHA256, ordinal: row.label.ordinal, captureGroup: row.label.captureGroup,
                role: row.label.role, expectedPersonID: row.label.personID, expectedPseudonym: row.label.pseudonym,
                captureQuality: row.quality, outcome: status, acceptedCorrect: correct, falseName: falseName,
                missedKnown: missed, best: best.map(Candidate.init), runnerUp: runnerUp.map(Candidate.init))
        }
    }
    struct Policy: Encodable {
        let maximumCosineDistance: Double
        let minimumRunnerUpGap: Double
        let minimumCaptureQuality: Double
        let unavailableQualityPolicy: String
        init(_ policy: FaceRecognitionAcceptancePolicy) {
            maximumCosineDistance = policy.maximumCosineDistance
            minimumRunnerUpGap = policy.minimumRunnerUpGap
            minimumCaptureQuality = policy.minimumCaptureQuality
            unavailableQualityPolicy = policy.unavailableQualityPolicy == .reject ? "reject" : "allow"
        }
    }
    struct Report: Encodable {
        let schemaVersion: Int
        let manifestSHA256: String
        let runtimeRevision: String
        let referencePeople: Int
        let referenceExamples: Int
        let policy: Policy
        let thresholdCheckPerformed: Bool
        let heldOutCriteria: Criteria?
        let heldOutCriteriaMet: Bool?
        let detectionAccuracyEvaluated: Bool
        let releaseGatePassed: Bool
        let summaries: [String: Counts]
        let cases: [CaseResult]
    }
}
