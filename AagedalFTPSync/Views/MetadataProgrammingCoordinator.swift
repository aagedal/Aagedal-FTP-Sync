import Combine
import Foundation

struct MetadataProgrammingPreview: Equatable, Sendable {
    let folderName: String
    let result: MetadataPreviewResult
}

typealias MetadataPreviewOperation = @Sendable (
    _ job: SyncJob,
    _ endpoint: Endpoint,
    _ automation: MetadataAutomation
) async throws -> MetadataProgrammingPreview

struct PendingClipChange: Identifiable {
    let id = UUID()
    let clip: MetadataScheduleClip
}

struct TimelinePlayhead: Equatable {
    let photographerID: UUID
    let date: Date
}

@MainActor
final class MetadataProgrammingCoordinator: ObservableObject {
    @Published var selectedDate: Date
    @Published var draft = MetadataAutomation()
    @Published var loadedJobID: UUID?
    @Published var selectedPhotographerID: UUID?
    @Published var editingPhotographerID: UUID?
    @Published var draggedPhotographerID: UUID?
    @Published var editingClipID: UUID?
    @Published var photographerPendingDeletion: PhotographerProfile?
    @Published var saveConfirmation = false
    @Published var lastSavedDraft: MetadataAutomation?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var copiedClips: [MetadataScheduleClip] = []
    @Published var playhead: TimelinePlayhead?
    @Published var snapMinutes = 15
    @Published var pendingClipChange: PendingClipChange?
    @Published var pendingReprocessScope: MetadataReprocessScope?
    @Published var metadataPreview: MetadataPreviewResult?
    @Published var metadataPreviewFolderName = ""
    @Published var metadataPreviewError: String?
    @Published var isPreviewingMetadata = false

    let calendar: Calendar

    private let previewOperation: MetadataPreviewOperation
    private var autosaveTask: Task<Void, Never>?
    private var previewRequestID: UUID?
    private var previewTask: Task<Void, Never>?

    init(
        selectedDate: Date = Date(),
        calendar: Calendar = .current,
        previewOperation: @escaping MetadataPreviewOperation = performMetadataPreview
    ) {
        self.selectedDate = selectedDate
        self.calendar = calendar
        self.previewOperation = previewOperation
    }

    func selectedJob(in store: AppStore) -> SyncJob? {
        guard let selectedJobID = store.selectedJobID else { return nil }
        return store.jobs.first(where: { $0.id == selectedJobID })
    }

    func canEnableMetadata(for job: SyncJob?) -> Bool {
        guard let job, job.direction != .bidirectional else { return false }
        let target = job.direction == .leftToRight ? job.right : job.left
        return target.kind == .local
    }

    func metadataLocalEndpoint(for job: SyncJob?) -> Endpoint? {
        guard let job, job.direction != .bidirectional else { return nil }
        let target = job.direction == .leftToRight ? job.right : job.left
        return target.kind == .local ? target : nil
    }

    func canAutosaveDraft(in store: AppStore) -> Bool {
        guard let loadedJobID else { return false }
        return canPersistDraft(draft, for: loadedJobID, in: store)
    }

    func canPersistDraft(
        _ automation: MetadataAutomation,
        for jobID: UUID,
        in store: AppStore
    ) -> Bool {
        guard automation.validationMessage == nil,
              let job = store.jobs.first(where: { $0.id == jobID }) else {
            return false
        }
        guard automation.isEnabled else { return true }
        return canEnableMetadata(for: job)
    }

    func canReprocessMetadata(in store: AppStore) -> Bool {
        guard let loadedJobID else { return false }
        return draft.isEnabled
            && draft.validationMessage == nil
            && canEnableMetadata(for: selectedJob(in: store))
            && draft.timestampPolicy != .localArrival
            && !store.isJobBusy(loadedJobID)
    }

    var previewValidationMessage: String? {
        var enabledDraft = draft
        enabledDraft.isEnabled = true
        return enabledDraft.validationMessage
    }

    func canPreviewMetadata(for job: SyncJob?) -> Bool {
        loadedJobID != nil
            && metadataLocalEndpoint(for: job)?.bookmark != nil
            && previewValidationMessage == nil
            && !isPreviewingMetadata
    }

    func previewHelp(for job: SyncJob?) -> String {
        if let previewValidationMessage {
            return previewValidationMessage
        }
        guard let metadataLocalEndpoint = metadataLocalEndpoint(for: job) else {
            return "Automatic metadata requires a one-way job with a local destination."
        }
        return "Preview the unsaved programming draft against \(job?.localDestinationDisplayPath ?? metadataLocalEndpoint.localPath). No files are changed."
    }

