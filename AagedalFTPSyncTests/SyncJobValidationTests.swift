import Foundation
import XCTest
@testable import AagedalFTPSync

final class SyncJobValidationTests: XCTestCase {
    func testMinimumCheckIntervalIsFiveSeconds() {
        var job = validJob(direction: .leftToRight)
        job.intervalSeconds = 4
        XCTAssertEqual(job.validationMessage, "The interval must be at least 5 seconds.")
        job.intervalSeconds = 5
        XCTAssertNil(job.validationMessage)
    }

    func testImportedLegacyCheckIntervalIsRaisedToFiveSeconds() {
        var job = validJob(direction: .leftToRight)
        job.intervalSeconds = 2
        XCTAssertEqual(job.preparedForImport().intervalSeconds, 5)
        job.intervalSeconds = 60
        XCTAssertEqual(job.preparedForImport().intervalSeconds, 60)
    }

    func testImageOutputFolderFollowsStorageAndPhotographerSorting() throws {
        let photographer = PhotographerProfile(
            name: "Jane/News: Desk", filenamePrefix: "JAD", creator: "Jane/News: Desk", copyrightNotice: ""
        )
        for direction in [SyncDirection.leftToRight, .rightToLeft] {
            var job = validJob(direction: direction)
            job.left = Endpoint(kind: .local, localPath: "/LeftPhotos", bookmark: Data([1]))
            job.right = Endpoint(kind: .local, localPath: "/RightPhotos", bookmark: Data([1]))
            job.metadataAutomation = MetadataAutomation(photographers: [photographer])
            // Sorting only applies when processed-file storage is configured.
            job.sortsProcessedFilesByPhotographer = true
            var folder = try XCTUnwrap(job.imageOutputFolder(for: photographer))
            XCTAssertEqual(folder.endpoint, job.destinationEndpoint)
            XCTAssertNil(folder.managedFolder)
            XCTAssertNil(folder.photographerFolder)

            job.processedFilesLocation = .processedSubfolder
            folder = try XCTUnwrap(job.imageOutputFolder(for: photographer))
            XCTAssertEqual(folder.endpoint, job.destinationEndpoint)
            XCTAssertEqual(folder.managedFolder?.directoryName, "Processed Files")
            XCTAssertEqual(folder.photographerFolder, "Jane News Desk (JAD)")

            job.sortsProcessedFilesByPhotographer = false
            XCTAssertNil(job.imageOutputFolder(for: photographer)?.photographerFolder)

            let custom = Endpoint(kind: .local, localPath: "/CustomPhotos", bookmark: Data([1]))
            job.processedFilesLocation = .customFolder
            job.processedFolder = custom
            folder = try XCTUnwrap(job.imageOutputFolder(for: photographer))
            XCTAssertEqual(folder.endpoint, custom)
            XCTAssertNil(folder.managedFolder)
            XCTAssertNil(folder.photographerFolder)

            job.sortsProcessedFilesByPhotographer = true
            XCTAssertEqual(job.imageOutputFolder(for: photographer)?.photographerFolder, "Jane News Desk (JAD)")
        }
    }

    func testImageOutputFolderDisambiguatesPhotographersAndRejectsMissingDestination() throws {
        let first = PhotographerProfile(name: "Jane", filenamePrefix: "JAD", creator: "Jane", copyrightNotice: "")
        let second = PhotographerProfile(name: "Jane", filenamePrefix: "JAD", creator: "Jane", copyrightNotice: "")
        var job = validJob(direction: .leftToRight)
        job.metadataAutomation = MetadataAutomation(photographers: [first, second])
        job.processedFilesLocation = .processedSubfolder
        job.sortsProcessedFilesByPhotographer = true
        let firstFolder = try XCTUnwrap(job.imageOutputFolder(for: first)?.photographerFolder)
        let secondFolder = try XCTUnwrap(job.imageOutputFolder(for: second)?.photographerFolder)
        XCTAssertNotEqual(firstFolder, secondFolder)
        XCTAssertTrue(firstFolder.hasPrefix("Jane (JAD) ["))
        job.direction = .bidirectional
        XCTAssertNil(job.imageOutputFolder(for: first))
        job.processedFilesLocation = .customFolder
        job.processedFolder = nil
        XCTAssertNil(job.imageOutputFolder(for: first))
    }

    func testOrdinaryLocalJobsRejectOverlappingFoldersInEveryDirection() {
        for direction in [SyncDirection.leftToRight, .rightToLeft, .bidirectional] {
            for (left, right) in [("/Photos", "/Photos/Backup"), ("/Photos/Backup", "/Photos"), ("/Photos", "/Photos"), ("/", "/Photos")] {
                var job = validJob(direction: direction)
                job.left = Endpoint(kind: .local, localPath: left, bookmark: Data([1]))
                job.right = Endpoint(kind: .local, localPath: right, bookmark: Data([1]))
                XCTAssertEqual(job.validationMessage, "Source and destination folders must not overlap.")
            }
        }
    }

    func testSiblingFoldersWithCommonPrefixAreAllowed() {
        var job = validJob(direction: .leftToRight)
        job.left = Endpoint(kind: .local, localPath: "/Photos", bookmark: Data([1]))
        job.right = Endpoint(kind: .local, localPath: "/PhotosBackup", bookmark: Data([1]))
        XCTAssertNil(job.validationMessage)
    }

