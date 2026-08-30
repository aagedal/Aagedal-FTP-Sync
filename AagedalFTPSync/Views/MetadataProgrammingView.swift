import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MetadataProgrammingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var selectedDate = Date()
    @State private var draft = MetadataAutomation()
    @State private var loadedJobID: UUID?
    @State private var selectedPhotographerID: UUID?
    @State private var editingPhotographerID: UUID?
    @State private var draggedPhotographerID: UUID?
    @State private var editingClipID: UUID?
    @State private var photographerPendingDeletion: PhotographerProfile?
    @State private var saveConfirmation = false
    @State private var lastSavedDraft: MetadataAutomation?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var selectedClipIDs: Set<UUID> = []
    @State private var copiedClips: [MetadataScheduleClip] = []
    @State private var playhead: TimelinePlayhead?
    @State private var snapMinutes = 15
    @State private var pendingClipChange: PendingClipChange?
    @State private var showReprocessConfirmation = false
    @State private var metadataPreview: MetadataPreviewResult?
    @State private var metadataPreviewFolderName = ""
    @State private var metadataPreviewError: String?
    @State private var isPreviewingMetadata = false
    @FocusState private var timelineFocused: Bool

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            windowHeader
            Divider()

            if selectedJob == nil {
                ContentUnavailableView(
                    "No sync job selected",
                    systemImage: "tag.slash",
                    description: Text("Create or select a sync job before programming metadata.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    librarySidebar
                        .frame(minWidth: 245, idealWidth: 275, maxWidth: 320)
                    dayTimeline
                        .frame(minWidth: 650)
                }
                .frame(maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(
            minWidth: 1180,
            maxWidth: .infinity,
            minHeight: 650,
            maxHeight: .infinity,
            alignment: .top
        )
        .onAppear(perform: loadSelectedJob)
        .onDisappear {
            flushAutosave()
        }
        .onChange(of: store.selectedJobID) { _, _ in
            flushAutosave()
            loadSelectedJob()
        }
        .onChange(of: draft) { _, _ in
            scheduleAutosave()
        }
        .onChange(of: store.photographerLibrary) { _, _ in
            refreshDraftPhotographersFromLibrary()
        }
        .onChange(of: selectedDate) { _, newDate in
            if let playhead, !calendar.isDate(playhead.date, inSameDayAs: newDate) {
                self.playhead = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { editingClipID != nil },
            set: { if !$0 { editingClipID = nil } }
        )) {
            if let clipID = editingClipID,
               let clip = draft.clips.first(where: { $0.id == clipID }) {
                MetadataClipEditor(
                    clip: clip,
                    photographers: draft.photographers,
                    onSave: updateClip
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { editingPhotographerID != nil },
            set: { if !$0 { editingPhotographerID = nil } }
        )) {
            if let photographerID = editingPhotographerID,
               let binding = photographerBinding(for: photographerID) {
                TimelinePhotographerEditor(
                    photographer: binding,
                    day: selectedDate,
                    onDone: { editingPhotographerID = nil }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { metadataPreview != nil },
            set: { if !$0 { metadataPreview = nil } }
        )) {
            if let metadataPreview {
                MetadataFolderPreviewView(
                    folderName: metadataPreviewFolderName,
                    timestampPolicy: draft.timestampPolicy,
                    result: metadataPreview
                )
            }
        }
        .confirmationDialog(
            "Remove photographer?",
            isPresented: Binding(
                get: { photographerPendingDeletion != nil },
                set: { if !$0 { photographerPendingDeletion = nil } }
            ),
            presenting: photographerPendingDeletion
        ) { photographer in
            Button("Remove \(photographer.photographerName)", role: .destructive) {
                removePhotographer(photographer)
            }
        } message: { photographer in
            Text("This also removes every metadata clip on \(photographer.photographerName)’s track.")
        }
        .alert(
            "Extend into another day?",
            isPresented: Binding(
                get: { pendingClipChange != nil },
                set: { if !$0 { pendingClipChange = nil } }
            ),
            presenting: pendingClipChange
        ) { change in
            Button("Cancel", role: .cancel) { pendingClipChange = nil }
            Button("Apply Change") {
                applyClipChange(change.clip)
                pendingClipChange = nil
            }
        } message: { change in
            Text("Resizing \(change.clip.name) crosses midnight, so it will appear on more than one day’s timeline.")
        }
        .confirmationDialog(
            "Reprocess existing local files?",
            isPresented: $showReprocessConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reprocess Files") {
                guard save(), let loadedJobID else { return }
                store.reprocessExistingLocalFiles(loadedJobID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reprocessConfirmationMessage)
        }
        .alert(
            "Preview Failed",
            isPresented: Binding(
                get: { metadataPreviewError != nil },
                set: { if !$0 { metadataPreviewError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { metadataPreviewError = nil }
        } message: {
            Text(metadataPreviewError ?? "The folder could not be previewed.")
        }
    }

    private var windowHeader: some View {
        HStack(spacing: 14) {
            Label("Metadata Programming", systemImage: "tag.fill")
                .font(.title2.weight(.semibold))
                .fixedSize()

            Picker("Sync job", selection: selectedJobBinding) {
                ForEach(store.jobs) { job in
                    Text(job.name).tag(Optional(job.id))
                }
            }
            .frame(minWidth: 240, idealWidth: 270, maxWidth: 270)

            Picker("Schedule time", selection: $draft.timestampPolicy) {
                ForEach(MetadataTimestampPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .frame(minWidth: 245, idealWidth: 320, maxWidth: 320)
            .layoutPriority(1)
            .help(draft.timestampPolicy.explanation)

            Picker("Existing fields", selection: $draft.existingFieldPolicy) {
                ForEach(MetadataExistingFieldPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .frame(minWidth: 190, idealWidth: 235, maxWidth: 235)
            .layoutPriority(1)
            .help(draft.existingFieldPolicy.explanation)

            Spacer(minLength: 0)

            Toggle("Automatic metadata", isOn: $draft.isEnabled)
                .toggleStyle(.switch)
                .disabled(!canEnableMetadata)
                .help(canEnableMetadata
                    ? "Apply scheduled metadata as files arrive"
                    : "Choose a one-way job with a local destination")
        }
        .padding(16)
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            ProgrammingMonthCalendar(
                selection: $selectedDate,
                programmedDays: programmedDays,
                calendar: calendar
            )
            .padding(12)

            Spacer(minLength: 12)
            Divider()

            Button {
                RegularWindowController.shared.prepareForOpening()
                openWindow(id: "photographers")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Manage All Photographers…", systemImage: "person.2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
            .help("Open the shared photographer library in a separate window")
        }
    }

    private var dayTimeline: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { moveDay(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous Day")

                Text(selectedDate.formatted(date: .complete, time: .omitted))
                    .font(.headline)
                    .frame(minWidth: 250)

                Button { moveDay(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next Day")

                Button("Today") { selectedDate = Date() }

                Spacer()

                Picker("Snap", selection: $snapMinutes) {
                    Text("5 min").tag(5)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                }
                .pickerStyle(.menu)
                .frame(width: 125)

                Button(action: editSelectedClip) {
                    Image(systemName: "pencil")
                        .frame(width: 16, height: 16)
                }
                .disabled(selectedClipIDs.count != 1)
                .help("Edit Selected Clip (Return)")

                Button(action: copySelectedClips) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 16, height: 16)
                }
                .disabled(selectedClipIDs.isEmpty)
                .help("Copy Selected Clips (Command-C)")

                Button(action: pasteClips) {
                    Image(systemName: "doc.on.clipboard")
                        .frame(width: 16, height: 16)
                }
                .disabled(copiedClips.isEmpty || playhead == nil)
                .help(pasteHelp)

                Button(role: .destructive, action: deleteSelectedClips) {
                    Image(systemName: "trash")
                        .frame(width: 16, height: 16)
                }
                .disabled(selectedClipIDs.isEmpty)
                .help("Delete Selected Clips")

                Button(action: addClip) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Add Metadata Clip")
                .disabled(selectedPhotographer == nil)
                .help(selectedPhotographer == nil ? "Select a photographer first" : "Add a clip to the selected photographer")
            }
            .padding(14)

            Divider()

            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        TimelineHourHeader(day: selectedDate)

                        if timelinePhotographers.isEmpty {
                            ContentUnavailableView {
                                Label("No photographer tracks", systemImage: "person.crop.circle.badge.plus")
                            } description: {
                                Text("Use the row below to add a new or known photographer.")
                            }
                            .frame(height: 180)
                        }

                        ForEach(timelinePhotographers) { photographer in
                            TimelineTrack(
                                photographer: photographer,
                                clips: clips(for: photographer),
                                allClips: draft.clips,
                                day: selectedDate,
                                color: color(for: photographer),
                                snapMinutes: snapMinutes,
                                selectedClipIDs: selectedClipIDs,
                                playheadDate: playhead?.date,
                                showsPlayhead: playhead?.photographerID == photographer.id,
                                canPaste: !copiedClips.isEmpty && playhead != nil,
                                isSelected: selectedPhotographerID == photographer.id,
                                processedFileCount: processedFileCount(for: photographer),
                                onSelectPhotographer: {
                                    selectedPhotographerID = photographer.id
                                    selectedClipIDs = []
                                    timelineFocused = true
                                },
                                onEditPhotographer: {
                                    selectedPhotographerID = photographer.id
                                    editingPhotographerID = photographer.id
                                },
                                onRequestRemove: {
                                    selectedPhotographerID = photographer.id
                                    photographerPendingDeletion = photographer
                                },
                                onBeginReordering: {
                                    draggedPhotographerID = photographer.id
                                },
                                onSelect: selectClip,
                                onEdit: editClip,
                                onCreate: createClip,
                                onMove: moveClip,
                                onResize: resizeClip,
                                onPlacePlayhead: placePlayhead,
                                onPasteAtPlayhead: pasteClips
                            )
                            .onDrop(
                                of: [UTType.text],
                                delegate: PhotographerTrackDropDelegate(
                                    destinationID: photographer.id,
                                    photographers: $draft.photographers,
                                    draggedPhotographerID: $draggedPhotographerID
                                )
                            )
                            Divider()
                        }

                        TimelineAddPhotographerRow(
                            knownPhotographers: knownPhotographers,
                            onAddNew: addPhotographer,
                            onAddKnown: addKnownPhotographer
                        )
                    }
                    .frame(
                        width: max(viewport.size.width, 920),
                        alignment: .topLeading
                    )
                }
                .focusable()
                .focused($timelineFocused)
                .onKeyPress(.leftArrow) {
                    selectAdjacentClip(horizontalOffset: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    selectAdjacentClip(horizontalOffset: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectAdjacentTrack(offset: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    selectAdjacentTrack(offset: 1)
                    return .handled
                }
            }

            if timelineFocused {
                timelineKeyboardShortcuts
            }
        }
    }

    private var timelineKeyboardShortcuts: some View {
        Group {
            Button("Copy", action: copySelectedClips)
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste", action: pasteClips)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(copiedClips.isEmpty || playhead == nil)
            Button("Select All Clips", action: selectAllClipsForDay)
                .keyboardShortcut("a", modifiers: .command)
            Button("Edit Clip", action: editSelectedClip)
                .keyboardShortcut(.return, modifiers: [])
            Button("Delete Clips", action: deleteSelectedClips)
                .keyboardShortcut(.delete, modifiers: [])
            Button("Previous Day") { moveDay(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Day") { moveDay(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = draft.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let selectedJob, draft.isEnabled, !canEnableMetadata {
                Label("\(selectedJob.name) needs a one-way local destination.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Matching uses the filename initials and \(draft.timestampPolicy.title.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if draft != lastSavedDraft, canAutosaveDraft {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if saveConfirmation {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let reprocessStatusText {
                Text(reprocessStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: previewConfiguredLocalFolder) {
                if isPreviewingMetadata {
                    ProgressView()
                        .controlSize(.small)
                    Text("Previewing…")
                } else {
                    Text("Preview Local Folder")
                }
            }
            .disabled(!canPreviewMetadata)
            .help(previewHelp)
            Button {
                showReprocessConfirmation = true
            } label: {
                if isReprocessing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reprocessing…")
                } else {
                    Text("Reprocess Existing Files…")
                }
            }
            .disabled(!canReprocessMetadata)
            .help(reprocessHelp)
        }
        .padding(14)
    }

    private var selectedJobBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedJobID },
            set: { store.selectedJobID = $0 }
        )
    }

    private var selectedJob: SyncJob? {
        guard let selectedJobID = store.selectedJobID else { return nil }
        return store.jobs.first(where: { $0.id == selectedJobID })
    }

    private var canEnableMetadata: Bool {
        guard let selectedJob, selectedJob.direction != .bidirectional else { return false }
        let target = selectedJob.direction == .leftToRight ? selectedJob.right : selectedJob.left
        return target.kind == .local
    }

    private var metadataLocalEndpoint: Endpoint? {
        guard let selectedJob, selectedJob.direction != .bidirectional else { return nil }
        let target = selectedJob.direction == .leftToRight ? selectedJob.right : selectedJob.left
        return target.kind == .local ? target : nil
    }

    private var canAutosaveDraft: Bool {
        guard let loadedJobID else { return false }
        return canPersistDraft(draft, for: loadedJobID)
    }

    private func canPersistDraft(_ automation: MetadataAutomation, for jobID: UUID) -> Bool {
        guard automation.validationMessage == nil,
              let job = store.jobs.first(where: { $0.id == jobID }) else {
            return false
        }
        guard automation.isEnabled else { return true }
        guard job.direction != .bidirectional else { return false }
        let target = job.direction == .leftToRight ? job.right : job.left
        return target.kind == .local
    }

    private var canReprocessMetadata: Bool {
        guard let loadedJobID else { return false }
        return draft.isEnabled
            && draft.validationMessage == nil
            && canEnableMetadata
            && draft.timestampPolicy != .localArrival
            && !store.isJobBusy(loadedJobID)
    }

    private var previewValidationMessage: String? {
        var enabledDraft = draft
        enabledDraft.isEnabled = true
        return enabledDraft.validationMessage
    }

    private var canPreviewMetadata: Bool {
        loadedJobID != nil
            && metadataLocalEndpoint?.bookmark != nil
            && previewValidationMessage == nil
            && !isPreviewingMetadata
    }

    private var previewHelp: String {
        if let previewValidationMessage {
            return previewValidationMessage
        }
        guard let metadataLocalEndpoint else {
            return "Automatic metadata requires a one-way job with a local destination."
        }
        return "Preview the unsaved programming draft against \(selectedJob?.localDestinationDisplayPath ?? metadataLocalEndpoint.localPath). No files are changed."
    }

    private var isReprocessing: Bool {
        guard let loadedJobID else { return false }
        return store.metadataReprocessPhases[loadedJobID] == .running
    }

    private var reprocessStatusText: String? {
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

    private var reprocessHelp: String {
        if draft.timestampPolicy == .localArrival {
            return "Arrival timestamps were not recorded for existing files. Choose source modification or camera capture time."
        }
        if !draft.isEnabled {
            return "Enable automatic metadata before reprocessing existing files."
        }
        return "Apply the saved schedule to matching files already in the local destination."
    }

    private var reprocessConfirmationMessage: String {
        let target = selectedJob?.localDestinationDisplayPath ?? "the local destination"
        let policyNote = draft.existingFieldPolicy == .fillEmpty
            ? "Existing non-empty fields will be preserved."
            : "Non-empty programmed values will overwrite existing fields."
        return "Matching files in \(target) will be rewritten safely in place; the source is untouched and modification dates are retained. \(policyNote)"
    }

    private func previewConfiguredLocalFolder() {
        guard let selectedJob, let metadataLocalEndpoint else { return }
        let previewDraft = draft
        let filter = selectedJob.filter
        isPreviewingMetadata = true
        metadataPreviewError = nil
        Task {
            do {
                let folderAccess = try BookmarkAccess(endpoint: metadataLocalEndpoint)
                let folderURL: URL
                if selectedJob.usesManagedFolderStructure {
                    folderURL = try ManagedOutputFolder.syncedFiles.url(
                        inside: folderAccess.url,
                        createIfNeeded: true
                    )
                } else {
                    folderURL = folderAccess.url
                }
                let result = try await Task.detached(priority: .userInitiated) {
                    _ = folderAccess
                    return try MetadataPreviewService.previewLocalFolder(
                        at: folderURL,
                        automation: previewDraft,
                        filter: filter
                    )
                }.value
                metadataPreviewFolderName = folderURL.lastPathComponent
                metadataPreview = result
            } catch {
                metadataPreviewError = error.localizedDescription
            }
            isPreviewingMetadata = false
        }
    }

    private var selectedPhotographer: PhotographerProfile? {
        guard let selectedPhotographerID else { return nil }
        return draft.photographers.first(where: { $0.id == selectedPhotographerID })
    }

    private var playheadSummary: String? {
        guard let playhead,
              let photographer = draft.photographers.first(where: { $0.id == playhead.photographerID }) else {
            return nil
        }
        return "\(photographer.photographerName) · \(playhead.date.formatted(date: .omitted, time: .shortened))"
    }

    private var pasteHelp: String {
        if let playheadSummary {
            return "Paste at \(playheadSummary) (Command-V)"
        }
        return "Click a track to place the playhead, then paste (Command-V)"
    }

    private var timelinePhotographers: [PhotographerProfile] {
        draft.photographers
    }

    private var programmedDays: Set<Date> {
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

    private var knownPhotographers: [PhotographerProfile] {
        let assignedIDs = Set(draft.photographers.map(\.id))
        return store.photographerLibrary.filter { !assignedIDs.contains($0.id) }
    }

    private func clips(for photographer: PhotographerProfile) -> [MetadataScheduleClip] {
        draft.clips
            .filter {
                $0.photographerID == photographer.id
                    && $0.overlaps(dayContaining: selectedDate, calendar: calendar)
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func processedFileCount(for photographer: PhotographerProfile) -> Int {
        guard let loadedJobID else { return 0 }
        let processedPaths = store.metadataAuditTrail(for: loadedJobID).lazy
            .filter { $0.status == .applied && $0.photographerID == photographer.id }
            .map(\.relativePath)
        return Set(processedPaths).count
    }

    private func photographerBinding(for id: UUID) -> Binding<PhotographerProfile>? {
        guard let index = draft.photographers.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.photographers[index] },
            set: { draft.photographers[index] = $0 }
        )
    }

    private func loadSelectedJob() {
        autosaveTask?.cancel()
        autosaveTask = nil
        saveConfirmation = false
        guard let job = selectedJob else {
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

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        saveConfirmation = false
        guard draft != lastSavedDraft, canAutosaveDraft else { return }

        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            _ = save()
            autosaveTask = nil
        }
    }

    private func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard draft != lastSavedDraft else { return }
        _ = save()
    }

    private func refreshDraftPhotographersFromLibrary() {
        let libraryByID = Dictionary(uniqueKeysWithValues: store.photographerLibrary.map { ($0.id, $0) })
        for index in draft.photographers.indices {
            if let updatedProfile = libraryByID[draft.photographers[index].id] {
                draft.photographers[index] = updatedProfile
            }
        }
    }

    private func addPhotographer() {
        let photographer = PhotographerProfile(
            name: "Photographer",
            filenamePrefix: uniquePrefix(),
            creator: "Photographer",
            copyrightNotice: ""
        )
        draft.photographers.append(photographer)
        selectedPhotographerID = photographer.id
    }

    private func addKnownPhotographer(_ photographer: PhotographerProfile) {
        guard !draft.photographers.contains(where: { $0.id == photographer.id }) else {
            selectedPhotographerID = photographer.id
            return
        }
        draft.photographers.append(photographer)
        selectedPhotographerID = photographer.id
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

    private func removePhotographer(_ photographer: PhotographerProfile) {
        draft.photographers.removeAll { $0.id == photographer.id }
        draft.clips.removeAll { $0.photographerID == photographer.id }
        selectedClipIDs = selectedClipIDs.filter { id in draft.clips.contains(where: { $0.id == id }) }
        selectedPhotographerID = draft.photographers.first?.id
        if playhead?.photographerID == photographer.id { playhead = nil }
        photographerPendingDeletion = nil
    }

    private func addClip() {
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

    private func updateClip(_ clip: MetadataScheduleClip) {
        guard let index = draft.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        draft.clips[index] = clip
        editingClipID = nil
    }

    private func selectClip(_ clip: MetadataScheduleClip) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedClipIDs.contains(clip.id) {
                selectedClipIDs.remove(clip.id)
            } else {
                selectedClipIDs.insert(clip.id)
            }
        } else {
            selectedClipIDs = [clip.id]
        }
        selectedPhotographerID = clip.photographerID
        timelineFocused = true
    }

    private func editSelectedClip() {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return }
        editingClipID = id
    }

    private func editClip(_ clip: MetadataScheduleClip) {
        selectedClipIDs = [clip.id]
        selectedPhotographerID = clip.photographerID
        editingClipID = clip.id
    }

    private func createClip(
        for photographer: PhotographerProfile,
        from start: Date,
        to end: Date
    ) {
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
        timelineFocused = true
    }

    private func copySelectedClips() {
        copiedClips = draft.clips
            .filter { selectedClipIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
                return lhs.photographerID.uuidString < rhs.photographerID.uuidString
            }
    }

    private func pasteClips() {
        guard let playhead else { return }
        pasteClips(to: playhead.date, on: playhead.photographerID)
    }

    private func pasteClips(to date: Date, on photographerID: UUID) {
        guard !copiedClips.isEmpty else { return }
        let pasted = MetadataTimelineEditing.copies(
            of: copiedClips,
            anchoredAt: date,
            on: photographerID
        )
        finishPasting(pasted, playhead: TimelinePlayhead(photographerID: photographerID, date: date))
    }

    private func finishPasting(_ pasted: [MetadataScheduleClip], playhead newPlayhead: TimelinePlayhead? = nil) {
        guard !pasted.isEmpty else { return }
        draft.clips.append(contentsOf: pasted)
        selectedClipIDs = Set(pasted.map(\.id))
        if let newPlayhead {
            playhead = newPlayhead
            selectedPhotographerID = newPlayhead.photographerID
        }
        timelineFocused = true
    }

    private func deleteSelectedClips() {
        guard !selectedClipIDs.isEmpty else { return }
        draft.clips.removeAll { selectedClipIDs.contains($0.id) }
        selectedClipIDs = []
    }

    private func selectAllClipsForDay() {
        selectedClipIDs = Set(draft.clips.filter {
            $0.overlaps(dayContaining: selectedDate, calendar: calendar)
        }.map(\.id))
        timelineFocused = true
    }

    private func moveClip(_ clip: MetadataScheduleClip, by interval: TimeInterval, duplicating: Bool) {
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

    private func placePlayhead(on photographerID: UUID, at date: Date) {
        playhead = TimelinePlayhead(photographerID: photographerID, date: date)
        selectedPhotographerID = photographerID
        selectedClipIDs = []
        timelineFocused = true
    }

    private func resizeClip(
        _ clip: MetadataScheduleClip,
        edge: MetadataClipResizeEdge,
        by interval: TimeInterval
    ) {
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

    private func applyClipChange(_ clip: MetadataScheduleClip) {
        guard let index = draft.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        draft.clips[index] = clip
        selectedClipIDs = [clip.id]
        selectedPhotographerID = clip.photographerID
    }

    private func selectAdjacentClip(horizontalOffset: Int) {
        let visible = draft.clips
            .filter { $0.overlaps(dayContaining: selectedDate, calendar: calendar) }
            .sorted { $0.startsAt < $1.startsAt }
        guard !visible.isEmpty else { return }
        guard selectedClipIDs.count == 1,
              let selectedID = selectedClipIDs.first,
              let selected = visible.first(where: { $0.id == selectedID }) else {
            selectClip(visible[horizontalOffset < 0 ? visible.count - 1 : 0])
            return
        }
        let sameTrack = visible.filter { $0.photographerID == selected.photographerID }
        guard let index = sameTrack.firstIndex(where: { $0.id == selected.id }) else { return }
        let target = min(max(index + horizontalOffset, 0), sameTrack.count - 1)
        selectClip(sameTrack[target])
    }

    private func selectAdjacentTrack(offset: Int) {
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

    private func moveDay(by value: Int) {
        selectedDate = calendar.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
        playhead = nil
        selectedClipIDs = selectedClipIDs.filter { id in
            draft.clips.first(where: { $0.id == id })?.overlaps(dayContaining: selectedDate, calendar: calendar) == true
        }
    }

    private func color(for photographer: PhotographerProfile) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
        let index = draft.photographers.firstIndex(where: { $0.id == photographer.id }) ?? 0
        return colors[index % colors.count]
    }

    @discardableResult
    private func save() -> Bool {
        guard canAutosaveDraft,
              let loadedJobID,
              store.saveMetadataAutomation(draft, for: loadedJobID) else {
            saveConfirmation = false
            return false
        }
        lastSavedDraft = draft
        saveConfirmation = true
        return true
    }
}

private struct MetadataFolderPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let folderName: String
    let timestampPolicy: MetadataTimestampPolicy
    let result: MetadataPreviewResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Metadata Preview")
                        .font(.title2.weight(.semibold))
                    Text("\(folderName) · \(timestampPolicy.title)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 18) {
                Label("\(result.scanned) scanned", systemImage: "doc.text.magnifyingglass")
                Label("\(result.willApply) will apply", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(result.alreadyApplied) already applied", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.blue)
                Label("\(result.skipped) skipped", systemImage: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Read-only preview — no files were changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if result.items.isEmpty {
                ContentUnavailableView(
                    "No matching file types",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("The selected job’s file filter found nothing to preview in this folder.")
                )
            } else {
                Table(result.items) {
                    TableColumn("File") { item in
                        Text(item.relativePath)
                            .lineLimit(1)
                            .help(item.relativePath)
                    }
                    .width(min: 220, ideal: 300)

                    TableColumn("Result") { item in
                        Label(item.status.title, systemImage: item.status.symbolName)
                            .foregroundStyle(item.status.color)
                    }
                    .width(min: 150, ideal: 190)

                    TableColumn("Photographer") { item in
                        Text(item.photographerName ?? "—")
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Clip") { item in
                        Text(item.clipName ?? "—")
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Schedule time") { item in
                        if let scheduledAt = item.scheduledAt {
                            Text(scheduledAt.formatted(date: .abbreviated, time: .standard))
                        } else {
                            Text("—")
                        }
                    }
                    .width(min: 160, ideal: 190)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 520)
    }
}

private struct ProgrammingMonthCalendar: View {
    @Binding var selection: Date
    let programmedDays: Set<Date>
    let calendar: Calendar
    @State private var displayedMonth: Date

    init(
        selection: Binding<Date>,
        programmedDays: Set<Date>,
        calendar: Calendar = .current
    ) {
        _selection = selection
        self.programmedDays = programmedDays
        self.calendar = calendar
        _displayedMonth = State(initialValue: Self.monthStart(for: selection.wrappedValue, calendar: calendar))
    }

    var body: some View {
        VStack(spacing: 12) {
            monthHeader

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayButton(date)
                    } else {
                        Color.clear
                            .aspectRatio(1.15, contentMode: .fit)
                            .accessibilityHidden(true)
                    }
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(.teal)
                    .frame(width: 7, height: 7)
                Text("Programmed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Today") {
                    let today = Date()
                    selection = today
                    displayedMonth = Self.monthStart(for: today, calendar: calendar)
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .onChange(of: selection) { _, newSelection in
            let selectionMonth = Self.monthStart(for: newSelection, calendar: calendar)
            if !calendar.isDate(selectionMonth, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = selectionMonth
            }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 10) {
            monthButton(systemImage: "chevron.left", offset: -1)

            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .frame(maxWidth: .infinity)

            monthButton(systemImage: "chevron.right", offset: 1)
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let firstIndex = max(min(calendar.firstWeekday - 1, symbols.count - 1), 0)
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    private var monthDays: [Date?] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let leadingBlanks = (weekday - calendar.firstWeekday + 7) % 7
        var days = Array<Date?>(repeating: nil, count: leadingBlanks)
        days.append(contentsOf: dayRange.compactMap { day -> Date? in
            calendar.date(bySetting: .day, value: day, of: displayedMonth)
        })
        let trailingBlanks = (7 - days.count % 7) % 7
        days.append(contentsOf: Array<Date?>(repeating: nil, count: trailingBlanks))
        return days
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isProgrammed = programmedDays.contains(calendar.startOfDay(for: date))
        let isToday = calendar.isDateInToday(date)

        return Button {
            selection = date
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dayBackground(isSelected: isSelected, isProgrammed: isProgrammed))

                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.tint, lineWidth: 1)
                }

                VStack(spacing: 2) {
                    Text(date.formatted(.dateTime.day()))
                        .font(.body.monospacedDigit().weight(isSelected || isToday ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)

                    Circle()
                        .fill(isSelected ? Color.white : Color.teal)
                        .frame(width: 5, height: 5)
                        .opacity(isProgrammed ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .aspectRatio(1.15, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(isProgrammed ? "Programmed" : "No programming")
    }

    private func dayBackground(isSelected: Bool, isProgrammed: Bool) -> Color {
        if isSelected { return .accentColor }
        if isProgrammed { return .teal.opacity(0.2) }
        return .clear
    }

    private func monthButton(systemImage: String, offset: Int) -> some View {
        Button {
            displayedMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth)
                .map { Self.monthStart(for: $0, calendar: calendar) }
                ?? displayedMonth
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(offset < 0 ? "Previous Month" : "Next Month")
    }

    private static func monthStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

private extension MetadataPreviewStatus {
    var symbolName: String {
        switch self {
        case .willApply: "checkmark.circle.fill"
        case .alreadyApplied: "checkmark.seal.fill"
        case .existingMetadataPreserved: "lock.circle.fill"
        case .noMatchingPhotographer: "person.crop.circle.badge.questionmark"
        case .noScheduledClip: "calendar.badge.exclamationmark"
        case .captureTimeUnavailable: "camera.badge.ellipsis"
        }
    }

    var color: Color {
        switch self {
        case .willApply: .green
        case .alreadyApplied: .blue
        case .existingMetadataPreserved,
             .noMatchingPhotographer,
             .noScheduledClip,
             .captureTimeUnavailable: .secondary
        }
    }
}

struct PhotographerEditor: View {
    @Binding var photographer: PhotographerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photographer Profile").font(.headline)
            TextField("Photographer / creator", text: photographerNameBinding)
            TextField("Filename initials", text: $photographer.filenamePrefix)
                .textCase(.uppercase)
            Text("Separate initials from multiple cameras with commas, for example JAD, JDX.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Copyright notice", text: $photographer.copyrightNotice)
            Text("Used as the photographer name and IPTC Creator/byline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var photographerNameBinding: Binding<String> {
        Binding(
            get: { photographer.photographerName },
            set: { newValue in
                photographer.name = newValue
                photographer.creator = newValue
            }
        )
    }
}

struct PhotographerWorkHoursControl: View {
    @Binding var photographer: PhotographerProfile
    let day: Date?
    let calendar: Calendar
    @State private var isPresented = false

    init(
        photographer: Binding<PhotographerProfile>,
        day: Date? = nil,
        calendar: Calendar = .current
    ) {
        _photographer = photographer
        self.day = day
        self.calendar = calendar
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Work Hours")
                    .fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Edit…") {
                isPresented = true
            }
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Work Hours")
                        .font(.title3.weight(.semibold))

                    PhotographerDefaultWorkHoursEditor(
                        photographer: $photographer,
                        calendar: calendar
                    )

                    if let day {
                        Divider()
                        PhotographerDayWorkHoursEditor(
                            photographer: $photographer,
                            day: day,
                            calendar: calendar
                        )
                    }
                }
                .padding(18)
                .frame(width: 430)
            }
        }
    }

    private var summary: String {
        guard let day else {
            guard let hours = photographer.workHours else { return "No profile default" }
            return "Profile default \(formatted(hours))"
        }

        let date = day.formatted(date: .abbreviated, time: .omitted)
        if let override = photographer.workHoursOverride(on: day, calendar: calendar) {
            guard let hours = override.hours else { return "Day off on \(date)" }
            return "Custom \(formatted(hours)) on \(date)"
        }
        guard let hours = photographer.workHours else { return "No hours set for \(date)" }
        return "Profile default \(formatted(hours)) on \(date)"
    }

    private func formatted(_ hours: PhotographerWorkHours) -> String {
        "\(formatted(minutes: hours.startMinutes))–\(formatted(minutes: hours.endMinutes))"
    }

    private func formatted(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct PhotographerDefaultWorkHoursEditor: View {
    @Binding var photographer: PhotographerProfile
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use profile default hours", isOn: workHoursEnabled)
            if photographer.workHours != nil {
                HStack {
                    DatePicker(
                        "From",
                        selection: workHourBinding(isStart: true),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "To",
                        selection: workHourBinding(isStart: false),
                        displayedComponents: .hourAndMinute
                    )
                }
            }
            Text("Default hours apply unless a specific calendar day overrides them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var workHoursEnabled: Binding<Bool> {
        Binding(
            get: { photographer.workHours != nil },
            set: { isEnabled in
                photographer.workHours = isEnabled ? photographer.workHours ?? .standard : nil
            }
        )
    }

    private func workHourBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let hours = photographer.workHours ?? .standard
                let minutes = isStart ? hours.startMinutes : hours.endMinutes
                return calendar.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = calendar.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var hours = photographer.workHours ?? .standard
                if isStart {
                    hours.startMinutes = min(minutes, 24 * 60 - 2)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.endMinutes = min(hours.startMinutes + 60, 24 * 60 - 1)
                    }
                } else {
                    hours.endMinutes = max(minutes, 1)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.startMinutes = max(hours.endMinutes - 60, 0)
                    }
                }
                photographer.workHours = hours
            }
        )
    }
}

private enum PhotographerDayWorkHoursMode: String, CaseIterable, Identifiable {
    case profileDefault
    case custom
    case dayOff

    var id: Self { self }

    var title: String {
        switch self {
        case .profileDefault: "Profile Default"
        case .custom: "Custom Hours"
        case .dayOff: "Day Off"
        }
    }
}

private struct PhotographerDayWorkHoursEditor: View {
    @Binding var photographer: PhotographerProfile
    let day: Date
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hours for \(day.formatted(date: .abbreviated, time: .omitted))")
                .font(.headline)

            Picker("Schedule", selection: modeBinding) {
                ForEach(PhotographerDayWorkHoursMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if mode == .custom {
                HStack {
                    DatePicker(
                        "From",
                        selection: customWorkHourBinding(isStart: true),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "To",
                        selection: customWorkHourBinding(isStart: false),
                        displayedComponents: .hourAndMinute
                    )
                }
            } else {
                Text(dayScheduleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu("Apply to This Week") {
                Button("Apply to Weekdays") {
                    applyCurrentScheduleToWeek(weekdaysOnly: true)
                }
                Button("Apply to All 7 Days") {
                    applyCurrentScheduleToWeek(weekdaysOnly: false)
                }
                Divider()
                Button("Reset Week to Profile Defaults") {
                    resetWeekToProfileDefaults()
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var mode: PhotographerDayWorkHoursMode {
        guard let override = photographer.workHoursOverride(on: day, calendar: calendar) else {
            return .profileDefault
        }
        return override.hours == nil ? .dayOff : .custom
    }

    private var modeBinding: Binding<PhotographerDayWorkHoursMode> {
        Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .profileDefault:
                    photographer.clearWorkHoursOverride(on: day, calendar: calendar)
                case .custom:
                    let hours = photographer.workHours(on: day, calendar: calendar) ?? .standard
                    photographer.setWorkHoursOverride(hours, on: day, calendar: calendar)
                case .dayOff:
                    photographer.setWorkHoursOverride(nil, on: day, calendar: calendar)
                }
            }
        )
    }

    private var dayScheduleDescription: String {
        switch mode {
        case .profileDefault:
            guard let hours = photographer.workHours else {
                return "No default hours are set."
            }
            return "Using profile default: \(formatted(hours))."
        case .dayOff:
            return "This photographer is not working on this date."
        case .custom:
            return ""
        }
    }

    private func customWorkHourBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let hours = photographer.workHoursOverride(on: day, calendar: calendar)?.hours ?? .standard
                let minutes = isStart ? hours.startMinutes : hours.endMinutes
                return calendar.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: day
                ) ?? day
            },
            set: { date in
                let components = calendar.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var hours = photographer.workHoursOverride(on: day, calendar: calendar)?.hours ?? .standard
                if isStart {
                    hours.startMinutes = min(minutes, 24 * 60 - 2)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.endMinutes = min(hours.startMinutes + 60, 24 * 60 - 1)
                    }
                } else {
                    hours.endMinutes = max(minutes, 1)
                    if hours.endMinutes <= hours.startMinutes {
                        hours.startMinutes = max(hours.endMinutes - 60, 0)
                    }
                }
                photographer.setWorkHoursOverride(hours, on: day, calendar: calendar)
            }
        )
    }

    private func applyCurrentScheduleToWeek(weekdaysOnly: Bool) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return }
        let sourceOverride = photographer.workHoursOverride(on: day, calendar: calendar)
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start),
                  !weekdaysOnly || !calendar.isDateInWeekend(date) else {
                continue
            }
            if let sourceOverride {
                photographer.setWorkHoursOverride(sourceOverride.hours, on: date, calendar: calendar)
            } else {
                photographer.clearWorkHoursOverride(on: date, calendar: calendar)
            }
        }
    }

    private func resetWeekToProfileDefaults() {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return }
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start) else { continue }
            photographer.clearWorkHoursOverride(on: date, calendar: calendar)
        }
    }

    private func formatted(_ hours: PhotographerWorkHours) -> String {
        "\(formatted(minutes: hours.startMinutes))–\(formatted(minutes: hours.endMinutes))"
    }

    private func formatted(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct PendingClipChange: Identifiable {
    let id = UUID()
    let clip: MetadataScheduleClip
}

private struct TimelinePlayhead: Equatable {
    let photographerID: UUID
    let date: Date
}

private struct TimelinePhotographerEditor: View {
    @Binding var photographer: PhotographerProfile
    let day: Date
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit Photographer Track")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }

            PhotographerEditor(photographer: $photographer)
            Divider()
            PhotographerWorkHoursControl(
                photographer: $photographer,
                day: day
            )
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct TimelineAddPhotographerRow: View {
    let knownPhotographers: [PhotographerProfile]
    let onAddNew: () -> Void
    let onAddKnown: (PhotographerProfile) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button(action: onAddNew) {
                    Label("New Photographer", systemImage: "person.badge.plus")
                }

                if !knownPhotographers.isEmpty {
                    Divider()
                    Section("Known Photographers") {
                        ForEach(knownPhotographers) { photographer in
                            Button {
                                onAddKnown(photographer)
                            } label: {
                                Text("\(photographer.photographerName) (\(photographer.formattedFilenamePrefixes))")
                            }
                        }
                    }
                }
            } label: {
                Label("Add Photographer", systemImage: "plus.circle.fill")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 177)
            .help(knownPhotographers.isEmpty ? "Add a photographer" : "Add a new or known photographer")

            Rectangle()
                .fill(.quaternary.opacity(0.25))
                .overlay(alignment: .leading) {
                    Text("Tracks are matched using filename initials")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12)
                }
        }
        .frame(height: 52)
    }
}

