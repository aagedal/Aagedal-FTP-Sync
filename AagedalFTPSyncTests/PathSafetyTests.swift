import XCTest
@testable import AagedalFTPSync

final class PathSafetyTests: XCTestCase {
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
}
