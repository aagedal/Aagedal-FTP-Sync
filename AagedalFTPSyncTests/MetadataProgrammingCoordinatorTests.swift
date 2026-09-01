import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataProgrammingCoordinatorTests: XCTestCase {
    func testCopyAndPasteCoordinatesSelectionAndTargetTrack() {
        let calendar = utcCalendar
        let sourcePhotographerID = UUID()
        let targetPhotographerID = UUID()
        let firstStart = date(2026, 8, 29, 9, 0, calendar: calendar)
        let secondStart = date(2026, 8, 29, 11, 30, calendar: calendar)
        let targetStart = date(2026, 8, 30, 14, 15, calendar: calendar)
        let source = [
            MetadataScheduleClip(
                photographerID: sourcePhotographerID,
                name: "First",
                startsAt: firstStart,
                endsAt: firstStart.addingTimeInterval(3_600)
            ),
            MetadataScheduleClip(
                photographerID: sourcePhotographerID,
                name: "Second",
                startsAt: secondStart,
                endsAt: secondStart.addingTimeInterval(1_800)
            ),
        ]
        let coordinator = MetadataProgrammingCoordinator(calendar: calendar)
        coordinator.draft.clips = source
        coordinator.selectedClipIDs = Set(source.map(\.id))

        coordinator.copySelectedClips()
        coordinator.pasteClips(to: targetStart, on: targetPhotographerID)

        let pasted = coordinator.draft.clips
            .filter { coordinator.selectedClipIDs.contains($0.id) }
            .sorted { $0.startsAt < $1.startsAt }
        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(pasted.map(\.photographerID), [targetPhotographerID, targetPhotographerID])
        XCTAssertEqual(pasted[0].startsAt, targetStart)
        XCTAssertEqual(pasted[1].startsAt.timeIntervalSince(pasted[0].startsAt), 2.5 * 3_600)
        XCTAssertEqual(coordinator.playhead, TimelinePlayhead(
            photographerID: targetPhotographerID,
            date: targetStart
        ))
    }

    func testResizeCrossingMidnightWaitsForConfirmation() {
        let calendar = utcCalendar
        let photographerID = UUID()
        let clip = MetadataScheduleClip(
            photographerID: photographerID,
            name: "Late",
            startsAt: date(2026, 8, 29, 22, 0, calendar: calendar),
            endsAt: date(2026, 8, 29, 23, 30, calendar: calendar)
        )
        let coordinator = MetadataProgrammingCoordinator(calendar: calendar)
        coordinator.draft.clips = [clip]
        coordinator.snapMinutes = 15

        coordinator.resizeClip(clip, edge: .end, by: 60 * 60)

        XCTAssertEqual(coordinator.draft.clips, [clip])
        let pending = coordinator.pendingClipChange?.clip
        XCTAssertEqual(pending?.endsAt, date(2026, 8, 30, 0, 30, calendar: calendar))

        if let pending {
            coordinator.applyClipChange(pending)
        }
        XCTAssertEqual(coordinator.draft.clips.first?.endsAt, pending?.endsAt)
        XCTAssertEqual(coordinator.selectedClipIDs, [clip.id])
    }

    func testPreviewPublishesInjectedResultAndClearsLoadingState() async {
        let expected = MetadataPreviewResult(items: [])
        let coordinator = MetadataProgrammingCoordinator { _, _, _ in
            MetadataProgrammingPreview(folderName: "Synced Files", result: expected)
        }
        let job = previewJob()
        coordinator.loadedJobID = job.id

        coordinator.previewConfiguredLocalFolder(for: job)
        await waitForPreview(coordinator)

        XCTAssertFalse(coordinator.isPreviewingMetadata)
        XCTAssertEqual(coordinator.metadataPreviewFolderName, "Synced Files")
        XCTAssertEqual(coordinator.metadataPreview, expected)
        XCTAssertNil(coordinator.metadataPreviewError)
    }

    func testPreviewFailurePublishesErrorAndClearsLoadingState() async {
        let coordinator = MetadataProgrammingCoordinator { _, _, _ in
            throw PreviewFailure.expected
        }
        let job = previewJob()
        coordinator.loadedJobID = job.id

        coordinator.previewConfiguredLocalFolder(for: job)
        await waitForPreview(coordinator)

        XCTAssertFalse(coordinator.isPreviewingMetadata)
        XCTAssertNil(coordinator.metadataPreview)
        XCTAssertNotNil(coordinator.metadataPreviewError)
    }

    func testReplacementPreviewIgnoresCancelledRequest() async {
        let previews = PreviewSequence()
        let coordinator = MetadataProgrammingCoordinator { _, _, _ in
            try await previews.next()
        }
        let job = previewJob()
        coordinator.loadedJobID = job.id

        coordinator.previewConfiguredLocalFolder(for: job)
        await previews.waitUntilStarted()
        coordinator.previewConfiguredLocalFolder(for: job)
        await waitForPreview(coordinator)

        XCTAssertFalse(coordinator.isPreviewingMetadata)
        XCTAssertEqual(coordinator.metadataPreviewFolderName, "Current")
        XCTAssertNil(coordinator.metadataPreviewError)
    }

    func testReprocessPresentationDescribesSelectedClip() {
        let photographerID = UUID()
        let clip = MetadataScheduleClip(
            photographerID: photographerID,
            name: "Morning desk",
            startsAt: Date(),
            endsAt: Date().addingTimeInterval(3_600)
        )
        let coordinator = MetadataProgrammingCoordinator()
        coordinator.draft.clips = [clip]
        coordinator.pendingReprocessScope = .clip(clip.id)

        XCTAssertEqual(coordinator.reprocessActionTitle, "Reprocess Clip’s Files")
        XCTAssertTrue(coordinator.reprocessConfirmationMessage(for: nil).contains("“Morning desk” clip"))
    }

    private func waitForPreview(_ coordinator: MetadataProgrammingCoordinator) async {
        for _ in 0..<100 where coordinator.isPreviewingMetadata {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func previewJob() -> SyncJob {
        var job = SyncJob()
        job.right = Endpoint(
            kind: .local,
            localPath: "/tmp/preview",
            bookmark: Data([1])
        )
        job.direction = .leftToRight
        return job
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

private enum PreviewFailure: Error {
    case expected
}

private actor PreviewSequence {
    private var invocation = 0

    func waitUntilStarted() async {
        while invocation == 0 {
            await Task.yield()
        }
    }

    func next() async throws -> MetadataProgrammingPreview {
        invocation += 1
        if invocation == 1 {
            try await Task.sleep(for: .seconds(10))
            return MetadataProgrammingPreview(
                folderName: "Stale",
                result: MetadataPreviewResult(items: [])
            )
        }
        return MetadataProgrammingPreview(
            folderName: "Current",
            result: MetadataPreviewResult(items: [])
        )
    }
}
