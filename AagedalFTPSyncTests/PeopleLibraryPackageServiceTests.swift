import CryptoKit
import Darwin
import Foundation
import XCTest
import zlib
@testable import AagedalFTPSync

final class PeopleLibraryPackageServiceTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let repository: PeopleLibraryRepository
        let snapshot: PeopleLibrarySnapshot
    }
    private enum Failure: Error { case injected }
    private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("people-package-\(UUID())")
        let source = parent.appendingPathComponent("source.aagedalpeople")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("embeddings"), withIntermediateDirectories: true)
        addTeardownBlock {
            if let entries = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil) {
                for case let url as URL in entries { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
            }
            try? FileManager.default.removeItem(at: parent)
        }
        let exampleID = UUID(), personID = UUID()
        var values = [Float](repeating: 0, count: 512); values[0] = 1
        let vector = FaceRecognitionEmbeddingCodec.encode(try .init(validatingNormalized: values))
        let path = "embeddings/\(exampleID.uuidString.lowercased()).fem2"
        let example = try PeopleLibraryPayload.Example(id: exampleID, embeddingPath: path)
        let payload = try PeopleLibraryPayload(people: [.init(id: personID, name: "  {persons}, Å  ", examples: [example])])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        let manifest = try PeopleLibraryManifest(libraryID: UUID(), exportedAt: "2026-09-12T12:00:00.000Z",
            exporter: .init(app: "Fixture", version: "3", sourceRevision: String(repeating: "a", count: 40)),
            peopleCount: 1, embeddingCount: 1, files: [
                .init(path: "people.json", byteCount: bytes.count, sha256: sha(bytes)),
                .init(path: path, byteCount: vector.count, sha256: sha(vector))])
        try bytes.write(to: source.appendingPathComponent("people.json"))
        try vector.write(to: source.appendingPathComponent(path))
        try encoder.encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        let repository = PeopleLibraryRepository(root: parent.appendingPathComponent("installed"))
        return .init(parent: parent, repository: repository, snapshot: try repository.importSnapshot(from: source))
    }
    private func stages(_ f: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: f.parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".aagedalpeople-export-") }
    }
    private func assertNoStages(_ f: Fixture) throws {
        XCTAssertTrue(try stages(f).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: f.parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".aagedalpeople-import-") }.isEmpty)
    }

    private struct ZIPEntry {
        let name: String
        let data: Data
        var method: UInt16 = 0
        var versionMadeBy: UInt16 = UInt16(3 << 8) | 20
        var externalAttributes: UInt32 = UInt32(S_IFREG | 0o600) << 16
        var extra = Data()
        var declaredSize: UInt32?
        var crcOverride: UInt32?
        var usesDataDescriptor = false
    }
    private func packageEntries(_ f: Fixture, root: String = "") throws -> [ZIPEntry] {
        try (f.snapshot.manifest.files.map(\.path) + [PeopleLibraryManifest.fileName]).map { path in
            ZIPEntry(name: root + path, data: try Data(contentsOf: f.snapshot.directoryURL.appendingPathComponent(path)),
                     method: path == PeopleLibraryManifest.payloadFileName ? 8 : 0,
                     usesDataDescriptor: path == PeopleLibraryManifest.payloadFileName)
        }
    }
    private func zip(_ entries: [ZIPEntry], at url: URL) throws {
        struct Central { let entry: ZIPEntry; let compressed: Data; let crc: UInt32; let offset: UInt32 }
        var bytes = Data(), central: [Central] = []
        for entry in entries {
            let name = Data(entry.name.utf8)
            let compressed = entry.method == 8 ? try deflateRaw(entry.data) : entry.data
            let crc = entry.crcOverride ?? crc32(entry.data)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            let offset = UInt32(bytes.count)
            let flags: UInt16 = entry.usesDataDescriptor ? 0x0808 : 0x0800
            bytes.le32(0x0403_4b50); bytes.le16(20); bytes.le16(flags); bytes.le16(entry.method)
            bytes.le16(0); bytes.le16(0)
            bytes.le32(entry.usesDataDescriptor ? 0 : crc)
            bytes.le32(entry.usesDataDescriptor ? 0 : UInt32(compressed.count))
            bytes.le32(entry.usesDataDescriptor ? 0 : size)
            bytes.le16(UInt16(name.count)); bytes.le16(UInt16(entry.extra.count)); bytes.append(name)
            bytes.append(entry.extra); bytes.append(compressed)
            if entry.usesDataDescriptor {
                bytes.le32(crc); bytes.le32(UInt32(compressed.count)); bytes.le32(size)
            }
            central.append(.init(entry: entry, compressed: compressed, crc: crc, offset: offset))
        }
        let centralOffset = UInt32(bytes.count)
        for item in central {
            let name = Data(item.entry.name.utf8), size = item.entry.declaredSize ?? UInt32(item.entry.data.count)
            bytes.le32(0x0201_4b50); bytes.le16(item.entry.versionMadeBy); bytes.le16(20)
            bytes.le16(item.entry.usesDataDescriptor ? 0x0808 : 0x0800)
            bytes.le16(item.entry.method); bytes.le16(0); bytes.le16(0)
            bytes.le32(item.crc); bytes.le32(UInt32(item.compressed.count)); bytes.le32(size)
            bytes.le16(UInt16(name.count)); bytes.le16(UInt16(item.entry.extra.count)); bytes.le16(0)
            bytes.le16(0); bytes.le16(0); bytes.le32(item.entry.externalAttributes); bytes.le32(item.offset)
            bytes.append(name); bytes.append(item.entry.extra)
        }
        let centralSize = UInt32(bytes.count) - centralOffset
        bytes.le32(0x0605_4b50); bytes.le16(0); bytes.le16(0); bytes.le16(UInt16(entries.count))
        bytes.le16(UInt16(entries.count)); bytes.le32(centralSize); bytes.le32(centralOffset); bytes.le16(0)
        try bytes.write(to: url)
    }
    private func deflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream(), output = Data(count: Int(compressBound(uLong(data.count))))
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                           Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.injected
        }
        defer { deflateEnd(&stream) }
        let status: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(destination.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw Failure.injected }
        output.count = Int(stream.total_out)
        return output
    }
    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        }
        return value ^ 0xffff_ffff
    }

    func testCommittedCrossAppGoldenPackageAndExactReexport() throws {
        let repositoryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("people-golden-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: repositoryRoot) }
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: false)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Documentation/Testing/Fixtures/people-library-v2.aagedalpeople")
        let repository = PeopleLibraryRepository(root: repositoryRoot.appendingPathComponent("repository"))
        let snapshot = try PeopleLibraryPackageService().importPackage(at: fixture, into: repository)
        XCTAssertEqual(snapshot.manifest.coreRevision, "636f498dba7a9bb357ece23e2f5edcd02997fb4df1acc1e1101eecfd32438e83")
        XCTAssertEqual(snapshot.manifest.revision, "12324ae00b79094d239447531d81348e4c6450b7a65fbc329daab261c08025ba")
        let output = repositoryRoot.appendingPathComponent("roundtrip.aagedalpeople")
        try PeopleLibraryPackageService().export(snapshot, to: output)
        for path in snapshot.manifest.files.map(\.path) + [PeopleLibraryManifest.fileName] {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)),
                           try Data(contentsOf: fixture.appendingPathComponent(path)), path)
        }
    }

    func testExactByteExportAndImportIntoSeparateRepository() throws {
        let f = try fixture(), service = PeopleLibraryPackageService()
        let output = f.parent.appendingPathComponent("shared.aagedalpeople")
        XCTAssertEqual(try service.export(f.snapshot, to: output), output)
        let paths = f.snapshot.manifest.files.map(\.path) + [PeopleLibraryManifest.fileName]
        for path in paths {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)),
                           try Data(contentsOf: f.snapshot.directoryURL.appendingPathComponent(path)))
        }
        let receiver = PeopleLibraryRepository(root: f.parent.appendingPathComponent("receiver"))
        let imported = try service.importPackage(at: output, into: receiver)
        XCTAssertEqual(imported.manifest, f.snapshot.manifest)
        XCTAssertEqual(imported.gallery, f.snapshot.gallery)
        XCTAssertEqual(imported.gallery.people[0].name, "  {persons}, Å  ")
        XCTAssertEqual(try f.repository.currentSnapshot()?.manifest, f.snapshot.manifest)
        try assertNoStages(f)
    }

    func testWrappedZIPImportsStoredAndDeflatedFilesByteForByte() throws {
        let f = try fixture(), archive = f.parent.appendingPathComponent("shared.aagedalpeople.zip")
        try zip(packageEntries(f, root: "shared.aagedalpeople/"), at: archive)
        let receiver = PeopleLibraryRepository(root: f.parent.appendingPathComponent("zip-receiver"))
        let imported = try PeopleLibraryPackageService().importPackage(at: archive, into: receiver)
        XCTAssertEqual(imported.manifest, f.snapshot.manifest)
        XCTAssertEqual(imported.gallery, f.snapshot.gallery)
        for path in f.snapshot.manifest.files.map(\.path) + [PeopleLibraryManifest.fileName] {
            XCTAssertEqual(try Data(contentsOf: imported.directoryURL.appendingPathComponent(path)),
                           try Data(contentsOf: f.snapshot.directoryURL.appendingPathComponent(path)), path)
        }
        try assertNoStages(f)
    }

    func testZIPRejectsUnsafeEntriesAndAmbiguousRootsBeforeRepositoryMutation() throws {
        let f = try fixture(), base = try packageEntries(f)
        let payloadIndex = try XCTUnwrap(base.firstIndex { $0.name == PeopleLibraryManifest.payloadFileName })
        var symlinkEntries = base
        symlinkEntries[payloadIndex].externalAttributes = UInt32(S_IFLNK | 0o777) << 16
        var nonUnixSymlinkEntries = symlinkEntries
        nonUnixSymlinkEntries[payloadIndex].versionMadeBy = 20
        var hardlinkEntries = base
        hardlinkEntries[payloadIndex].extra = Data([0x0d, 0x00, 0x00, 0x00])
        let variants: [[ZIPEntry]] = [
            base + [.init(name: "../escape", data: Data([1]))],
            symlinkEntries,
            nonUnixSymlinkEntries,
            base + [.init(name: "PEOPLE.JSON", data: Data([1]))],
            base + [.init(name: "undeclared", data: Data([1]))],
            hardlinkEntries,
            try packageEntries(f, root: "one.aagedalpeople/") +
                [.init(name: "two.aagedalpeople/extra", data: Data([1]))],
        ]
        for (index, entries) in variants.enumerated() {
            let archive = f.parent.appendingPathComponent("unsafe-\(index).aagedalpeople.zip")
            try zip(entries, at: archive)
            let receiverRoot = f.parent.appendingPathComponent("unsafe-receiver-\(index)")
            XCTAssertThrowsError(try PeopleLibraryPackageService().importPackage(
                at: archive, into: .init(root: receiverRoot)), "variant \(index)") { error in
                if index == 1 || index == 2 || index == 5 {
                    XCTAssertEqual(error as? PeopleLibraryPackageService.Failure, .unsafeFile)
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiverRoot.path), "variant \(index)")
            try assertNoStages(f)
        }
    }

    func testZIPRejectsDeclaredExpansionAndCorruptionWithoutLeavingStage() throws {
        let f = try fixture()
        var oversized = try packageEntries(f)
        let payloadIndex = try XCTUnwrap(oversized.firstIndex { $0.name == PeopleLibraryManifest.payloadFileName })
        oversized[payloadIndex].declaredSize = UInt32(PeopleLibraryManifest.Limits().maximumFileBytes + 1)
        let oversizedURL = f.parent.appendingPathComponent("oversized.aagedalpeople.zip")
        try zip(oversized, at: oversizedURL)
        let oversizedRoot = f.parent.appendingPathComponent("oversized-receiver")
        XCTAssertThrowsError(try PeopleLibraryPackageService().importPackage(at: oversizedURL, into: .init(root: oversizedRoot)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversizedRoot.path))

        var corrupt = try packageEntries(f)
        corrupt[payloadIndex].crcOverride = 0
        let corruptURL = f.parent.appendingPathComponent("corrupt.aagedalpeople.zip")
        try zip(corrupt, at: corruptURL)
        let corruptRoot = f.parent.appendingPathComponent("corrupt-receiver")
        XCTAssertThrowsError(try PeopleLibraryPackageService().importPackage(at: corruptURL, into: .init(root: corruptRoot)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptRoot.path))
        try assertNoStages(f)
    }

    func testZIPArchiveHardlinkIsRejectedBeforeRepositoryMutation() throws {
        let f = try fixture(), archive = f.parent.appendingPathComponent("shared.aagedalpeople.zip")
        try zip(try packageEntries(f), at: archive)
        let hardlink = f.parent.appendingPathComponent("linked.aagedalpeople.zip")
        try FileManager.default.linkItem(at: archive, to: hardlink)
        let receiverRoot = f.parent.appendingPathComponent("hardlink-receiver")
        XCTAssertThrowsError(try PeopleLibraryPackageService().importPackage(
            at: hardlink, into: .init(root: receiverRoot)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiverRoot.path))
        try assertNoStages(f)
    }

    func testEditorPayloadIsValidatedAndReexportedByteForByte() throws {
        let f = try fixture()
        let payloadBytes = try Data(contentsOf: f.snapshot.directoryURL.appendingPathComponent("people.json"))
        let payload = try PeopleLibraryPayload.decode(payloadBytes)
        let person = try XCTUnwrap(payload.people.first)
        let example = try XCTUnwrap(person.examples.first)
        let editorText = """
        { "examples" : {
            "\(example.id.uuidString.lowercased())" : { "recognitionMode" : "faceClothing", "addedAt" : 42.125,
              "sourceDescription" : "/private/source/Å.jpg" }
          },
          "people" : { "\(person.id.uuidString.lowercased())" : {
              "updatedAt" : 812345678.123456, "createdAt" : -0.125,
              "representativeThumbnailID" : "\(example.id.uuidString.lowercased())", "notes" : "  Preserve exactly {value}", "role" : "" } },
          "coreRevision" : "\(f.snapshot.manifest.coreRevision)", "libraryID" : "\(f.snapshot.manifest.libraryID.uuidString.lowercased())",
          "schemaVersion" : 1, "format" : "aagedal-photo-agent-known-people-editor" }
        """
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let editorBytes = Data(editorText.utf8)
        let descriptor = try PeopleLibraryManifest.EditorPayloadDescriptor(
            byteCount: editorBytes.count, sha256: sha(editorBytes)
        )
        let manifest = try PeopleLibraryManifest(
            libraryID: f.snapshot.manifest.libraryID,
            exportedAt: f.snapshot.manifest.exportedAt,
            exporter: f.snapshot.manifest.exporter,
            peopleCount: f.snapshot.manifest.peopleCount,
            embeddingCount: f.snapshot.manifest.embeddingCount,
            files: f.snapshot.manifest.files + [
                .init(path: descriptor.path, byteCount: descriptor.byteCount, sha256: descriptor.sha256)
            ],
            editorPayload: descriptor
        )
        let package = f.parent.appendingPathComponent("editor-source.aagedalpeople")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("embeddings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("editor"), withIntermediateDirectories: true)
        for declaration in f.snapshot.manifest.files {
            let source = f.snapshot.directoryURL.appendingPathComponent(declaration.path)
            let destination = package.appendingPathComponent(declaration.path)
            try Data(contentsOf: source).write(to: destination)
        }
        try editorBytes.write(to: package.appendingPathComponent(descriptor.path))
        try encoder.encode(manifest).write(to: package.appendingPathComponent(PeopleLibraryManifest.fileName))

        let repository = PeopleLibraryRepository(root: f.parent.appendingPathComponent("editor-receiver"))
        let imported = try PeopleLibraryPackageService().importPackage(at: package, into: repository)
        let output = f.parent.appendingPathComponent("editor-roundtrip.aagedalpeople")
        try PeopleLibraryPackageService().export(imported, to: output)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(descriptor.path)), editorBytes)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(PeopleLibraryManifest.fileName)),
                       try Data(contentsOf: imported.directoryURL.appendingPathComponent(PeopleLibraryManifest.fileName)))
        let secondRepository = PeopleLibraryRepository(root: f.parent.appendingPathComponent("editor-second-receiver"))
        let second = try PeopleLibraryPackageService().importPackage(at: output, into: secondRepository)
        let secondOutput = f.parent.appendingPathComponent("editor-second-roundtrip.aagedalpeople")
        try PeopleLibraryPackageService().export(second, to: secondOutput)
        XCTAssertEqual(try Data(contentsOf: secondOutput.appendingPathComponent(descriptor.path)), editorBytes)
        XCTAssertEqual(second.manifest.coreRevision, f.snapshot.manifest.coreRevision)
        XCTAssertNotEqual(second.manifest.revision, f.snapshot.manifest.revision)
    }

    func testExistingAndConcurrentlyCreatedDestinationsAreNeverReplaced() throws {
        let f = try fixture()
        let output = f.parent.appendingPathComponent("occupied.aagedalpeople")
        let sentinel = Data("Keep existing user content".utf8)
        let racing = PeopleLibraryPackageService(beforePublish: {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try sentinel.write(to: output.appendingPathComponent("sentinel"))
        })
        XCTAssertThrowsError(try racing.export(f.snapshot, to: output))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("sentinel")), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["sentinel"])
        XCTAssertThrowsError(try PeopleLibraryPackageService().export(f.snapshot, to: output))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("sentinel")), sentinel)
        XCTAssertEqual(try stages(f).count, 1)
    }

    func testFailureAndChangedSourcePreserveStagesAfterExternalHook() throws {
        let f = try fixture(), output = f.parent.appendingPathComponent("failed.aagedalpeople")
        let unrelated = f.parent.appendingPathComponent("unrelated"); try Data([1, 2, 3]).write(to: unrelated)
        XCTAssertThrowsError(try PeopleLibraryPackageService(beforePublish: { throw Failure.injected }).export(f.snapshot, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try stages(f).count, 1)
        let vectorPath = try XCTUnwrap(f.snapshot.manifest.files.first { $0.path.hasSuffix(".fem2") }).path
        let vectorURL = f.snapshot.directoryURL.appendingPathComponent(vectorPath)
        let changed = PeopleLibraryPackageService(beforePublish: {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vectorURL.path)
            var bytes = try Data(contentsOf: vectorURL); bytes[8] ^= 1; try bytes.write(to: vectorURL)
        })
        XCTAssertThrowsError(try changed.export(f.snapshot, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([1, 2, 3]))
        XCTAssertEqual(try stages(f).count, 2)
    }

    func testTighterImportLimitsFailBeforeReceivingRepositoryMutation() throws {
        let f = try fixture()
        let package = f.parent.appendingPathComponent("bounded.aagedalpeople")
        try PeopleLibraryPackageService().export(f.snapshot, to: package)
        var limits = PeopleLibraryManifest.Limits(); limits.maximumFileBytes = 1
        let receiverRoot = f.parent.appendingPathComponent("limit-receiver")
        let receiver = PeopleLibraryRepository(root: receiverRoot)
        XCTAssertThrowsError(try PeopleLibraryPackageService(limits: limits).importPackage(at: package, into: receiver))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiverRoot.path))
        XCTAssertEqual(try f.repository.currentSnapshot()?.manifest, f.snapshot.manifest)
        try assertNoStages(f)
    }

    func testSubstitutedStageChildIsPreservedAfterHookFailure() throws {
        let f = try fixture(), output = f.parent.appendingPathComponent("substituted.aagedalpeople")
        let replacement = Data("Foreign replacement must remain".utf8)
        let service = PeopleLibraryPackageService(beforePublish: {
            let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.parent, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".aagedalpeople-export-") })
            let child = stage.appendingPathComponent("people.json")
            try FileManager.default.removeItem(at: child)
            try replacement.write(to: child)
        })
        XCTAssertThrowsError(try service.export(f.snapshot, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let stage = try XCTUnwrap(stages(f).first)
        XCTAssertEqual(try stages(f).count, 1)
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("people.json")), replacement)
        XCTAssertEqual(try f.repository.currentSnapshot()?.manifest, f.snapshot.manifest)
    }

    func testSymlinkHardlinkAndWrongPackageExtensionAreRejected() throws {
        let f = try fixture(), service = PeopleLibraryPackageService()
        let output = f.parent.appendingPathComponent("blocked.aagedalpeople")
        let alias = f.parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.snapshot.directoryURL)
        let aliased = PeopleLibrarySnapshot(manifest: f.snapshot.manifest, gallery: f.snapshot.gallery, directoryURL: alias)
        XCTAssertThrowsError(try service.export(aliased, to: output))
        let payload = f.snapshot.directoryURL.appendingPathComponent("people.json")
        try FileManager.default.linkItem(at: payload, to: f.parent.appendingPathComponent("payload-hardlink"))
        XCTAssertThrowsError(try service.export(f.snapshot, to: output))
        XCTAssertThrowsError(try service.export(f.snapshot, to: f.parent.appendingPathComponent("wrong.zip")))
        let receiverRoot = f.parent.appendingPathComponent("unused-receiver")
        XCTAssertThrowsError(try service.importPackage(at: alias, into: .init(root: receiverRoot)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiverRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStages(f)
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func le32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16)); append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