private struct PhotographerTrackDropDelegate: DropDelegate {
    let destinationID: UUID
    @Binding var photographers: [PhotographerProfile]
    @Binding var draggedPhotographerID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedPhotographerID,
              draggedPhotographerID != destinationID,
              let sourceIndex = photographers.firstIndex(where: { $0.id == draggedPhotographerID }),
              let destinationIndex = photographers.firstIndex(where: { $0.id == destinationID }) else {
            return
        }

        withAnimation(.snappy(duration: 0.18)) {
            photographers.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPhotographerID = nil
        return true
    }
}

private struct TimelineHourHeader: View {
    let day: Date
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 0) {
            Text("Photographer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 165, alignment: .leading)
                .padding(.leading, 12)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(stride(from: 0, to: 24, by: 3)), id: \.self) { hour in
                        Text(String(format: "%02d:00", hour))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .offset(x: max(0, proxy.size.width * CGFloat(hour) / 24 - 15))
                    }
                    if calendar.isDateInToday(day) {
                        Rectangle()
                            .fill(.red.opacity(0.75))
                            .frame(width: 1)
                            .offset(x: currentTimeOffset(totalWidth: proxy.size.width))
                    }

                }
            }

            VStack(spacing: 0) {
                Text("24:00")
                    .monospacedDigit()
                Text(nextDayLabel)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 68)
            .frame(maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.1))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 2)
            }
            .accessibilityLabel("Next day, \(nextDayLabel), starts at midnight")
        }
        .frame(height: 34)
        .background(.bar)
    }

    private var nextDayLabel: String {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return nextDay.formatted(.dateTime.weekday(.abbreviated).day())
    }

    private func currentTimeOffset(totalWidth: CGFloat) -> CGFloat {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return CGFloat(Date().timeIntervalSince(start) / end.timeIntervalSince(start)) * totalWidth
    }
}