    func testOrdinaryLocalJobRejectsSymlinkToSourceDescendant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Photos")
        let destination = source.appendingPathComponent("Backup")
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        var job = validJob(direction: .leftToRight)
        job.left = Endpoint(kind: .local, localPath: source.path, bookmark: Data([1]))
        job.right = Endpoint(kind: .local, localPath: alias.path, bookmark: Data([1]))
        XCTAssertEqual(job.validationMessage, "Source and destination folders must not overlap.")
    }

    func testCleanupAcceptsOneWayLocalTargetWithLongerRetention() {
        var job = validJob(direction: .leftToRight)
        job.filter.recentHours = 1
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertNil(job.validationMessage)
    }

    func testCleanupRejectsTwoWayJobs() {
        var job = validJob(direction: .bidirectional)
        job.filter.recentHours = 1
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Automatic cleanup is only available for one-way jobs.")
    }

    func testCleanupRequiresLocalTarget() {
        var job = validJob(direction: .rightToLeft)
        job.filter.recentHours = 1
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Automatic cleanup is only available when the target is a local folder.")
    }

    func testCleanupRequiresSourceAgeWindow() {
        var job = validJob(direction: .leftToRight)
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Choose a source file-age window before enabling automatic cleanup.")
    }

    func testCleanupMustBeOlderThanSourceWindow() {
        var job = validJob(direction: .leftToRight)
        job.filter.recentHours = 2
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "The cleanup age must be greater than the source file-age window.")
    }

    func testCleanupRejectsOverlappingLocalFolders() {
        let bookmark = Data([1])
        var job = SyncJob(
            name: "Test",
            left: Endpoint(kind: .local, localPath: "/Pictures", bookmark: bookmark),
            right: Endpoint(kind: .local, localPath: "/Pictures/target", bookmark: bookmark),
            direction: .leftToRight,
            filter: FileFilter(preset: .photos, recentHours: 1),
            intervalSeconds: 5,
            isEnabled: false
        )
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        XCTAssertEqual(job.validationMessage, "Source and target folders must not overlap when cleanup is enabled.")
    }

    func testProcessedFolderPreferencesCanBeSavedBeforeMetadataSetup() {
        var job = validJob(direction: .leftToRight)
        job.processedFolder = Endpoint(
            kind: .local,
            localPath: "/Users/example/Processed",
            bookmark: Data([1])
        )

        job.sortsProcessedFilesByPhotographer = true
        XCTAssertNil(job.validationMessage)

        job.processedFilesLocation = .processedSubfolder
        job.processedFolder = nil
        XCTAssertNil(job.validationMessage)

        job.metadataAutomation = validMetadataAutomation()
        job.metadataAutomation?.isEnabled = false
        XCTAssertNil(job.validationMessage)
    }

    func testProcessedFolderRejectsTwoWayJobs() {
        var job = validJob(direction: .bidirectional)
        job.metadataAutomation = validMetadataAutomation()
        job.processedFolder = Endpoint(
            kind: .local,
            localPath: "/Users/example/Processed",
            bookmark: Data([1])
        )

        XCTAssertEqual(
            job.validationMessage,
            "Moving processed files is only available for one-way jobs."
        )
    }

    func testProcessedFolderMustNotOverlapLocalDestination() {
        var job = validJob(direction: .leftToRight)
        job.metadataAutomation = validMetadataAutomation()
        job.processedFolder = Endpoint(
            kind: .local,
            localPath: "/Users/example/Pictures/Processed",
            bookmark: Data([1])
        )

        XCTAssertEqual(
            job.validationMessage,
            "The processed folder must be separate from the source and destination folders."
        )
    }

    func testManagedProcessedStructureUsesLocalDestinationAsMainFolder() {
        var job = validJob(direction: .leftToRight)
        job.metadataAutomation = validMetadataAutomation()
        job.processedFilesLocation = .processedSubfolder
        job.sortsProcessedFilesByPhotographer = true

        XCTAssertNil(job.validationMessage)
        XCTAssertTrue(job.movesProcessedFiles)
        XCTAssertTrue(job.usesManagedFolderStructure)
        XCTAssertEqual(
            job.localDestinationDisplayPath,
            "/Users/example/Pictures/Synced Files"
        )
    }

    func testManagedProcessedStructureRejectsOverlappingLocalSource() {
        let bookmark = Data([1])
        var job = SyncJob(
            name: "Test",
            left: Endpoint(
                kind: .local,
                localPath: "/Users/example/Pictures/incoming",
                bookmark: bookmark
            ),
            right: Endpoint(
                kind: .local,
                localPath: "/Users/example/Pictures",
                bookmark: bookmark
            ),
            direction: .leftToRight,
            intervalSeconds: 5,
            isEnabled: false
        )
        job.metadataAutomation = validMetadataAutomation()
        job.processedFilesLocation = .processedSubfolder

        XCTAssertEqual(
            job.validationMessage,
            "The managed main folder must be separate from the local source folder."
        )
    }

    private func validJob(direction: SyncDirection) -> SyncJob {
        let remote = Endpoint(
            kind: .sftp,
            host: "photos.example.com",
            username: "desk",
            remotePath: "/incoming",
            hostKeyFingerprint: "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"
        )
        let local = Endpoint(
            kind: .local,
            localPath: "/Users/example/Pictures",
            bookmark: Data([1])
        )
        return SyncJob(
            name: "Test",
            left: remote,
            right: local,
            direction: direction,
            intervalSeconds: 5,
            isEnabled: false
        )
    }

    private func validMetadataAutomation() -> MetadataAutomation {
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: ""
        )
        return MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [MetadataScheduleClip(
                photographerID: photographer.id,
                name: "Assignment",
                startsAt: Date(timeIntervalSince1970: 100),
                endsAt: Date(timeIntervalSince1970: 200)
            )]
        )
    }
}