    func isReprocessing(in store: AppStore) -> Bool {
        guard let loadedJobID else { return false }
        return store.metadataReprocessPhases[loadedJobID] == .running
    }

    func reprocessStatusText(in store: AppStore) -> String? {
        guard let loadedJobID,
              let phase = store.metadataReprocessPhases[loadedJobID] else { return nil }
        switch phase {
        case .idle:
            return nil
        case .running:
            return "Scanning the local destination…"
        case .succeeded(_, let result):
            return "Reprocessed \(result.applied) of \(result.scanned) files; \(result.skipped) skipped, \(result.failed) failed."
        case .failed(let message):
            return "Reprocessing failed: \(message)"
        }
    }

    var reprocessHelp: String {
        if draft.timestampPolicy == .localArrival {
            return "Arrival timestamps were not recorded for existing files. Choose source modification or camera capture time."
        }
        if !draft.isEnabled {
            return "Enable automatic metadata before reprocessing existing files."
        }
        return "Apply the saved schedule to matching files already in the local destination."
    }

    func reprocessConfirmationMessage(for job: SyncJob?) -> String {
        let target = job?.localDestinationDisplayPath ?? "the local destination"
        let policyNote = draft.existingFieldPolicy == .fillEmpty
            ? "Existing non-empty fields will be preserved."
            : "Non-empty programmed values will overwrite existing fields."
        let scopeDescription: String
        switch pendingReprocessScope {
        case .photographer(let photographerID):
            let name = draft.photographers.first(where: { $0.id == photographerID })?.photographerName
                ?? "the selected photographer"
            scopeDescription = "Only files assigned to \(name)"
        case .clip(let clipID):
            let name = draft.clips.first(where: { $0.id == clipID })?.name
                ?? "the selected metadata clip"
            scopeDescription = "Only files assigned to the “\(name)” clip"
        case .all, nil:
            scopeDescription = "Matching files"
        }
        return "\(scopeDescription) in \(target) will be rewritten safely in place; the source is untouched and modification dates are retained. \(policyNote)"
    }

    var reprocessActionTitle: String {
        switch pendingReprocessScope {
        case .photographer:
            "Reprocess Photographer’s Files"
        case .clip:
            "Reprocess Clip’s Files"
        case .all, nil:
            "Reprocess Files"
        }
    }

    @discardableResult
    func confirmReprocessing(in store: AppStore) -> Bool {
        guard let scope = pendingReprocessScope,
              save(in: store),
              let loadedJobID else { return false }
        store.reprocessExistingLocalFiles(loadedJobID, scope: scope)
        return true
    }

    func previewConfiguredLocalFolder(for job: SyncJob?) {
        guard let job,
              let metadataLocalEndpoint = metadataLocalEndpoint(for: job) else { return }
        let previewDraft = draft
        let previewOperation = self.previewOperation
        previewTask?.cancel()
        let requestID = UUID()
        previewRequestID = requestID
        isPreviewingMetadata = true
        metadataPreviewError = nil
        previewTask = Task { [weak self] in
            do {
                let preview = try await previewOperation(job, metadataLocalEndpoint, previewDraft)
                guard let self,
                      previewRequestID == requestID,
                      loadedJobID == job.id else { return }
                metadataPreviewFolderName = preview.folderName
                metadataPreview = preview.result
                isPreviewingMetadata = false
                previewRequestID = nil
                previewTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      previewRequestID == requestID,
                      loadedJobID == job.id else { return }
                metadataPreviewError = error.localizedDescription
                isPreviewingMetadata = false
                previewRequestID = nil
                previewTask = nil
            }
        }
    }

    var selectedPhotographer: PhotographerProfile? {
        guard let selectedPhotographerID else { return nil }
        return draft.photographers.first(where: { $0.id == selectedPhotographerID })
    }

    var playheadSummary: String? {
        guard let playhead,
              let photographer = draft.photographers.first(where: { $0.id == playhead.photographerID }) else {
            return nil
        }
        return "\(photographer.photographerName) · \(playhead.date.formatted(date: .omitted, time: .shortened))"
    }

    var pasteHelp: String {
        if let playheadSummary {
            return "Paste at \(playheadSummary) (Command-V)"
        }
        return "Click a track to place the playhead, then paste (Command-V)"
    }

