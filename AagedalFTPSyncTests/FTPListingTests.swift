import Network
import XCTest
@testable import AagedalFTPSync

final class FTPListingTests: XCTestCase {
    func testParsesMachineReadableListing() throws {
        let listing = """
        modify=20260821122345;size=43121;type=file; NEWS_001.JPG\r
        modify=20260821122350;size=98122;type=file; NEWS 002.CR3\r
        modify=20260821122000;type=dir; selects\r
        type=cdir; .\r
        """
        let entries = FTPEndpointSession.parseMLSD(listing)
        XCTAssertEqual(entries.map(\.name), ["NEWS_001.JPG", "NEWS 002.CR3", "selects"])
        XCTAssertEqual(entries[0].size, 43_121)
        XCTAssertTrue(entries[2].isDirectory)
    }

    func testParsesMDTMModificationDateAsUTC() throws {
        let date = try XCTUnwrap(FTPConnection.parseModificationDate("213 20260830080942.125"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                       DateComponents(year: 2026, month: 8, day: 30, hour: 8, minute: 9, second: 42))
    }

    func testNoDataNetworkErrorIsTreatedAsEndOfStream() {
        XCTAssertTrue(NetworkStream.isEndOfStream(.posix(.ENODATA)))
        XCTAssertFalse(NetworkStream.isEndOfStream(.posix(.ECONNRESET)))
    }
}
