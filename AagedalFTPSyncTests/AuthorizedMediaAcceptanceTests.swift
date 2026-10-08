import CryptoKit
import Foundation
import ImageIO
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

/// Operator-supplied images are read-only. No photos, labels or paths are checked in.
/// The manifest contains `files: [absolute paths]` and an empty, disposable `outputRoot`.
final class AuthorizedMediaAcceptanceTests: XCTestCase {
    private struct Manifest: Decodable {
        let files: [String]
        let outputRoot: String
    }

    private func manifest() throws -> Manifest {
        guard let path = ProcessInfo.processInfo.environment["AAGEDAL_REAL_MEDIA_MANIFEST"] else {
            throw XCTSkip("Set AAGEDAL_REAL_MEDIA_MANIFEST for authorized real-image acceptance")
        }
        let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard !value.files.isEmpty else { throw XCTSkip("The authorized image manifest is empty") }
        return value
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func pixels(_ url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }

    private func endpoint(_ url: URL) throws -> Endpoint {
        let bookmark = try FolderBookmark.create(for: url)
        return Endpoint(kind: .local, localPath: bookmark.resolvedURL.path, bookmark: bookmark.data)
    }

    func testOptInCameraMediaTransferReprocessAndIntegrity() async throws {
        let manifest = try manifest()
        let root = URL(fileURLWithPath: manifest.outputRoot, isDirectory: true)
        // Never reuse an existing directory: these fixtures may be removed/changed by sync.
        guard !FileManager.default.fileExists(atPath: root.path) else {
            XCTFail("Real-image outputRoot must be a new disposable directory")
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, path) in manifest.files.enumerated() {
            let original = URL(fileURLWithPath: path)
            let originalHash = try digest(original)
            let isRAW = MetadataWriter.usesXMPSidecar(for: original.lastPathComponent)
            for managed in [false, true] {
                let sample = root.appendingPathComponent("sample-\(index)-\(managed ? "managed" : "ordinary")")
                let source = sample.appendingPathComponent("source")
                let destination = sample.appendingPathComponent("destination")
                for folder in [source, destination] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                let name = "FX_sample." + original.pathExtension.lowercased()
                let input = source.appendingPathComponent(name)
                try FileManager.default.copyItem(at: original, to: input)
                let originalSidecar = original.deletingPathExtension().appendingPathExtension("xmp")
                let sidecarHash = isRAW && FileManager.default.fileExists(atPath: originalSidecar.path)
                    ? try digest(originalSidecar) : nil
                if sidecarHash != nil {
                    try FileManager.default.copyItem(at: originalSidecar,
                        to: input.deletingPathExtension().appendingPathExtension("xmp"))
                }
                try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: input.path)
                let originalPixels = isRAW ? nil : try pixels(input)
                var job = try SyncJob(name: "Disposable camera-media acceptance", left: endpoint(source),
                    right: endpoint(destination), direction: .leftToRight, filter: FileFilter(preset: .photos),
                    intervalSeconds: 5, isEnabled: false)
                job.startsOnAppLaunch = false
                job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
                if managed { job.processedFilesLocation = .processedSubfolder }
                let photographer = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "")
                var fields = ScheduledMetadataFields()
                fields.setHeadline(try .activated("{photographer} {date:YYYY-MM-DD}"))
                job.metadataAutomation = MetadataAutomation(isEnabled: true, timestampPolicy: .sourceModification,
                    existingFieldPolicy: .overwrite, photographers: [photographer],
                    clips: [.init(photographerID: photographer.id, name: "Disposable", startsAt: frozen.addingTimeInterval(-60),
                                  endsAt: frozen.addingTimeInterval(60), fields: fields)])
                let engine = SyncEngine(
                    sourceSignatureRepository: SourceSignatureRepository(fileURL: sample.appendingPathComponent("signatures.sqlite")),
                    downloadManifestRepository: DownloadManifestRepository(fileURL: sample.appendingPathComponent("manifest.json")),
                    now: { Date(timeIntervalSince1970: 1_704_153_600) })
                let first = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(first.transferred, 1)
                XCTAssertEqual(first.metadataReport.applied, 1)
                let outputFolder = managed ? destination.appendingPathComponent("Synced Files") : destination
                let output = outputFolder.appendingPathComponent(name)
                let outputMetadata = isRAW
                    ? try XMPSidecar.read(from: output.deletingPathExtension().appendingPathExtension("xmp"))
                    : try XCTUnwrap(ImageMetadata.read(from: output).xmp)
                XCTAssertEqual(outputMetadata.headline, "Fixture 2024-01-02")
                let repeatRun = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
                XCTAssertEqual(repeatRun.transferred, 0)
                job.metadataAutomation?.clips[0].fields.setHeadline(try .activated("Revision {photographer} {date:YYYY-MM-DD}"))
                let beforePreview = try digest(output)
                let sidecar = output.deletingPathExtension().appendingPathExtension("xmp")
                let beforePreviewSidecar = isRAW ? try digest(sidecar) : nil
                let preflight = try await engine.reprocessExistingLocalFiles(job: job, isPreflight: true)
                XCTAssertEqual(preflight.applied, 1)
                XCTAssertEqual(try digest(output), beforePreview)
                if isRAW { XCTAssertEqual(try digest(sidecar), beforePreviewSidecar) }
                let reprocessed = try await engine.reprocessExistingLocalFiles(job: job)
                XCTAssertEqual(reprocessed.applied, 1)
                XCTAssertEqual(reprocessed.failed, 0)
                XCTAssertEqual(try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, frozen)
                if isRAW { XCTAssertEqual(try digest(output), originalHash) }
                else { XCTAssertEqual(try pixels(output), originalPixels) }
                if managed {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
                    let processed = destination.appendingPathComponent("Processed Files").appendingPathComponent(name)
                    if isRAW { XCTAssertEqual(try digest(processed), originalHash) }
                    else { XCTAssertEqual(try pixels(processed), originalPixels) }
                } else { XCTAssertEqual(try digest(input), originalHash) }
                // Exercise the same place/name writer used by admitted enrichment.
                // Keep this separate from the engine output and its durable receipt.
                let readerFolder = sample.appendingPathComponent("external-reader")
                try FileManager.default.createDirectory(at: readerFolder, withIntermediateDirectories: true)
                let readerCopy = readerFolder.appendingPathComponent(name)
                try FileManager.default.copyItem(at: output, to: readerCopy)
                let readerSidecar = readerCopy.deletingPathExtension().appendingPathExtension("xmp")
                if isRAW { try FileManager.default.copyItem(at: sidecar, to: readerSidecar) }
                _ = try MetadataWriter.apply(.init(places: .init(city: "Oslo", country: "Norway",
                    cityPolicy: .overwrite, countryPolicy: .overwrite),
                    faceNames: .init(names: ["Acceptance ÆØÅ"], appendToKeywords: false)),
                    to: readerCopy, relativePath: name)
                let reread = isRAW ? try XMPSidecar.read(from: readerSidecar) : try XCTUnwrap(ImageMetadata.read(from: readerCopy).xmp)
                XCTAssertEqual(reread.headline, "Revision Fixture 2024-01-02")
                XCTAssertEqual(reread.city, "Oslo")
                XCTAssertEqual(reread.country, "Norway")
                XCTAssertTrue(reread.personInImage.contains("Acceptance ÆØÅ"))
                if isRAW { XCTAssertEqual(try digest(readerCopy), originalHash) }
                else { XCTAssertEqual(try pixels(readerCopy), originalPixels) }
                XCTAssertEqual(try digest(original), originalHash)
                if let sidecarHash { XCTAssertEqual(try digest(originalSidecar), sidecarHash) }
                print("AUTHORIZED_MEDIA_PASS sample=\(index) format=\(original.pathExtension.lowercased()) managed=\(managed) sourceUnchanged=true")
            }
        }
    }

    func testOptInBundledModelDecodesAuthorizedImages() async throws {
        let manifest = try manifest()
        let runtime = try BundledAuraFaceModel.admit()
        for (index, path) in manifest.files.enumerated() {
            let url = URL(fileURLWithPath: path)
            let before = try digest(url)
            let observations = try await runtime.analyze(imageURL: url, maximumFaces: 64)
            XCTAssertTrue(observations.allSatisfy { $0.embedding.values.allSatisfy(\.isFinite) })
            XCTAssertEqual(try digest(url), before)
            print("AUTHORIZED_FACE_DECODE sample=\(index) format=\(url.pathExtension.lowercased()) faces=\(observations.count)")
        }
        // Detection/runtime coverage only; this is not labeled recognition accuracy.
    }
}