private struct TimelineTrack: View {
    let photographer: PhotographerProfile
    let clips: [MetadataScheduleClip]
    let allClips: [MetadataScheduleClip]
    let day: Date
    let color: Color
    let snapMinutes: Int
    let selectedClipIDs: Set<UUID>
    let playheadDate: Date?
    let showsPlayhead: Bool
    let canPaste: Bool
    let isSelected: Bool
    let processedFileCount: Int
    let onSelectPhotographer: () -> Void
    let onEditPhotographer: () -> Void
    let onRequestRemove: () -> Void
    let onBeginReordering: () -> Void
    let onSelect: (MetadataScheduleClip) -> Void
    let onEdit: (MetadataScheduleClip) -> Void
    let onCreate: (PhotographerProfile, Date, Date) -> Void
    let onMove: (MetadataScheduleClip, TimeInterval, Bool) -> Void
    let onResize: (MetadataScheduleClip, MetadataClipResizeEdge, TimeInterval) -> Void
    let onPlacePlayhead: (UUID, Date) -> Void
    let onPasteAtPlayhead: (Date, UUID) -> Void

    private let calendar = Calendar.current
    @GestureState private var creationDrag: DragGesture.Value?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .contentShape(Rectangle().inset(by: -6))
                    .onDrag {
                        onBeginReordering()
                        return NSItemProvider(object: photographer.id.uuidString as NSString)
                    }
                    .help("Drag to reorder this track")

