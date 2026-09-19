import Foundation
import XCTest
@testable import AagedalFTPSync

final class PathSafetyTests: XCTestCase {
    func testSFTPRootResolutionRejectsCloseDuringValidationWithoutCachingStaleRoot() async throws {
        let transport = SFTPTransport(endpoint: Endpoint(kind: .sftp), password: "")
        do {
            _ = try await transport.resolvedRoot(
                getRealPath: { _ in "/old-root/" },
                getPermissions: { path in
                    XCTAssertEqual(path, "/old-root")
                    await transport.close()
                    return 0o040755
                }
            )
            XCTFail("A root from a closed connection must be discarded")
        } catch is CancellationError {
            // A successful response arriving after close must not revive the cache.
        }
        let root = try await transport.resolvedRoot(
            getRealPath: { _ in "/new-root/" }, getPermissions: { _ in 0o040755 }
        )
        XCTAssertEqual(root, "/new-root")
    }

    func testSFTPRootValidationFailureDoesNotCacheUnvalidatedPath() async throws {
        let transport = SFTPTransport(endpoint: Endpoint(kind: .sftp), password: "")
        do {
            _ = try await transport.resolvedRoot(
                getRealPath: { _ in "/unvalidated" },
                getPermissions: { _ in throw AppError.transferFailed("Injected failure") }
            )
            XCTFail("Validation should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Injected failure"))
        }
        let root = try await transport.resolvedRoot(
            getRealPath: { _ in "/validated" }, getPermissions: { _ in 0o040755 }
        )
        XCTAssertEqual(root, "/validated")
    }

    func testSFTPUploadRejectsChildSymlinkResolvingOutsideRoot() {
        XCTAssertThrowsError(try SFTPPathContainment.validateExistingParent(
            path: "/uploads/escape",
            permissions: 0o120777,
            canonicalPath: "/outside",
            root: "/uploads"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic link or special file"))
        }
    }

    func testAcceptsNestedRelativePaths() {
        XCTAssertTrue(PathSafety.isSafeRelativePath("assignment/selects/NEWS 001.CR3"))
    }

    func testRejectsTraversalAndAbsolutePaths() {
        XCTAssertFalse(PathSafety.isSafeRelativePath("../outside.jpg"))
        XCTAssertFalse(PathSafety.isSafeRelativePath("folder/../../outside.jpg"))
        XCTAssertFalse(PathSafety.isSafeRelativePath("/absolute.jpg"))
        XCTAssertFalse(PathSafety.isSafeRelativePath("folder//file.jpg"))
    }

    func testFTPListingDropsUnsafeNames() {
        let listing = """
        modify=20260821122345;size=10;type=file; good.jpg\r
        modify=20260821122345;size=10;type=file; ../outside.jpg\r
        """
        XCTAssertEqual(FTPEndpointSession.parseMLSD(listing).map(\.name), ["good.jpg"])
    }

    func testRecognizesReservedTransferStagingPaths() {
        XCTAssertTrue(PathSafety.isInternalStagingPath(".aagedal-sync-123.part"))
        XCTAssertTrue(PathSafety.isInternalStagingPath("folder/.aagedal-sync-123.backup"))
        XCTAssertFalse(PathSafety.isInternalStagingPath("folder/aagedal-sync-photo.jpg"))
    }

    func testDetectsCaseAndUnicodeEquivalentLocalPathCollisions() {
        XCTAssertEqual(
            PathSafety.localPathCollision(in: ["Selects/NEWS.JPG", "selects/news.jpg"]),
            ["Selects/NEWS.JPG", "selects/news.jpg"]
        )
        XCTAssertNotNil(PathSafety.localPathCollision(in: ["café.jpg", "cafe\u{301}.jpg"]))
        XCTAssertNil(PathSafety.localPathCollision(in: ["one.jpg", "two.jpg"]))
    }

    func testManagedOutputFolderRejectsExpectedDirectoryNameUsedByAFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(
            to: root.appendingPathComponent(ManagedOutputFolder.syncedFiles.directoryName)
        )

        XCTAssertThrowsError(
            try ManagedOutputFolder.syncedFiles.url(inside: root, createIfNeeded: true)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("already contains a file named Synced Files"))
        }
    }

    func testCollisionSelectionPreservesByteSortedDiagnosticsForEveryInputOrder() {
        // Swift String equality treats the two accents as equal. Compare bytes
        // so this also catches a changed diagnostic spelling, not only its key.
        let fixtures = [
            ["news.jpg", "NEWS.JPG", "News.jpg", "NEWS.JPG"],
            ["café.jpg", "cafe\u{301}.jpg", "CAFÉ.JPG", "café.jpg"],
            ["b.jpg", "B.JPG", "a.jpg", "A.JPG"],
            ["dir/Å.jpg", "DIR/A\u{30A}.JPG", "dir/å.jpg", "other.jpg"],
            ["one.jpg", "one.jpg", "two.jpg", "nested/one.jpg"]
        ]
        func reference(_ paths: [String]) -> [String]? {
            var seen: [String: String] = [:]
            for path in paths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                let key = PathSafety.localComparisonKey(path)
                if let prior = seen[key], !PathSafety.hasIdenticalRepresentation(prior, path) {
                    return [prior, path]
                }
                seen[key] = path
            }
            return nil
        }
        func permutations(_ paths: [String]) -> [[String]] {
            guard !paths.isEmpty else { return [[]] }
            return paths.indices.flatMap { index in
                var rest = paths
                let first = rest.remove(at: index)
                return permutations(rest).map { [first] + $0 }
            }
        }
        for fixture in fixtures {
            let expected = reference(fixture)?.map { Array($0.utf8) }
            for order in permutations(fixture) {
                XCTAssertEqual(PathSafety.localPathCollision(in: order)?.map { Array($0.utf8) }, expected)
            }
        }
        XCTAssertNil(PathSafety.localPathCollision(in: []))
    }
}
