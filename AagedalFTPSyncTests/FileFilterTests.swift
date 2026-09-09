import XCTest
@testable import AagedalFTPSync

final class FileFilterTests: XCTestCase {
    func testLexicalFileExtensionsPreserveFilenameAndPathEdges() {
        let filter = FileFilter(preset: .jpeg, includeHiddenFiles: true)
        for path in ["photo.JPG", "folder/photo.jpeg", "/folder/photo.JpG", "photo.jpg/", "photo.jpg//",
                     "folder.jpg/", "./photo.jpg", "../photo.jpg", "folder/.hidden.jpg", ".hidden.JPG",
                     "photo..jpg", "....jpg", "folder.with.dots/東京 é🎞️.JPG", "folder/Cafe\u{301}.jpeg",
                     "photo?#%.jpg", "photo%2Fname.jpg", "folder/photo\\name.jpg", "photo:name.jpg"] {
            XCTAssertTrue(filter.includesFileType(path: path), path)
        }
        for path in ["photo", "folder.jpg/photo", "photo.jpg.", ".jpg", "..jpg", "...jpg",
                     "photo.jpg?query", "photo.jpg#fragment", "photo.jpg%20", "photo.%6apg",
                     "photo.jpg.txt", "photo.ｊｐｇ", "/"] {
            XCTAssertFalse(filter.includesFileType(path: path), path)
        }
        let visible = FileFilter(preset: .jpeg)
        for path in [".hidden.jpg", ".folder/photo.jpg", "./photo.jpg", "../photo.jpg"] {
            XCTAssertFalse(visible.includesFileType(path: path), path)
        }
    }

    func testExtensionExtractionMatchesLegacyURLForDirectoryOnlyAndUnusualInputs() {
        // These inputs are outside normal scanner filenames, but the filter API
        // previously resolved terminal dot components/current-directory inputs.
        // Compare to that behavior without assuming the test runner's directory.
        let paths = ["", ".", "..", "./", "../", "/", "//", "folder.jpg/.", "folder.jpg/.//",
                     "folder.jpg/sub/..", "folder.jpg/sub/../", "folder.jpg/./.", "folder.jpg/./..",
                     "/folder.jpg/sub/..", "a.JPG/../../..", "~/photo.jpg", "file:///photo.jpg"]
        for preset in [FilterPreset.jpeg, .photos, .custom] {
            let filter = FileFilter(preset: preset, customExtensions: "jpg, jpeg, aagedal", includeHiddenFiles: true)
            let extensions = filter.allowedExtensions!
            for path in paths {
                let previous = extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
                XCTAssertEqual(filter.includesFileType(path: path), previous, path)
            }
        }
    }

    func testStandardUploadExclusionIsOptInAndCaseInsensitive() throws {
        var filter = FileFilter(photographerInitials: "TA")
        XCTAssertFalse(filter.ignoresAFTPSyncUploads)
        XCTAssertTrue(filter.includesFilename(path: "TA_001_aftpsync.JPG"))
        filter.ignoresAFTPSyncUploads = true
        for path in ["TA_001_aftpsync.JPG", "folder/TA_001_AFTPSYNC.NEF", "TA_001_aftpsync.xmp", "TA_001_EDITED_aftpsync.jpg"] {
            XCTAssertFalse(filter.includesFilename(path: path), path)
        }
        XCTAssertTrue(filter.includesFilename(path: "TA_001.JPG"))
        XCTAssertTrue(filter.includesFilename(path: "folder_aftpsync/TA_001.JPG"))
        XCTAssertTrue(filter.includesFilename(path: "TA_001_aftpsync_copy.JPG"))
        XCTAssertEqual(try JSONDecoder().decode(FileFilter.self, from: JSONEncoder().encode(filter)), filter)
        let legacy = try JSONDecoder().decode(FileFilter.self, from: Data(#"{"preset":"photos","customExtensions":"jpg","includeHiddenFiles":false}"#.utf8))
        XCTAssertFalse(legacy.ignoresAFTPSyncUploads)
        XCTAssertTrue(legacy.includesFilename(path: "TA_001_aftpsync.JPG"))
    }

    func testFilenameInitialsAndExclusionsCombineWithTypeAndAge() {
        let now = Date()
        let filter = FileFilter(preset: .photos, recentHours: 1, photographerInitials: " ta, JAD, , ",
            excludedFilenamePrefixes: "TA_SKIP, EDITED_", excludedFilenameSuffixes: "_EDITED, _SENT")
        for path in ["folder/ta_001.JPG", "JAD0002.NEF", "_EDITED/TA_001.jpg"] {
            XCTAssertTrue(filter.includes(path: path, modifiedAt: now), path)
        }
        for path in ["other.jpg", "TA/photo.jpg", "xTA_001.jpg", "TA_SKIP001.jpg", "TA_001_edited.JPG",
                     "JAD_001_SENT.NEF", "EDITED_TA_001.jpg", "TA_001.txt", ".hidden/TA_001.jpg"] {
            XCTAssertFalse(filter.includes(path: path, modifiedAt: now), path)
        }
        XCTAssertFalse(filter.includes(path: "TA_001.jpg", modifiedAt: now.addingTimeInterval(-7200), now: now))
        XCTAssertTrue(filter.includesFileType(path: "TA_001.jpg"))
        XCTAssertFalse(filter.includesFileType(path: "TA_001_EDITED.jpg"))
        XCTAssertFalse(filter.includesFilename(path: "TA_001_EDITED.xmp"))
    }

    func testEmptyFilenameRulesAndLegacyFiltersPreserveBehavior() throws {
        let data = Data(#"{"preset":"all","customExtensions":"jpg","includeHiddenFiles":false}"#.utf8)
        let legacy = try JSONDecoder().decode(FileFilter.self, from: data)
        XCTAssertTrue(legacy.includes(path: "any.bin", modifiedAt: Date()))
        XCTAssertNil(legacy.photographerInitials)
        let empty = FileFilter(preset: .all, photographerInitials: " , ", excludedFilenamePrefixes: " , ", excludedFilenameSuffixes: " ")
        XCTAssertTrue(empty.includesFilename(path: "any.bin"))
        let configured = FileFilter(photographerInitials: "TA", excludedFilenameSuffixes: "_EDITED")
        XCTAssertEqual(try JSONDecoder().decode(FileFilter.self, from: JSONEncoder().encode(configured)), configured)
    }

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
