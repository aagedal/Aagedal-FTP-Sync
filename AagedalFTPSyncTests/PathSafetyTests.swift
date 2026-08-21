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
}
