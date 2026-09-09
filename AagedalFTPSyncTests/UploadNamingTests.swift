import Foundation
import XCTest
@testable import AagedalFTPSync

final class UploadNamingTests: XCTestCase {
    func testStandardSuffixIsOptInAndCombinesWithCustomNaming() throws {
        let legacy = try JSONDecoder().decode(UploadNaming.self, from: Data(#"{"prefix":"EDIT_","suffix":"_SENT"}"#.utf8))
        XCTAssertFalse(legacy.addsStandardSuffix)
        XCTAssertEqual(try legacy.relativePath(for: "TA_001.JPG"), "EDIT_TA_001_SENT.JPG")
        XCTAssertFalse(UploadNaming().isEnabled)

        var naming = UploadNaming(addStandardSuffix: true)
        XCTAssertTrue(naming.isEnabled)
        XCTAssertEqual(try naming.relativePath(for: "desk/TA_001.JPG"), "desk/TA_001_aftpsync.JPG")
        XCTAssertEqual(try naming.relativePath(for: "desk/TA_001.NEF"), "desk/TA_001_aftpsync.NEF")
        XCTAssertEqual(try naming.relativePath(for: "desk/TA_001.xmp"), "desk/TA_001_aftpsync.xmp")
        XCTAssertEqual(try naming.relativePath(for: "README"), "README_aftpsync")
        XCTAssertEqual(try naming.relativePath(for: "TA_001_aftpsync.JPG"), "TA_001_aftpsync.JPG")
        XCTAssertEqual(try naming.relativePath(for: "TA_001_AFTPSYNC.JPG"), "TA_001_AFTPSYNC.JPG")
        naming.prefix = "EDIT_"
        naming.suffix = "_SENT"
        XCTAssertEqual(try naming.relativePath(for: "TA_001.JPG"), "EDIT_TA_001_SENT_aftpsync.JPG")
        XCTAssertEqual(try JSONDecoder().decode(UploadNaming.self, from: JSONEncoder().encode(naming)), naming)
        naming.addsStandardSuffix = false
        XCTAssertEqual(try naming.relativePath(for: "TA_001.JPG"), "EDIT_TA_001_SENT.JPG")
    }

    func testNamingPreservesDirectoriesExtensionsAndCompanions() throws {
        let naming = UploadNaming(prefix: "EDIT_", suffix: "_SENT")
        XCTAssertEqual(try naming.relativePath(for: "desk/TA_001.JPG"), "desk/EDIT_TA_001_SENT.JPG")
        XCTAssertEqual(try naming.relativePath(for: "desk/TA_001.NEF"), "desk/EDIT_TA_001_SENT.NEF")
        XCTAssertEqual(try naming.relativePath(for: "desk/TA_001.xmp"), "desk/EDIT_TA_001_SENT.xmp")
        XCTAssertEqual(try naming.relativePath(for: "README"), "EDIT_README_SENT")
        XCTAssertEqual(try naming.relativePath(for: "a.b.JPG"), "EDIT_a.b_SENT.JPG")
        XCTAssertEqual(try UploadNaming().relativePath(for: "TA_001.JPG"), "TA_001.JPG")
    }

    func testUnsafeAndOversizedNamesAreRejected() {
        for value in ["../", "bad\\", "bad:", "\n", "\0", " padded"] {
            XCTAssertNotNil(UploadNaming(prefix: value).validationMessage)
            XCTAssertNotNil(UploadNaming(suffix: value).validationMessage)
        }
        XCTAssertThrowsError(try UploadNaming(prefix: ".aagedal-sync-").relativePath(for: "TA.jpg"))
        XCTAssertThrowsError(try UploadNaming(suffix: String(repeating: "a", count: 256)).relativePath(for: "TA.jpg"))
        XCTAssertThrowsError(try UploadNaming(prefix: "EDIT_").relativePath(for: "../TA.jpg"))
    }

    func testNamingIsOnlyAllowedForOneWayUploadsAndPersists() throws {
        var job = SyncJob()
        job.left = Endpoint(kind: .local, localPath: "/Pictures", bookmark: Data([1]))
        job.right = Endpoint(kind: .ftp, host: "example.org", username: "editor")
        job.uploadNaming = UploadNaming(addStandardSuffix: true)
        job.filter.photographerInitials = "TA, JAD"
        job.filter.excludedFilenameSuffixes = "_SENT"
        XCTAssertNil(job.validationMessage)
        let decoded = try JSONDecoder().decode(SyncJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(decoded, job)
        XCTAssertEqual(job.portableCopy(includeMetadata: false).uploadNaming, job.uploadNaming)
        job.direction = .rightToLeft
        XCTAssertNotNil(job.validationMessage)
        swap(&job.left, &job.right)
        XCTAssertNil(job.validationMessage)
        job.direction = .bidirectional
        XCTAssertNotNil(job.validationMessage)
        job.uploadNaming = nil
        XCTAssertNil(job.validationMessage)
    }

    func testUploadsUseRenamedNamespaceAcrossRunsAndKeepLocalFiles() async throws {
        for (direction, marker) in [(.leftToRight, ""), (.rightToLeft, ""), (.leftToRight, "_aftpsync"), (.rightToLeft, "_aftpsync")] as [(SyncDirection, String)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let local = root.appendingPathComponent("local")
            let remoteRoot = root.appendingPathComponent("remote")
            for folder in [local, remoteRoot] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("desk"), withIntermediateDirectories: true)
            }
            func endpoint(_ url: URL) throws -> Endpoint {
                Endpoint(kind: .local, localPath: url.path,
                    bookmark: try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            }
            let sourceEndpoint = try endpoint(local)
            let source = try LocalEndpointSession(endpoint: sourceEndpoint)
            let destination = try LocalEndpointSession(endpoint: endpoint(remoteRoot))
            let files = ["desk/TA_001.JPG", "desk/TA_002.NEF", "desk/TA_002.xmp", "OTHER.JPG", "TA_003_SENT.JPG"]
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            for path in files {
                let url = local.appendingPathComponent(path)
                try Data(path.utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            var job = SyncJob()
            job.left = sourceEndpoint
            job.right = Endpoint(kind: .ftp, host: "example.org", username: "editor")
            job.direction = direction
            if direction == .rightToLeft { swap(&job.left, &job.right) }
            job.filter = FileFilter(photographerInitials: "TA", excludedFilenameSuffixes: "_SENT")
            job.uploadNaming = UploadNaming(prefix: "EDIT_", suffix: "_SENT", addStandardSuffix: !marker.isEmpty)
            let engine = SyncEngine(
                sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.sqlite")),
                downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
                sessionFactory: { entry, _, _ -> any EndpointSession in entry.kind.isRemote ? destination : source })
            let first = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(first.transferred, 2)
            let remoteFiles = try await destination.listFiles()
            XCTAssertEqual(Set(remoteFiles.keys), ["desk/EDIT_TA_001_SENT\(marker).JPG", "desk/EDIT_TA_002_SENT\(marker).NEF", "desk/EDIT_TA_002_SENT\(marker).xmp"])
            XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent("desk/EDIT_TA_002_SENT\(marker).xmp")), Data("desk/TA_002.xmp".utf8))
            let localFiles = try await source.listFiles()
            XCTAssertEqual(Set(localFiles.keys), Set(files))
            job.verifiesMatchingFileContents = true
            let second = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(second.transferred, 0)
            let updated = local.appendingPathComponent("desk/TA_001.JPG")
            try Data("updated photo".utf8).write(to: updated)
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(10)], ofItemAtPath: updated.path)
            let third = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(third.transferred, 1)
            XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent("desk/EDIT_TA_001_SENT\(marker).JPG")), Data("updated photo".utf8))
            let sidecar = local.appendingPathComponent("desk/TA_002.xmp")
            try Data("edited metadata".utf8).write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(20)], ofItemAtPath: sidecar.path)
            let metadataUpdate = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(metadataUpdate.transferred, 1)
            XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent("desk/EDIT_TA_002_SENT\(marker).xmp")), Data("edited metadata".utf8))
            let unchangedPair = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(unchangedPair.transferred, 0)
            try Data("other metadata!".utf8).write(to: sidecar)
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(20)], ofItemAtPath: sidecar.path)
            let checksumUpdate = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
            XCTAssertEqual(checksumUpdate.transferred, 1)
            XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent("desk/EDIT_TA_002_SENT\(marker).xmp")), Data("other metadata!".utf8))
            if !marker.isEmpty {
                // An original and an already-marked local file must not silently
                // overwrite each other when the marker is applied only once.
                try Data("separate marked copy".utf8).write(to: local.appendingPathComponent("desk/TA_001_aftpsync.JPG"))
                job.uploadNaming = UploadNaming(addStandardSuffix: true)
                do {
                    _ = try await engine.run(job: job, leftPassword: nil, rightPassword: nil)
                    XCTFail("Colliding marked uploads must be rejected")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Two source files would use the upload name"), error.localizedDescription)
                }
                let afterCollision = try await destination.listFiles()
                XCTAssertEqual(Set(afterCollision.keys), Set(remoteFiles.keys))
            }
        }
    }
}
