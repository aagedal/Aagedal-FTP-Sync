import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MetadataProgrammingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var coordinator = MetadataProgrammingCoordinator()
    @FocusState private var timelineFocused: Bool

    private var calendar: Calendar { coordinator.calendar }
    private var selectedDate: Date {
        get { coordinator.selectedDate }
        nonmutating set { coordinator.selectedDate = newValue }
    }
    private var draft: MetadataAutomation {
        get { coordinator.draft }
        nonmutating set { coordinator.draft = newValue }
    }
    private var selectedPhotographerID: UUID? {
        get { coordinator.selectedPhotographerID }
        nonmutating set { coordinator.selectedPhotographerID = newValue }
    }
    private var editingPhotographerID: UUID? {
        get { coordinator.editingPhotographerID }
        nonmutating set { coordinator.editingPhotographerID = newValue }
    }
    private var draggedPhotographerID: UUID? {
        get { coordinator.draggedPhotographerID }
        nonmutating set { coordinator.draggedPhotographerID = newValue }
    }
    private var editingClipID: UUID? {
        get { coordinator.editingClipID }
        nonmutating set { coordinator.editingClipID = newValue }
    }
    private var photographerPendingDeletion: PhotographerProfile? {
        get { coordinator.photographerPendingDeletion }
        nonmutating set { coordinator.photographerPendingDeletion = newValue }
    }
    private var saveConfirmation: Bool { coordinator.saveConfirmation }
    private var lastSavedDraft: MetadataAutomation? { coordinator.lastSavedDraft }
    private var selectedClipIDs: Set<UUID> {
        get { coordinator.selectedClipIDs }
        nonmutating set { coordinator.selectedClipIDs = newValue }
    }
    private var copiedClips: [MetadataScheduleClip] { coordinator.copiedClips }
    private var playhead: TimelinePlayhead? {
        get { coordinator.playhead }
        nonmutating set { coordinator.playhead = newValue }
    }
    private var snapMinutes: Int { coordinator.snapMinutes }
    private var pendingClipChange: PendingClipChange? {
        get { coordinator.pendingClipChange }
        nonmutating set { coordinator.pendingClipChange = newValue }
    }
    private var pendingReprocessScope: MetadataReprocessScope? {
        get { coordinator.pendingReprocessScope }
        nonmutating set { coordinator.pendingReprocessScope = newValue }
    }
    private var metadataPreview: MetadataPreviewResult? {
        get { coordinator.metadataPreview }
        nonmutating set { coordinator.metadataPreview = newValue }
    }
    private var metadataPreviewFolderName: String { coordinator.metadataPreviewFolderName }
    private var metadataPreviewError: String? {
        get { coordinator.metadataPreviewError }
        nonmutating set { coordinator.metadataPreviewError = newValue }
    }
    private var isPreviewingMetadata: Bool { coordinator.isPreviewingMetadata }

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
        .onChange(of: selectedDate) { _, _ in
            coordinator.clearPlayheadIfOutsideSelectedDay()
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
            isPresented: Binding(
                get: { pendingReprocessScope != nil },
                set: { if !$0 { pendingReprocessScope = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(reprocessActionTitle) {
                coordinator.confirmReprocessing(in: store)
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

            Picker("Schedule time", selection: $coordinator.draft.timestampPolicy) {
                ForEach(MetadataTimestampPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .frame(minWidth: 245, idealWidth: 320, maxWidth: 320)
            .layoutPriority(1)
            .help(draft.timestampPolicy.explanation)

            Picker("Existing fields", selection: $coordinator.draft.existingFieldPolicy) {
                ForEach(MetadataExistingFieldPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .frame(minWidth: 190, idealWidth: 235, maxWidth: 235)
            .layoutPriority(1)
            .help(draft.existingFieldPolicy.explanation)

            Spacer(minLength: 0)

            Toggle("Automatic metadata", isOn: $coordinator.draft.isEnabled)
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
                selection: $coordinator.selectedDate,
                programmedDays: programmedDays,
                calendar: calendar
            )
            .padding(12)

            Spacer(minLength: 12)
            Divider()

            Button {
                RegularWindowController.shared.prepareForOpening()
                openWindow(id: "photographers")
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

                Picker("Snap", selection: $coordinator.snapMinutes) {
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
                                canReprocess: canReprocessMetadata,
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
                                onReprocessPhotographer: {
                                    pendingReprocessScope = .photographer(photographer.id)
                                },
                                onBeginReordering: {
                                    draggedPhotographerID = photographer.id
                                },
                                onSelect: selectClip,
                                onEdit: editClip,
                                onCreate: createClip,
                                onMove: moveClip,
                                onResize: resizeClip,
                                onReprocessClip: { clip in
                                    pendingReprocessScope = .clip(clip.id)
                                },
                                onPlacePlayhead: placePlayhead,
                                onPasteAtPlayhead: pasteClips
                            )
                            .onDrop(
                                of: [UTType.text],
                                delegate: PhotographerTrackDropDelegate(
                                    destinationID: photographer.id,
                                    photographers: $coordinator.draft.photographers,
                                    draggedPhotographerID: $coordinator.draggedPhotographerID
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
                pendingReprocessScope = .all
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
        coordinator.selectedJob(in: store)
    }

    private var canEnableMetadata: Bool {
        coordinator.canEnableMetadata(for: selectedJob)
    }

    private var canAutosaveDraft: Bool {
        coordinator.canAutosaveDraft(in: store)
    }

    private var canReprocessMetadata: Bool {
        coordinator.canReprocessMetadata(in: store)
    }

    private var canPreviewMetadata: Bool {
        coordinator.canPreviewMetadata(for: selectedJob)
    }

    private var previewHelp: String {
        coordinator.previewHelp(for: selectedJob)
    }

    private var isReprocessing: Bool {
        coordinator.isReprocessing(in: store)
    }

    private var reprocessStatusText: String? {
        coordinator.reprocessStatusText(in: store)
    }

    private var reprocessHelp: String {
        coordinator.reprocessHelp
    }

    private var reprocessConfirmationMessage: String {
        coordinator.reprocessConfirmationMessage(for: selectedJob)
    }

    private var reprocessActionTitle: String {
        coordinator.reprocessActionTitle
    }

    private func previewConfiguredLocalFolder() {
        coordinator.previewConfiguredLocalFolder(for: selectedJob)
    }

    private var selectedPhotographer: PhotographerProfile? {
        coordinator.selectedPhotographer
    }

    private var pasteHelp: String {
        coordinator.pasteHelp
    }

    private var timelinePhotographers: [PhotographerProfile] {
        coordinator.timelinePhotographers
    }

    private var programmedDays: Set<Date> {
        coordinator.programmedDays
    }

    private var knownPhotographers: [PhotographerProfile] {
        coordinator.knownPhotographers(in: store)
    }

    private func clips(for photographer: PhotographerProfile) -> [MetadataScheduleClip] {
        coordinator.clips(for: photographer)
    }

    private func processedFileCount(for photographer: PhotographerProfile) -> Int {
        coordinator.processedFileCount(for: photographer, in: store)
    }

    private func photographerBinding(for id: UUID) -> Binding<PhotographerProfile>? {
        guard let index = draft.photographers.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.photographers[index] },
            set: { draft.photographers[index] = $0 }
        )
    }

    private func loadSelectedJob() {
        coordinator.loadSelectedJob(from: store)
    }

    private func scheduleAutosave() {
        coordinator.scheduleAutosave(in: store)
    }

    private func flushAutosave() {
        coordinator.flushAutosave(in: store)
    }

    private func refreshDraftPhotographersFromLibrary() {
        coordinator.refreshDraftPhotographers(from: store)
    }

    private func addPhotographer() {
        coordinator.addPhotographer()
    }

    private func addKnownPhotographer(_ photographer: PhotographerProfile) {
        coordinator.addKnownPhotographer(photographer)
    }

    private func removePhotographer(_ photographer: PhotographerProfile) {
        coordinator.removePhotographer(photographer)
    }

    private func addClip() {
        coordinator.addClip()
    }

    private func updateClip(_ clip: MetadataScheduleClip) {
        coordinator.updateClip(clip)
    }

    private func selectClip(_ clip: MetadataScheduleClip) {
        coordinator.selectClip(
            clip,
            extendingSelection: NSEvent.modifierFlags.contains(.command)
        )
        timelineFocused = true
    }

    private func editSelectedClip() {
        coordinator.editSelectedClip()
    }

    private func editClip(_ clip: MetadataScheduleClip) {
        coordinator.editClip(clip)
    }

    private func createClip(
        for photographer: PhotographerProfile,
        from start: Date,
        to end: Date
    ) {
        coordinator.createClip(for: photographer, from: start, to: end)
        timelineFocused = true
    }

    private func copySelectedClips() {
        coordinator.copySelectedClips()
    }

    private func pasteClips() {
        coordinator.pasteClips()
        timelineFocused = true
    }

    private func pasteClips(to date: Date, on photographerID: UUID) {
        coordinator.pasteClips(to: date, on: photographerID)
        timelineFocused = true
    }

    private func deleteSelectedClips() {
        coordinator.deleteSelectedClips()
    }

    private func selectAllClipsForDay() {
        coordinator.selectAllClipsForDay()
        timelineFocused = true
    }

    private func moveClip(_ clip: MetadataScheduleClip, by interval: TimeInterval, duplicating: Bool) {
        coordinator.moveClip(clip, by: interval, duplicating: duplicating)
    }

    private func placePlayhead(on photographerID: UUID, at date: Date) {
        coordinator.placePlayhead(on: photographerID, at: date)
        timelineFocused = true
    }

    private func resizeClip(
        _ clip: MetadataScheduleClip,
        edge: MetadataClipResizeEdge,
        by interval: TimeInterval
    ) {
        coordinator.resizeClip(clip, edge: edge, by: interval)
    }

    private func applyClipChange(_ clip: MetadataScheduleClip) {
        coordinator.applyClipChange(clip)
    }

    private func selectAdjacentClip(horizontalOffset: Int) {
        coordinator.selectAdjacentClip(horizontalOffset: horizontalOffset)
        timelineFocused = true
    }

    private func selectAdjacentTrack(offset: Int) {
        coordinator.selectAdjacentTrack(offset: offset)
    }

    private func moveDay(by value: Int) {
        coordinator.moveDay(by: value)
    }

    private func color(for photographer: PhotographerProfile) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
        let index = draft.photographers.firstIndex(where: { $0.id == photographer.id }) ?? 0
        return colors[index % colors.count]
    }

    @discardableResult
    private func save() -> Bool {
        coordinator.save(in: store)
    }
}