    var timelinePhotographers: [PhotographerProfile] {
        draft.photographers
    }

    var programmedDays: Set<Date> {
        draft.clips.reduce(into: Set<Date>()) { days, clip in
            var day = calendar.startOfDay(for: clip.startsAt)
            while clip.endsAt > day {
                if clip.overlaps(dayContaining: day, calendar: calendar) {
                    days.insert(day)
                }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                      nextDay > day else {
                    break
                }
                day = nextDay
            }
        }
    }

    func knownPhotographers(in store: AppStore) -> [PhotographerProfile] {
        let assignedIDs = Set(draft.photographers.map(\.id))
        return store.photographerLibrary.filter { !assignedIDs.contains($0.id) }
    }

    func clips(for photographer: PhotographerProfile) -> [MetadataScheduleClip] {
        draft.clips
            .filter {
                $0.photographerID == photographer.id
                    && $0.overlaps(dayContaining: selectedDate, calendar: calendar)
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    func processedFileCount(for photographer: PhotographerProfile, in store: AppStore) -> Int {
        guard let loadedJobID else { return 0 }
        let processedPaths = store.metadataAuditTrail(for: loadedJobID).lazy
            .filter { $0.status == .applied && $0.photographerID == photographer.id }
            .map(\.relativePath)
        return Set(processedPaths).count
    }

    func loadSelectedJob(from store: AppStore) {
        autosaveTask?.cancel()
        autosaveTask = nil
        previewTask?.cancel()
        previewTask = nil
        previewRequestID = nil
        isPreviewingMetadata = false
        saveConfirmation = false
        guard let job = selectedJob(in: store) else {
            loadedJobID = nil
            draft = MetadataAutomation()
            lastSavedDraft = nil
            selectedPhotographerID = nil
            editingPhotographerID = nil
            selectedClipIDs = []
            copiedClips = []
            playhead = nil
            return
        }
        loadedJobID = job.id
        draft = job.metadataAutomation ?? MetadataAutomation()
        lastSavedDraft = draft
        selectedPhotographerID = draft.photographers.first?.id
        editingPhotographerID = nil
        selectedClipIDs = []
        copiedClips = []
        playhead = nil
    }

    func scheduleAutosave(in store: AppStore) {
        autosaveTask?.cancel()
        saveConfirmation = false
        guard draft != lastSavedDraft, canAutosaveDraft(in: store) else { return }

        autosaveTask = Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let store else { return }
            _ = save(in: store)
            autosaveTask = nil
        }
    }

    func flushAutosave(in store: AppStore) {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard draft != lastSavedDraft else { return }
        _ = save(in: store)
    }

    func refreshDraftPhotographers(from store: AppStore) {
        let libraryByID = Dictionary(uniqueKeysWithValues: store.photographerLibrary.map { ($0.id, $0) })
        for index in draft.photographers.indices {
            if let updatedProfile = libraryByID[draft.photographers[index].id] {
                draft.photographers[index] = updatedProfile
            }
        }
    }

    func addPhotographer() {
        let photographer = PhotographerProfile(
            name: "Photographer",
            filenamePrefix: uniquePrefix(),
            creator: "Photographer",
            copyrightNotice: ""
        )
        draft.photographers.append(photographer)
        selectedPhotographerID = photographer.id
    }

    func addKnownPhotographer(_ photographer: PhotographerProfile) {
        guard !draft.photographers.contains(where: { $0.id == photographer.id }) else {
            selectedPhotographerID = photographer.id
            return
        }
        draft.photographers.append(photographer)
        selectedPhotographerID = photographer.id
    }

    func removePhotographer(_ photographer: PhotographerProfile) {
        draft.photographers.removeAll { $0.id == photographer.id }
        draft.clips.removeAll { $0.photographerID == photographer.id }
        selectedClipIDs = selectedClipIDs.filter { id in draft.clips.contains(where: { $0.id == id }) }
        selectedPhotographerID = draft.photographers.first?.id
        if playhead?.photographerID == photographer.id { playhead = nil }
        photographerPendingDeletion = nil
    }

    func addClip() {
        guard let photographer = selectedPhotographer else { return }
        let dayStart = calendar.startOfDay(for: selectedDate)
        let defaultStartHour = calendar.isDateInToday(selectedDate)
            ? min(max(calendar.component(.hour, from: Date()), 0), 22)
            : 9
        let defaultStart = calendar.date(byAdding: .hour, value: defaultStartHour, to: dayStart) ?? dayStart
        let start = playhead?.photographerID == photographer.id ? playhead?.date ?? defaultStart : defaultStart
        let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Metadata clip",
            startsAt: start,
            endsAt: end,
            fields: ScheduledMetadataFields(headline: "Metadata clip")
        )
        draft.clips.append(clip)
        selectedClipIDs = [clip.id]
        editingClipID = clip.id
    }

