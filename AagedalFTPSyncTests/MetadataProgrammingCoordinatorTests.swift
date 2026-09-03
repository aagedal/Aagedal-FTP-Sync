import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataProgrammingCoordinatorTests: XCTestCase {
    func testOpenClipSelectsItsDayTrackAndEditor() {
        let calendar = utcCalendar
        let photographerID = UUID()
        let instant = date(2026, 9, 3, 14, 15, calendar: calendar)
        let clip = MetadataScheduleClip(
            photographerID: photographerID,
            name: "Assignment",
            startsAt: instant.addingTimeInterval(-1_800),
            endsAt: instant.addingTimeInterval(1_800)
        )
        let coordinator = MetadataProgrammingCoordinator(calendar: calendar)
        coordinator.draft.clips = [clip]

        XCTAssertTrue(coordinator.openClip(clip.id, at: instant))

        XCTAssertEqual(coordinator.selectedDate, calendar.startOfDay(for: instant))
        XCTAssertEqual(coordinator.selectedPhotographerID, photographerID)
        XCTAssertEqual(coordinator.selectedPhotographerIDs, [photographerID])
        XCTAssertEqual(coordinator.selectedClipIDs, [clip.id])
        XCTAssertEqual(coordinator.editingClipID, clip.id)
        XCTAssertEqual(coordinator.playhead, TimelinePlayhead(photographerID: photographerID, date: instant))
    }

    func testExternalGPSPositionMergesWithoutMakingCleanDraftDirty() throws {
        let jobID = UUID()
        let clip = MetadataScheduleClip(
            photographerID: UUID(),
            name: "Assignment",
            startsAt: Date(),
            endsAt: Date().addingTimeInterval(3_600),
            gpsPosition: ScheduledGPSPosition(latitude: 59.91, longitude: 10.75)
        )
        let coordinator = MetadataProgrammingCoordinator()
        coordinator.loadedJobID = jobID
        coordinator.draft.clips = [clip]
        coordinator.lastSavedDraft = coordinator.draft
        let moved = ScheduledGPSPosition(latitude: 60.39, longitude: 5.32)

        coordinator.applyExternalGPSPosition(moved, to: clip.id, jobID: jobID)

        XCTAssertEqual(coordinator.draft.clips.first?.gpsPosition, moved)
        XCTAssertEqual(coordinator.lastSavedDraft, coordinator.draft)

        coordinator.draft.clips[0].name = "Unsaved name"
        coordinator.applyExternalGPSPosition(
            ScheduledGPSPosition(latitude: 63.43, longitude: 10.39),
            to: clip.id,
            jobID: jobID
        )

        XCTAssertEqual(coordinator.draft.clips.first?.name, "Unsaved name")
        XCTAssertNotEqual(coordinator.lastSavedDraft, coordinator.draft)
    }

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

    func testPasteCopiesSingleTrackProgrammingToEverySelectedTrack() {
        let calendar = utcCalendar
        let sourcePhotographer = PhotographerProfile(
            name: "Source", filenamePrefix: "SRC", creator: "Source", copyrightNotice: ""
        )
        let firstTarget = PhotographerProfile(
            name: "First", filenamePrefix: "ONE", creator: "First", copyrightNotice: ""
        )
        let secondTarget = PhotographerProfile(
            name: "Second", filenamePrefix: "TWO", creator: "Second", copyrightNotice: ""
        )
        let sourceStart = date(2026, 8, 29, 9, 0, calendar: calendar)
        let targetStart = date(2026, 8, 29, 14, 15, calendar: calendar)
        let sourceClips = [
            MetadataScheduleClip(
                photographerID: sourcePhotographer.id,
                name: "First clip",
                startsAt: sourceStart,
                endsAt: sourceStart.addingTimeInterval(1_800)
            ),
            MetadataScheduleClip(
                photographerID: sourcePhotographer.id,
                name: "Second clip",
                startsAt: sourceStart.addingTimeInterval(3_600),
                endsAt: sourceStart.addingTimeInterval(5_400)
            ),
        ]
        let coordinator = MetadataProgrammingCoordinator(selectedDate: sourceStart, calendar: calendar)
        coordinator.draft = MetadataAutomation(
            photographers: [sourcePhotographer, firstTarget, secondTarget],
            clips: sourceClips
        )
        coordinator.selectedClipIDs = Set(sourceClips.map(\.id))
        coordinator.copySelectedClips()
        coordinator.selectPhotographer(firstTarget.id, extendingSelection: false)
        coordinator.selectPhotographer(secondTarget.id, extendingSelection: true)
        coordinator.placePlayhead(on: firstTarget.id, at: targetStart)

        coordinator.pasteClips()

        let pasted = coordinator.draft.clips.filter { coordinator.selectedClipIDs.contains($0.id) }
        XCTAssertEqual(pasted.count, 4)
        XCTAssertEqual(Set(pasted.map(\.photographerID)), [firstTarget.id, secondTarget.id])
        for targetID in [firstTarget.id, secondTarget.id] {
            let targetClips = pasted.filter { $0.photographerID == targetID }.sorted { $0.startsAt < $1.startsAt }
            XCTAssertEqual(targetClips.map(\.startsAt), [targetStart, targetStart.addingTimeInterval(3_600)])
        }
        XCTAssertEqual(coordinator.selectedPhotographerIDs, [firstTarget.id, secondTarget.id])
        XCTAssertEqual(coordinator.playhead, TimelinePlayhead(photographerID: firstTarget.id, date: targetStart))
    }

    func testVerticalTrackNavigationMovesPlayheadWithoutChangingItsTime() {
        let calendar = utcCalendar
        let first = PhotographerProfile(
            name: "First", filenamePrefix: "ONE", creator: "First", copyrightNotice: ""
        )
        let second = PhotographerProfile(
            name: "Second", filenamePrefix: "TWO", creator: "Second", copyrightNotice: ""
        )
        let targetDate = date(2026, 8, 29, 14, 15, calendar: calendar)
        let coordinator = MetadataProgrammingCoordinator(selectedDate: targetDate, calendar: calendar)
        coordinator.draft.photographers = [first, second]
        coordinator.placePlayhead(on: first.id, at: targetDate)

        coordinator.selectAdjacentTrack(offset: 1)

        XCTAssertEqual(coordinator.selectedPhotographerID, second.id)
        XCTAssertEqual(coordinator.selectedPhotographerIDs, [second.id])
        XCTAssertEqual(coordinator.playhead, TimelinePlayhead(photographerID: second.id, date: targetDate))
    }

    func testHorizontalNavigationMovesPlayheadBySnapIntervalAndClampsToDay() {
        let calendar = utcCalendar
        let photographer = PhotographerProfile(
            name: "First", filenamePrefix: "ONE", creator: "First", copyrightNotice: ""
        )
        let day = date(2026, 8, 29, 0, 0, calendar: calendar)
        let coordinator = MetadataProgrammingCoordinator(selectedDate: day, calendar: calendar)
        coordinator.draft.photographers = [photographer]
        coordinator.snapMinutes = 15
        coordinator.placePlayhead(on: photographer.id, at: date(2026, 8, 29, 10, 0, calendar: calendar))

        coordinator.movePlayhead(bySnapIntervals: 1)
        XCTAssertEqual(coordinator.playhead?.date, date(2026, 8, 29, 10, 15, calendar: calendar))

        coordinator.placePlayhead(on: photographer.id, at: day)
        coordinator.movePlayhead(bySnapIntervals: -1)
        XCTAssertEqual(coordinator.playhead?.date, day)

        coordinator.placePlayhead(on: photographer.id, at: date(2026, 8, 29, 23, 45, calendar: calendar))
        coordinator.movePlayhead(bySnapIntervals: 1)
        XCTAssertEqual(coordinator.playhead?.date, date(2026, 8, 29, 23, 45, calendar: calendar))
    }

    func testCopyAndPasteDayProgrammingPreservesTracksAndVisibleTimes() throws {
        let calendar = utcCalendar
        let firstPhotographerID = UUID()
        let secondPhotographerID = UUID()
        let sourceDay = date(2026, 8, 29, 0, 0, calendar: calendar)
        let targetDay = date(2026, 9, 1, 0, 0, calendar: calendar)
        let sourceClips = [
            MetadataScheduleClip(
                photographerID: firstPhotographerID,
                name: "Morning",
                startsAt: date(2026, 8, 29, 9, 0, calendar: calendar),
                endsAt: date(2026, 8, 29, 10, 0, calendar: calendar)
            ),
            MetadataScheduleClip(
                photographerID: secondPhotographerID,
                name: "From previous day",
                startsAt: date(2026, 8, 28, 23, 0, calendar: calendar),
                endsAt: date(2026, 8, 29, 1, 0, calendar: calendar)
            ),
            MetadataScheduleClip(
                photographerID: secondPhotographerID,
                name: "Into next day",
                startsAt: date(2026, 8, 29, 23, 30, calendar: calendar),
                endsAt: date(2026, 8, 30, 1, 0, calendar: calendar)
            ),
            MetadataScheduleClip(
                photographerID: firstPhotographerID,
                name: "Different day",
                startsAt: date(2026, 8, 30, 12, 0, calendar: calendar),
                endsAt: date(2026, 8, 30, 13, 0, calendar: calendar)
            ),
            MetadataScheduleClip(
                photographerID: firstPhotographerID,
                name: "Existing destination programming",
                startsAt: date(2026, 9, 1, 15, 0, calendar: calendar),
                endsAt: date(2026, 9, 1, 16, 0, calendar: calendar)
            ),
        ]
        let coordinator = MetadataProgrammingCoordinator(calendar: calendar)
        coordinator.draft.clips = sourceClips

        coordinator.copyAllProgramming(on: sourceDay)
        coordinator.pasteDayProgramming(to: targetDay)

        XCTAssertEqual(Array(coordinator.draft.clips.prefix(sourceClips.count)), sourceClips)
        let pasted = coordinator.draft.clips.filter { coordinator.selectedClipIDs.contains($0.id) }
            .sorted { $0.startsAt < $1.startsAt }
        XCTAssertEqual(pasted.count, 3)
        XCTAssertEqual(pasted.map(\.photographerID), [secondPhotographerID, firstPhotographerID, secondPhotographerID])
        XCTAssertEqual(pasted[0].startsAt, date(2026, 9, 1, 0, 0, calendar: calendar))
        XCTAssertEqual(pasted[0].endsAt, date(2026, 9, 1, 1, 0, calendar: calendar))
        XCTAssertEqual(pasted[1].startsAt, date(2026, 9, 1, 9, 0, calendar: calendar))
        XCTAssertEqual(pasted[1].endsAt, date(2026, 9, 1, 10, 0, calendar: calendar))
        XCTAssertEqual(pasted[2].startsAt, date(2026, 9, 1, 23, 30, calendar: calendar))
        XCTAssertEqual(pasted[2].endsAt, date(2026, 9, 2, 0, 0, calendar: calendar))
        XCTAssertTrue(Set(pasted.map(\.id)).isDisjoint(with: Set(sourceClips.map(\.id))))
        XCTAssertEqual(coordinator.selectedDate, targetDay)
        XCTAssertTrue(coordinator.programmedDays.contains(targetDay))
        XCTAssertNil(coordinator.playhead)
    }

    func testCopiedDaySurvivesJobSwitchAndAddsItsMissingPhotographerTrack() throws {
        let calendar = utcCalendar
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-day-job-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photographer = PhotographerProfile(
            name: "News desk",
            filenamePrefix: "ND",
            creator: "News desk",
            copyrightNotice: "Newsroom"
        )
        let sourceDay = date(2026, 9, 3, 0, 0, calendar: calendar)
        let targetDay = date(2026, 9, 4, 0, 0, calendar: calendar)
        let sourceClip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Morning assignment",
            startsAt: date(2026, 9, 3, 8, 30, calendar: calendar),
            endsAt: date(2026, 9, 3, 10, 0, calendar: calendar)
        )
        var sourceJob = SyncJob(name: "Source job")
        sourceJob.metadataAutomation = MetadataAutomation(
            photographers: [photographer],
            clips: [sourceClip]
        )
        let targetJob = SyncJob(name: "Target job")
        let repository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        try repository.save([sourceJob, targetJob])
        let store = AppStore(
            repository: repository,
            metadataPresetRepository: MetadataPresetRepository(
                fileURL: root.appendingPathComponent("presets.json")
            ),
            photographerProfileRepository: PhotographerProfileRepository(
                fileURL: root.appendingPathComponent("photographers.json")
            ),
            serverProfileRepository: ServerProfileRepository(
                fileURL: root.appendingPathComponent("servers.json")
            ),
            metadataAuditRepository: MetadataAuditRepository(
                fileURL: root.appendingPathComponent("audit.json")
            ),
            syncFailureRepository: SyncFailureRepository(
                fileURL: root.appendingPathComponent("failures.json")
            ),
            sourceSignatureRepository: SourceSignatureRepository(
                fileURL: root.appendingPathComponent("signatures.json")
            )
        )
        let coordinator = MetadataProgrammingCoordinator(calendar: calendar)

        store.selectedJobID = sourceJob.id
        coordinator.loadSelectedJob(from: store)
        coordinator.copyAllProgramming(on: sourceDay)

        store.selectedJobID = targetJob.id
        coordinator.loadSelectedJob(from: store)

        XCTAssertNotNil(coordinator.copiedDayProgramming)
        coordinator.pasteDayProgramming(to: targetDay)

        XCTAssertEqual(coordinator.draft.photographers, [photographer])
        let pasted = try XCTUnwrap(coordinator.draft.clips.first)
        XCTAssertEqual(pasted.photographerID, photographer.id)
        XCTAssertEqual(pasted.name, sourceClip.name)
        XCTAssertEqual(pasted.startsAt, date(2026, 9, 4, 8, 30, calendar: calendar))
        XCTAssertEqual(pasted.endsAt, date(2026, 9, 4, 10, 0, calendar: calendar))
        XCTAssertNil(coordinator.draft.validationMessage)
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

    func testOptionMoveDuplicatesClipAndKeepsOriginal() throws {
        let calendar = utcCalendar
        let photographerID = UUID()
        let clip = MetadataScheduleClip(
            photographerID: photographerID,
            name: "Original",
            startsAt: date(2026, 8, 29, 9, 0, calendar: calendar),
            endsAt: date(2026, 8, 29, 10, 0, calendar: calendar)
        )
        let coordinator = MetadataProgrammingCoordinator(calendar: calendar)
        coordinator.draft.clips = [clip]
        coordinator.snapMinutes = 15

        coordinator.moveClip(clip, by: 90 * 60, duplicating: true)

        XCTAssertEqual(coordinator.draft.clips.count, 2)
        XCTAssertEqual(coordinator.draft.clips.first, clip)
        let duplicate = try XCTUnwrap(coordinator.draft.clips.last)
        XCTAssertNotEqual(duplicate.id, clip.id)
        XCTAssertEqual(duplicate.startsAt, date(2026, 8, 29, 10, 30, calendar: calendar))
        XCTAssertEqual(duplicate.endsAt, date(2026, 8, 29, 11, 30, calendar: calendar))
        XCTAssertEqual(coordinator.selectedClipIDs, [duplicate.id])
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
