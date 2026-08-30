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

    func testDirectoryListingAccumulatorEnforcesMaximumSize() throws {
        var accumulator = BoundedDataAccumulator(maximumBytes: 5)
        try accumulator.append(Data("123".utf8), context: "test listing")
        try accumulator.append(Data("45".utf8), context: "test listing")

        XCTAssertEqual(String(decoding: accumulator.data, as: UTF8.self), "12345")
        XCTAssertThrowsError(try accumulator.append(Data("6".utf8), context: "test listing"))
    }

    func testFTPLineBufferRejectsOverlongLineWithoutDelimiter() {
        var buffer = FTPLineBuffer()
        buffer.append(Data("123456".utf8))

        XCTAssertThrowsError(try buffer.nextLine(maximumBytes: 5))
    }

    func testFTPLineBufferRejectsOverlongCompletedLine() {
        var buffer = FTPLineBuffer()
        buffer.append(Data("123456\r\n".utf8))

        XCTAssertThrowsError(try buffer.nextLine(maximumBytes: 5))
    }

    func testFTPLineBufferPreservesFollowingReply() throws {
        var buffer = FTPLineBuffer()
        buffer.append(Data("220 hello\r\n221 bye\r\n".utf8))

        XCTAssertEqual(try buffer.nextLine(maximumBytes: 64), "220 hello")
        XCTAssertEqual(try buffer.nextLine(maximumBytes: 64), "221 bye")
        XCTAssertNil(try buffer.nextLine(maximumBytes: 64))
    }
}