    func updateClip(_ clip: MetadataScheduleClip) {
        guard let index = draft.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        draft.clips[index] = clip
        editingClipID = nil
    }

    func selectClip(_ clip: MetadataScheduleClip, extendingSelection: Bool) {
        if extendingSelection {
            if selectedClipIDs.contains(clip.id) {
                selectedClipIDs.remove(clip.id)
            } else {
                selectedClipIDs.insert(clip.id)
            }
        } else {
            selectedClipIDs = [clip.id]
        }
        selectedPhotographerID = clip.photographerID
    }

    func editSelectedClip() {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return }
        editingClipID = id
    }

    func editClip(_ clip: MetadataScheduleClip) {
        selectedClipIDs = [clip.id]
        selectedPhotographerID = clip.photographerID
        editingClipID = clip.id
    }

    func createClip(for photographer: PhotographerProfile, from start: Date, to end: Date) {
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Metadata clip",
            startsAt: start,
            endsAt: end,
            fields: ScheduledMetadataFields(headline: "Metadata clip")
        )
        draft.clips.append(clip)
        selectedClipIDs = [clip.id]
        selectedPhotographerID = photographer.id
        playhead = TimelinePlayhead(photographerID: photographer.id, date: start)
    }

    func copySelectedClips() {
        copiedClips = draft.clips
            .filter { selectedClipIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
                return lhs.photographerID.uuidString < rhs.photographerID.uuidString
            }
    }

    func pasteClips() {
        guard let playhead else { return }
        pasteClips(to: playhead.date, on: playhead.photographerID)
    }

    func pasteClips(to date: Date, on photographerID: UUID) {
        guard !copiedClips.isEmpty else { return }
        let pasted = MetadataTimelineEditing.copies(
            of: copiedClips,
            anchoredAt: date,
            on: photographerID
        )
        finishPasting(pasted, playhead: TimelinePlayhead(photographerID: photographerID, date: date))
    }

    func deleteSelectedClips() {
        guard !selectedClipIDs.isEmpty else { return }
        draft.clips.removeAll { selectedClipIDs.contains($0.id) }
        selectedClipIDs = []
    }

    func selectAllClipsForDay() {
        selectedClipIDs = Set(draft.clips.filter {
            $0.overlaps(dayContaining: selectedDate, calendar: calendar)
        }.map(\.id))
    }

    func moveClip(_ clip: MetadataScheduleClip, by interval: TimeInterval, duplicating: Bool) {
        var changed = MetadataTimelineEditing.moving(
            clip,
            by: interval,
            snapMinutes: snapMinutes,
            calendar: calendar
        )
        if duplicating {
            changed.id = UUID()
            draft.clips.append(changed)
            selectedClipIDs = [changed.id]
            selectedPhotographerID = changed.photographerID
        } else {
            applyClipChange(changed)
        }
    }

    func placePlayhead(on photographerID: UUID, at date: Date) {
        playhead = TimelinePlayhead(photographerID: photographerID, date: date)
        selectedPhotographerID = photographerID
        selectedClipIDs = []
    }

    func resizeClip(_ clip: MetadataScheduleClip, edge: MetadataClipResizeEdge, by interval: TimeInterval) {
        let changed = MetadataTimelineEditing.resizing(
            clip,
            edge: edge,
            by: interval,
            snapMinutes: snapMinutes,
            calendar: calendar
        )
        let originallyCrossedMidnight = !calendar.isDate(clip.startsAt, inSameDayAs: clip.endsAt)
        let nowCrossesMidnight = !calendar.isDate(changed.startsAt, inSameDayAs: changed.endsAt)
        if nowCrossesMidnight && !originallyCrossedMidnight {
            pendingClipChange = PendingClipChange(clip: changed)
        } else {
            applyClipChange(changed)
        }
    }

    func applyClipChange(_ clip: MetadataScheduleClip) {
        guard let index = draft.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        draft.clips[index] = clip
        selectedClipIDs = [clip.id]
        selectedPhotographerID = clip.photographerID
    }

    func selectAdjacentClip(horizontalOffset: Int) {
        let visible = draft.clips
            .filter { $0.overlaps(dayContaining: selectedDate, calendar: calendar) }
            .sorted { $0.startsAt < $1.startsAt }
        guard !visible.isEmpty else { return }
        guard selectedClipIDs.count == 1,
              let selectedID = selectedClipIDs.first,
              let selected = visible.first(where: { $0.id == selectedID }) else {
            selectClip(visible[horizontalOffset < 0 ? visible.count - 1 : 0], extendingSelection: false)
            return
        }
        let sameTrack = visible.filter { $0.photographerID == selected.photographerID }
        guard let index = sameTrack.firstIndex(where: { $0.id == selected.id }) else { return }
        let target = min(max(index + horizontalOffset, 0), sameTrack.count - 1)
        selectClip(sameTrack[target], extendingSelection: false)
    }

    func selectAdjacentTrack(offset: Int) {
        guard !timelinePhotographers.isEmpty else { return }
        let selected = selectedClipIDs.count == 1
            ? draft.clips.first(where: { $0.id == selectedClipIDs.first })
            : nil
        let currentPhotographerID = selected?.photographerID ?? selectedPhotographerID
        let currentIndex = timelinePhotographers.firstIndex(where: { $0.id == currentPhotographerID }) ?? 0
        let targetIndex = min(max(currentIndex + offset, 0), timelinePhotographers.count - 1)
        let targetPhotographer = timelinePhotographers[targetIndex]
        let trackClips = clips(for: targetPhotographer)
        selectedPhotographerID = targetPhotographer.id
        guard !trackClips.isEmpty else {
            selectedClipIDs = []
            return
        }
        let referenceDate = selected?.startsAt ?? calendar.startOfDay(for: selectedDate)
        let nearest = trackClips.min {
            abs($0.startsAt.timeIntervalSince(referenceDate)) < abs($1.startsAt.timeIntervalSince(referenceDate))
        }
        if let nearest { selectedClipIDs = [nearest.id] }
    }

    func moveDay(by value: Int) {
        selectedDate = calendar.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
        playhead = nil
        selectedClipIDs = selectedClipIDs.filter { id in
            draft.clips.first(where: { $0.id == id })?.overlaps(dayContaining: selectedDate, calendar: calendar) == true
        }
    }

    func clearPlayheadIfOutsideSelectedDay() {
        if let playhead, !calendar.isDate(playhead.date, inSameDayAs: selectedDate) {
            self.playhead = nil
        }
    }

    @discardableResult
    func save(in store: AppStore) -> Bool {
        guard canAutosaveDraft(in: store),
              let loadedJobID,
              store.saveMetadataAutomation(draft, for: loadedJobID) else {
            saveConfirmation = false
            return false
        }
        lastSavedDraft = draft
        saveConfirmation = true
        return true
    }

    private func uniquePrefix() -> String {
        let used = Set(draft.photographers.flatMap(\.normalizedPrefixes))
        for prefix in ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG"] where !used.contains(prefix) {
            return prefix
        }
        var number = draft.photographers.count + 1
        while used.contains("P\(number)") { number += 1 }
        return "P\(number)"
    }

    private func finishPasting(
        _ pasted: [MetadataScheduleClip],
        playhead newPlayhead: TimelinePlayhead? = nil
    ) {
        guard !pasted.isEmpty else { return }
        draft.clips.append(contentsOf: pasted)
        selectedClipIDs = Set(pasted.map(\.id))
        if let newPlayhead {
            playhead = newPlayhead
            selectedPhotographerID = newPlayhead.photographerID
        }
    }
}

private func performMetadataPreview(
    job: SyncJob,
    endpoint: Endpoint,
    automation: MetadataAutomation
) async throws -> MetadataProgrammingPreview {
    let folderAccess = try BookmarkAccess(endpoint: endpoint)
    let folderURL = try MetadataPreviewService.localFolderURL(
        selectedRoot: folderAccess.url,
        usesManagedFolderStructure: job.usesManagedFolderStructure
    )
    let filter = job.filter
    let result = try await Task.detached(priority: .userInitiated) {
        _ = folderAccess
        return try MetadataPreviewService.previewLocalFolder(
            at: folderURL,
            automation: automation,
            filter: filter
        )
    }.value
    return MetadataProgrammingPreview(folderName: folderURL.lastPathComponent, result: result)
}
