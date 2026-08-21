import XCTest
@testable import AagedalFTPSync

final class FileFilterTests: XCTestCase {
    func testPhotoPresetIncludesJPEGAndRAW() {
        let filter = FileFilter(preset: .photos)
        XCTAssertTrue(filter.includes(path: "desk/NEWS_001.JPG", modifiedAt: Date()))
        XCTAssertTrue(filter.includes(path: "desk/NEWS_002.CR3", modifiedAt: Date()))
        XCTAssertTrue(filter.includes(path: "desk/NEWS_003.NEF", modifiedAt: Date()))
        XCTAssertFalse(filter.includes(path: "desk/notes.txt", modifiedAt: Date()))
    }

    func testCustomExtensionsAreCaseInsensitive() {
        let filter = FileFilter(preset: .custom, customExtensions: "MXF, wav")
        XCTAssertTrue(filter.includes(path: "clip.MXF", modifiedAt: Date()))
        XCTAssertTrue(filter.includes(path: "audio.WAV", modifiedAt: Date()))
        XCTAssertFalse(filter.includes(path: "image.jpg", modifiedAt: Date()))
    }

    func testRecentWindowRejectsOldFile() {
        let filter = FileFilter(preset: .all, recentHours: 1)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(filter.includes(path: "new.jpg", modifiedAt: now.addingTimeInterval(-3_599), now: now))
        XCTAssertFalse(filter.includes(path: "old.jpg", modifiedAt: now.addingTimeInterval(-3_601), now: now))
    }
}