                VStack(alignment: .leading, spacing: 3) {
                    Text(photographer.photographerName).fontWeight(.medium).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(photographer.formattedFilenamePrefixes)
                            .lineLimit(1)
                        Label(processedFileCount.formatted(), systemImage: "checkmark")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help(processedFileHelp)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 2)

                Button(action: onEditPhotographer) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Edit photographer and work hours")
            }
            .padding(.horizontal, 8)
            .frame(width: 177, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelectPhotographer)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(creationGesture(totalWidth: proxy.size.width))
                        .simultaneousGesture(playheadGesture(totalWidth: proxy.size.width))
                        .help("Click to place the playhead or drag to create a metadata clip")
                    workHoursBackground(totalWidth: proxy.size.width)
                    hourGrid
                    overlapHighlights(totalWidth: proxy.size.width)
                    currentTimeMarker(totalWidth: proxy.size.width)
                    creationPreview(totalWidth: proxy.size.width)
                    ForEach(clips) { clip in
                        TimelineClipView(
                            clip: clip,
                            color: color,
                            isSelected: selectedClipIDs.contains(clip.id),
                            continuesFromPreviousDay: clip.startsAt < dayStart,
                            continuesIntoNextDay: clip.endsAt > nextDay,
                            timeLabel: timeLabel(for: clip),
                            secondsPerPoint: dayDuration / max(proxy.size.width, 1),
                            onSelect: { onSelect(clip) },
                            onEdit: { onEdit(clip) },
                            onMove: { interval, duplicating in onMove(clip, interval, duplicating) },
                            onResize: { edge, interval in onResize(clip, edge, interval) }
                        )
                        .frame(width: clipWidth(clip, totalWidth: proxy.size.width), height: 44)
                        .offset(x: clipOffset(clip, totalWidth: proxy.size.width))
                    }
                    playheadMarker(totalWidth: proxy.size.width)
                }
            }
            .padding(.horizontal, 4)

            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 68)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 2)
                }
                .allowsHitTesting(false)
                .accessibilityLabel("Next day")
        }
        .frame(height: 58)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: onEditPhotographer) {
                Label("Edit Photographer…", systemImage: "slider.horizontal.3")
            }
            Button(role: .destructive, action: onRequestRemove) {
                Label("Remove Track", systemImage: "minus.circle")
            }
            Divider()
            Button {
                if let playheadDate { onPasteAtPlayhead(playheadDate, photographer.id) }
            } label: {
                Label(contextMenuPasteTitle, systemImage: "doc.on.clipboard")
            }
            .disabled(!canPaste || playheadDate == nil)
        }
    }

    private var dayStart: Date { calendar.startOfDay(for: day) }

    private var processedFileHelp: String {
        let files = processedFileCount == 1 ? "1 unique file" : "\(processedFileCount) unique files"
        return "Metadata successfully applied to \(files) for this photographer in the current job."
    }

    private var nextDay: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    }

    private var dayDuration: TimeInterval { nextDay.timeIntervalSince(dayStart) }

    private var contextMenuPasteTitle: String {
        guard let playheadDate else { return "Place Playhead to Paste" }
        return "Paste at \(playheadDate.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func workHoursBackground(totalWidth: CGFloat) -> some View {
        if let interval = photographer.workHours(on: day, calendar: calendar)?.interval(on: day, calendar: calendar) {
            Rectangle()
                .fill(color.opacity(0.12))
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: 52)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var hourGrid: some View {
        HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle()
                    .fill(.separator.opacity(0.45))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func creationPreview(totalWidth: CGFloat) -> some View {
        if let creationDrag {
            let interval = creationInterval(for: creationDrag, totalWidth: totalWidth)
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                .overlay(alignment: .leading) {
                    Text(creationTimeLabel(interval))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .lineLimit(1)
                }
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: 44)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
        }
    }

    private func creationGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .updating($creationDrag) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let interval = creationInterval(for: value, totalWidth: totalWidth)
                onCreate(photographer, interval.start, interval.end)
            }
    }

    private func playheadGesture(totalWidth: CGFloat) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                onPlacePlayhead(photographer.id, playheadDate(at: value.location.x, totalWidth: totalWidth))
            }
    }

    private func playheadDate(at location: CGFloat, totalWidth: CGFloat) -> Date {
        let fraction = min(max(location / max(totalWidth, 1), 0), 1)
        let unsnapped = dayStart.addingTimeInterval(Double(fraction) * dayDuration)
        let snapped = MetadataTimelineEditing.snapped(unsnapped, toMinutes: snapMinutes, calendar: calendar)
        let latest = nextDay.addingTimeInterval(-TimeInterval(max(snapMinutes, 1) * 60))
        return min(max(snapped, dayStart), latest)
    }

    private func creationInterval(
        for drag: DragGesture.Value,
        totalWidth: CGFloat
    ) -> DateInterval {
        let safeWidth = max(totalWidth, 1)
        return MetadataTimelineEditing.creationInterval(
            on: day,
            from: Double(drag.startLocation.x / safeWidth),
            to: Double(drag.location.x / safeWidth),
            snapMinutes: snapMinutes,
            calendar: calendar
        )
    }

    private func creationTimeLabel(_ interval: DateInterval) -> String {
        let start = interval.start.formatted(date: .omitted, time: .shortened)
        let end = interval.end.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    @ViewBuilder
    private func overlapHighlights(totalWidth: CGFloat) -> some View {
        ForEach(MetadataTimelineAnalysis.overlaps(
            in: allClips,
            for: photographer.id,
            on: day,
            calendar: calendar
        ), id: \.self) { interval in
            Rectangle()
                .fill(.red.opacity(0.2))
                .frame(width: intervalWidth(interval, totalWidth: totalWidth), height: 52)
                .offset(x: intervalOffset(interval, totalWidth: totalWidth))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func currentTimeMarker(totalWidth: CGFloat) -> some View {
        if calendar.isDateInToday(day) {
            Rectangle()
                .fill(.red.opacity(0.75))
                .frame(width: 1, height: 52)
                .offset(x: CGFloat(Date().timeIntervalSince(dayStart) / dayDuration) * totalWidth)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func playheadMarker(totalWidth: CGFloat) -> some View {
        if showsPlayhead, let playheadDate {
            let offset = CGFloat(playheadDate.timeIntervalSince(dayStart) / dayDuration) * totalWidth
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 52)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .offset(y: -3)
            }
            .offset(x: offset - 1)
            .allowsHitTesting(false)
            .help("Paste starts at \(playheadDate.formatted(date: .omitted, time: .shortened))")
        }
    }

    private func clippedInterval(
        for clip: MetadataScheduleClip
    ) -> (start: TimeInterval, end: TimeInterval, dayDuration: TimeInterval) {
        return (
            max(clip.startsAt, dayStart).timeIntervalSince(dayStart),
            min(clip.endsAt, nextDay).timeIntervalSince(dayStart),
            nextDay.timeIntervalSince(dayStart)
        )
    }

    private func clipOffset(_ clip: MetadataScheduleClip, totalWidth: CGFloat) -> CGFloat {
        let interval = clippedInterval(for: clip)
        return CGFloat(interval.start / interval.dayDuration) * totalWidth
    }

    private func clipWidth(_ clip: MetadataScheduleClip, totalWidth: CGFloat) -> CGFloat {
        let interval = clippedInterval(for: clip)
        return max(42, CGFloat((interval.end - interval.start) / interval.dayDuration) * totalWidth)
    }

    private func timeLabel(for clip: MetadataScheduleClip) -> String {
        let start = clip.startsAt.formatted(date: .omitted, time: .shortened)
        let end = clip.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    private func intervalOffset(_ interval: DateInterval, totalWidth: CGFloat) -> CGFloat {
        CGFloat(interval.start.timeIntervalSince(dayStart) / dayDuration) * totalWidth
    }

    private func intervalWidth(_ interval: DateInterval, totalWidth: CGFloat) -> CGFloat {
        CGFloat(interval.duration / dayDuration) * totalWidth
    }
}

private struct TimelineClipView: View {
    let clip: MetadataScheduleClip
    let color: Color
    let isSelected: Bool
    let continuesFromPreviousDay: Bool
    let continuesIntoNextDay: Bool
    let timeLabel: String
    let secondsPerPoint: TimeInterval
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onMove: (TimeInterval, Bool) -> Void
    let onResize: (MetadataClipResizeEdge, TimeInterval) -> Void

    @GestureState private var moveTranslation: CGFloat = 0
    @GestureState private var startTranslation: CGFloat = 0
    @GestureState private var endTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.22))

            HStack(spacing: 3) {
                if continuesFromPreviousDay {
                    Image(systemName: "arrow.left")
                        .font(.caption2.weight(.bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(timelineTitle).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(timeLabel).font(.caption2.monospacedDigit()).lineLimit(1)
                }
                Spacer(minLength: 0)
                if continuesIntoNextDay {
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                }
            }
            .padding(.horizontal, 9)

            HStack(spacing: 0) {
                resizeHandle(edge: .start)
                Spacer(minLength: 0)
                resizeHandle(edge: .end)
            }
        }
        .foregroundStyle(color)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? color : color.opacity(0.7), lineWidth: isSelected ? 2.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .offset(x: moveTranslation)
        .gesture(interactionGesture)
        .help("Click to select, double-click to edit, drag to move, Option-drag to duplicate, or drag an edge to resize.")
    }

    private var interactionGesture: some Gesture {
        selectionAndMoveGesture
            .simultaneously(with: TapGesture(count: 2).onEnded { onEdit() })
    }

    private var selectionAndMoveGesture: some Gesture {
        // A single tap used to be exclusive with the double-tap gesture, which
        // delayed selection until the system's double-click interval elapsed.
        // Treat a zero-distance drag as an immediate click while retaining the
        // same movement threshold for dragging clips.
        DragGesture(minimumDistance: 0)
            .updating($moveTranslation) { value, state, _ in
                guard gestureDistance(value.translation) >= 3 else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard gestureDistance(value.translation) >= 3 else {
                    onSelect()
                    return
                }
                onMove(
                    value.translation.width * secondsPerPoint,
                    NSEvent.modifierFlags.contains(.option)
                )
            }
    }

    private func gestureDistance(_ translation: CGSize) -> CGFloat {
        hypot(translation.width, translation.height)
    }

    private var timelineTitle: String {
        let headline = clip.fields.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return headline.isEmpty ? clip.name : headline
    }

    private func resizeHandle(edge: MetadataClipResizeEdge) -> some View {
        let translation = edge == .start ? startTranslation : endTranslation
        return Capsule()
            .fill(isSelected ? color : color.opacity(0.7))
            .frame(width: 5, height: 27)
            .padding(.horizontal, 2)
            .offset(x: translation)
            .contentShape(Rectangle().inset(by: -4))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating(edge == .start ? $startTranslation : $endTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in onResize(edge, value.translation.width * secondsPerPoint) }
            )
    }
}

