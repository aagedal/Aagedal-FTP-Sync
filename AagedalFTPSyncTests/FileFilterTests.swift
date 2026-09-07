import XCTest
@testable import AagedalFTPSync

final class FileFilterTests: XCTestCase {
    func testAllMediaIncludesPhotosVideoAndAudioButExcludesOtherFiles() {
        let filter = FileFilter(preset: .allMedia)
        for path in ["photo.JPG", "photo.HEIC", "photo.CR3", "photo.NEF", "clip.MOV", "clip.MXF", "clip.mp4", "sound.WAV", "sound.mp3", "sound.flac"] {
            XCTAssertTrue(filter.includesFileType(path: path), path)
        }
        for path in ["document.pdf", "document.doc", "document.docx", "notes.txt", "archive.zip", "photo.xmp", "README", ".hidden.jpg"] {
            XCTAssertFalse(filter.includesFileType(path: path), path)
        }
    }

    func testAudioIncludesCommonAudioFormatsOnly() {
        let filter = FileFilter(preset: .audio)
        for ext in ["AAC", "AIF", "AIFF", "ALAC", "BWF", "CAF", "FLAC", "M4A", "MP3", "OGA", "OGG", "OPUS", "WAV", "WAVE", "WMA"] {
            XCTAssertTrue(filter.includesFileType(path: "recording.\(ext)"), ext)
        }
        for path in ["photo.jpg", "photo.cr3", "clip.mov", "clip.mp4", "document.pdf", "document.docx"] {
            XCTAssertFalse(filter.includesFileType(path: path), path)
        }
    }

    func testMediaPresetsPersist() throws {
        for preset in [FilterPreset.allMedia, .audio] {
            let filter = FileFilter(preset: preset)
            let decoded = try JSONDecoder().decode(FileFilter.self, from: JSONEncoder().encode(filter))
            XCTAssertEqual(decoded, filter)
        }
    }

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
