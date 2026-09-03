import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MetadataProgrammingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var coordinator = MetadataProgrammingCoordinator()
    @FocusState private var timelineFocused: Bool
    @State private var pendingConfigurationTransfer: PendingConfigurationTransfer?
    @State private var showConfigurationImporter = false
    @State private var metadataImportTargetJobID: UUID?
    @State private var importSummary: String?
    @State private var selectedExportDays: Set<Date> = []
    @State private var showConfigurationExporter = false
    @State private var exportDocument = ConfigurationTransferFile()
    @State private var exportFilename = ConfigurationTransferScope.metadata.defaultFilename

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
        alertContent
    }

    private var mainContent: some View {
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
    }

    private var sheetContent: some View {
        mainContent
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
        .sheet(item: $pendingConfigurationTransfer) { transfer in
            ConfigurationTransferOptionsView(
                operation: transfer.operation,
                onExport: prepareMetadataExport,
                onImport: importMetadataProgramming
            )
        }
        .fileImporter(
            isPresented: $showConfigurationImporter,
            allowedContentTypes: [.aagedalFTPSyncConfiguration],
            allowsMultipleSelection: false,
            onCompletion: loadMetadataPackage
        )
        .fileExporter(
            isPresented: $showConfigurationExporter,
            document: exportDocument,
            contentType: .aagedalFTPSyncConfiguration,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                store.alertMessage = "The metadata programming could not be exported: \(error.localizedDescription)"
            }
        }
    }

    private var dialogContent: some View {
        sheetContent
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
    }

    private var alertContent: some View {
        dialogContent
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
        .alert("Aagedal FTP Sync", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .alert("Metadata Imported", isPresented: Binding(
            get: { importSummary != nil },
            set: { if !$0 { importSummary = nil } }
        )) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(importSummary ?? "")
        }
    }

    private var windowHeader: some View {
        HStack(spacing: 14) {
            Label("Metadata Programming", systemImage: "tag.fill")
                .font(.title2.weight(.semibold))
                .fixedSize()

            Picker(selection: $coordinator.draft.timestampPolicy) {
                ForEach(MetadataTimestampPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            } label: {
                Image(systemName: "clock")
                    .accessibilityLabel("Schedule Time")
            }
            .frame(minWidth: 245, idealWidth: 320, maxWidth: 320)
            .layoutPriority(1)
            .help("Schedule Time: \(draft.timestampPolicy.explanation)")

            Picker(selection: $coordinator.draft.existingFieldPolicy) {
                ForEach(MetadataExistingFieldPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            } label: {
                Image(systemName: "text.badge.checkmark")
                    .accessibilityLabel("Existing Fields")
            }
            .frame(minWidth: 190, idealWidth: 235, maxWidth: 235)
            .layoutPriority(1)
            .help("Existing Fields: \(draft.existingFieldPolicy.explanation)")

            Spacer(minLength: 0)

            Button(action: openPhotographerMap) {
                Label("Map", systemImage: "map")
            }
            .disabled(selectedJob == nil)
            .help("Show scheduled photographer locations on a map")

            Button {
                if let selectedJob {
                    beginMetadataImport(for: selectedJob)
                }
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("import-metadata-programming")
            .disabled(selectedJob == nil)
            .help("Import metadata programming into the selected sync job")

            Toggle("Activate", isOn: $coordinator.draft.isEnabled)
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
                calendar: calendar,
                canPasteProgramming: coordinator.copiedDayProgramming != nil,
                onCopyProgramming: coordinator.copyAllProgramming,
                onPasteProgramming: coordinator.pasteDayProgramming,
                onExport: beginMetadataExport
            )
            .padding(12)

            Divider()

            List(selection: selectedJobBinding) {
                Section("Sync Jobs") {
                    ForEach(store.jobs) { job in
                        metadataJobRow(for: job)
                            .tag(job.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(spacing: 0) {
                Button {
                    openJobSettings()
                } label: {
                    Label("Manage Sync Jobs…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
                .help("Open sync job settings in a separate window")

                Divider()

                Button {
                    RegularWindowController.shared.prepareForOpening(windowID: "photographers")
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
    }

    private func metadataJobRow(for job: SyncJob) -> some View {
        let automation = job.id == coordinator.loadedJobID
            ? draft
            : job.metadataAutomation ?? MetadataAutomation()

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: job.direction.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(job.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            Text(metadataJobSummary(for: automation))
                .font(.caption)
                .foregroundStyle(automation.isEnabled ? Color.green : Color.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .help("Program metadata for \(job.name)")
        .contextMenu {
            Button {
                beginMetadataImport(for: job)
            } label: {
                Label("Import Metadata Programming…", systemImage: "square.and.arrow.down")
            }

            Divider()

            Button {
                openJobSettings(for: job)
            } label: {
                Label("Job Settings…", systemImage: "gearshape")
            }
        }
    }

    private func openJobSettings(for job: SyncJob? = nil) {
        if let job {
            store.selectedJobID = job.id
        }
        RegularWindowController.shared.prepareForOpening(windowID: "jobs")
        openWindow(id: "jobs")
    }

    private func openPhotographerMap() {
        flushAutosave()
        store.metadataMapRequestedDate = playhead?.date ?? selectedDate
        RegularWindowController.shared.prepareForOpening(windowID: "photographer-map")
        openWindow(id: "photographer-map")
    }

    private func metadataJobSummary(for automation: MetadataAutomation) -> String {
        let status = automation.isEnabled ? "Active" : "Inactive"
        let photographerCount = automation.photographers.count
        let clipCount = automation.clips.count
        let photographers = photographerCount == 1
            ? "1 photographer"
            : "\(photographerCount) photographers"
        let clips = clipCount == 1 ? "1 clip" : "\(clipCount) clips"
        return "\(status) · \(photographers) · \(clips)"
    }

    private func beginMetadataExport(for days: Set<Date>) {
        selectedExportDays = days
        pendingConfigurationTransfer = PendingConfigurationTransfer(operation: .export(.metadata))
    }

    private func beginMetadataImport(for job: SyncJob) {
        flushAutosave()
        store.selectedJobID = job.id
        metadataImportTargetJobID = job.id
        showConfigurationImporter = true
    }

    private func loadMetadataPackage(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= ConfigurationTransferCodec.maximumFileSize else {
                throw ConfigurationTransferError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let protection = try ConfigurationTransferCodec.protection(of: data)
            pendingConfigurationTransfer = PendingConfigurationTransfer(
                operation: .importPackage(data, protection)
            )
        } catch {
            store.alertMessage = "The metadata programming could not be opened: \(error.localizedDescription)"
        }
    }

    private func importMetadataProgramming(_ data: Data, _ password: String?) -> Bool {
        guard let metadataImportTargetJobID,
              let result = store.importConfiguration(
                  from: data,
                  password: password,
                  expectedScope: .metadata,
                  metadataTargetJobID: metadataImportTargetJobID
              ) else {
            return false
        }
        loadSelectedJob()
        importSummary = result.summary
        self.metadataImportTargetJobID = nil
        return true
    }

    private func prepareMetadataExport(
        _ scope: ConfigurationTransferScope,
        _ password: String?
    ) -> Bool {
        guard scope == .metadata,
              let selectedJob,
              let data = store.metadataProgrammingExportData(
                  for: selectedJob,
                  automation: draft,
                  on: selectedExportDays,
                  calendar: calendar,
                  password: password
              ) else {
            return false
        }
        exportDocument = ConfigurationTransferFile(data: data)
        exportFilename = metadataExportFilename(for: selectedExportDays)
        DispatchQueue.main.async { showConfigurationExporter = true }
        return true
    }

    private func metadataExportFilename(for days: Set<Date>) -> String {
        let sortedDays = days.sorted()
        guard let first = sortedDays.first else {
            return ConfigurationTransferScope.metadata.defaultFilename
        }
        let firstStamp = metadataExportDateStamp(first)
        guard let last = sortedDays.last, last != first else {
            return "Aagedal Metadata Programming \(firstStamp)"
        }
        return "Aagedal Metadata Programming \(firstStamp) to \(metadataExportDateStamp(last))"
    }

    private func metadataExportDateStamp(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
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