private struct MetadataClipEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var draft: MetadataScheduleClip
    @State private var keywordsText: String
    @State private var selectedPresetID: UUID?
    @State private var newPresetName: String
    @State private var presetPendingDeletion: MetadataPreset?
    @State private var validationMessage: String?

    let photographers: [PhotographerProfile]
    let onSave: (MetadataScheduleClip) -> Void

    init(
        clip: MetadataScheduleClip,
        photographers: [PhotographerProfile],
        onSave: @escaping (MetadataScheduleClip) -> Void
    ) {
        var editorClip = clip
        if editorClip.fields.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editorClip.fields.headline = clip.name
        }
        _draft = State(initialValue: editorClip)
        _keywordsText = State(initialValue: editorClip.fields.keywords.joined(separator: ", "))
        _selectedPresetID = State(initialValue: nil)
        _newPresetName = State(initialValue: editorClip.fields.headline)
        self.photographers = photographers
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Programming") {
                    Picker("Photographer", selection: $draft.photographerID) {
                        ForEach(photographers) { Text($0.name).tag($0.id) }
                    }
                    Text("Set the start, end, and duration directly on the timeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("IPTC Metadata") {
                    TextField("Headline", text: $draft.fields.headline)
                    Text("The headline is also used as the clip name on the timeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Description") {
                        TextEditor(text: $draft.fields.description)
                            .font(.body)
                            .frame(minHeight: 90)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(.separator, lineWidth: 1)
                            }
                    }
                    TextField("Keywords", text: $keywordsText, prompt: Text("politics, conference, Oslo"))
                    Text("Separate keywords with commas. Creator and copyright come from the photographer profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Reusable Presets") {
                    Picker("Preset", selection: $selectedPresetID) {
                        Text("Choose a preset").tag(Optional<UUID>.none)
                        ForEach(store.metadataPresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }

                    HStack {
                        Button("Load", action: loadSelectedPreset)
                            .disabled(selectedPreset == nil)
                        Button("Update", action: updateSelectedPreset)
                            .disabled(selectedPreset == nil)
                        Button("Delete", role: .destructive) {
                            presetPendingDeletion = selectedPreset
                        }
                        .disabled(selectedPreset == nil)
                    }

                    HStack {
                        TextField("New preset name", text: $newPresetName)
                        Button("Save as New", action: saveNewPreset)
                            .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("Loading copies only the metadata values. Clips remain standalone, so later preset changes do not alter existing programming.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: attemptSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 620)
        .confirmationDialog(
            "Delete reusable preset?",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("Delete \(preset.name)", role: .destructive) {
                if store.removeMetadataPreset(preset.id) {
                    selectedPresetID = nil
                }
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("Existing clips that used \(preset.name) keep their copied metadata values.")
        }
    }

    private func attemptSave() {
        normalizeKeywords()
        let trimmedHeadline = draft.fields.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeadline.isEmpty else {
            validationMessage = "Give the metadata a headline."
            return
        }
        draft.fields.headline = trimmedHeadline
        draft.name = trimmedHeadline
        validationMessage = nil
        commitSave()
    }

    private func commitSave() {
        onSave(draft)
        dismiss()
    }

    private func normalizeKeywords() {
        draft.fields.keywords = keywordsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var selectedPreset: MetadataPreset? {
        guard let selectedPresetID else { return nil }
        return store.metadataPresets.first(where: { $0.id == selectedPresetID })
    }

    private func loadSelectedPreset() {
        guard let selectedPreset else { return }
        draft = draft.applying(selectedPreset)
        keywordsText = draft.fields.keywords.joined(separator: ", ")
    }

    private func saveNewPreset() {
        normalizeKeywords()
        let preset = MetadataPreset(name: newPresetName, fields: draft.fields)
        guard store.saveMetadataPreset(preset) else { return }
        selectedPresetID = preset.id
        newPresetName = draft.name
    }

    private func updateSelectedPreset() {
        guard var preset = selectedPreset else { return }
        normalizeKeywords()
        preset.fields = draft.fields
        _ = store.saveMetadataPreset(preset)
    }
}
