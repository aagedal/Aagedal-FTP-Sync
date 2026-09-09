import SwiftUI
import UniformTypeIdentifiers

struct JobDetailEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var session: JobEditingSession
    let onDiscardNewJob: () -> Void
    @State private var showDeleteConfirmation = false
    @State private var showResetConfirmation = false
    @State private var resetPreview: JobResetPreview?
    @State private var isPreparingReset = false
    @State private var saveConfirmation = false
    @State private var showMetadataAudit = false
    @State private var showSyncFailureHistory = false
    @State private var showProcessedFolderPicker = false
    @State private var processedFolderError: String?
    @State private var showCredentialLoadError = false

    private var draft: SyncJob {
        get { session.draft }
        nonmutating set { session.draft = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Job") {
                    TextField("Name", text: $session.draft.name)
                        .accessibilityIdentifier("job-name")
                    Toggle("Two-way sync", isOn: twoWayBinding)
                }

                Section("Automatic syncing") {
                    Toggle("Automatic syncing enabled", isOn: $session.draft.isEnabled)
                        .help("Repeatedly sync this job while the app is open.")
                    LabeledContent("Check every") {
                        HStack {
                            Slider(value: intervalSecondsBinding, in: 5...300)
                                .frame(width: 220)
                            Text(intervalLabel).monospacedDigit().frame(width: 72, alignment: .trailing)
                        }
                    }
                    .disabled(!session.draft.isEnabled)
                    .help("Wait this long after a sync finishes before checking again.")
                    Toggle("Enable automatically on app launch", isOn: startOnAppLaunchBinding)
                        .help("Enable automatic syncing for this job each time the app opens.")
                }

                Section("Display") {
                    Toggle("Show latest sync session count only", isOn: latestSessionTransferCountBinding)
                        .help("A sync session is one scheduled check or a manual Sync Now run.")
                }

                if shouldShowSyncStatus {
                    syncStatusSection
                }

                Section("Locations") {
                    HStack(alignment: .top, spacing: 12) {
                        EndpointSummaryCard(
                            title: draft.direction == .bidirectional ? "Location A" : "Source",
                            endpoint: firstEndpointBinding,
                            password: firstPasswordBinding,
                            serverProfiles: store.serverProfiles
                        )

                        directionControl

                        EndpointSummaryCard(
                            title: destinationLocationTitle,
                            endpoint: secondEndpointBinding,
                            password: secondPasswordBinding,
                            serverProfiles: store.serverProfiles
                        )
                    }
                    .padding(.vertical, 4)
                }

                Section("File filter") {
                    Picker("Quick filter", selection: $session.draft.filter.preset) {
                        ForEach(FilterPreset.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.filter.preset == .custom {
                        TextField("Extensions", text: $session.draft.filter.customExtensions, prompt: Text("jpg, jpeg, cr3, nef"))
                        Text("Separate extensions with commas or spaces.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Photographer initials", text: filenameFilterBinding(\.photographerInitials), prompt: Text("JAD, TA"))
                    Text("Only sync filenames starting with these initials, using the same matching rule as the photographer library. Separate initials with commas; leave blank for all photographers. Matching ignores capitalization.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Ignore filename prefixes", text: filenameFilterBinding(\.excludedFilenamePrefixes), prompt: Text("EDITED_"))
                    TextField("Ignore filename suffixes", text: filenameFilterBinding(\.excludedFilenameSuffixes), prompt: Text("_EDITED, _SENT"))
                    Text("Separate exclusions with commas. Suffixes match before the extension, for example _EDITED excludes TA_001_EDITED.JPG. Exclusions take priority over initials and also apply to local cleanup.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Ignore _aftpsync uploads", isOn: Binding(
                        get: { session.draft.filter.ignoresAFTPSyncUploads },
                        set: { session.draft.filter.ignoresAFTPSyncUploads = $0 }
                    ))
                    Text("Skips files ending in _aftpsync before the extension, including uploads from other app users. Off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Include hidden files", isOn: $session.draft.filter.includeHiddenFiles)
                    Picker("File age", selection: recentHoursBinding) {
                        Text("Any age").tag(0)
                        Text("Last hour").tag(1)
                        Text("Last 3 hours").tag(3)
                        Text("Last 6 hours").tag(6)
                        Text("Last 12 hours").tag(12)
                        Text("Last 24 hours").tag(24)
                        Text("Last 48 hours").tag(48)
                        Text("Last 7 days").tag(168)
                    }
                }

                if draft.supportsUploadNaming || draft.uploadNaming?.isEnabled == true {
                    Section("Upload filenames") {
                        Toggle("Add standard _aftpsync suffix", isOn: uploadStandardSuffixBinding)
                        Text("Adds _aftpsync after any custom suffix and before the extension. Enable “Ignore _aftpsync uploads” on download jobs to exclude marked uploads from all users. Off by default.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Upload prefix", text: uploadNamingBinding(\.prefix), prompt: Text("EDITED_"))
                        TextField("Upload suffix", text: uploadNamingBinding(\.suffix), prompt: Text("_EDITED"))
                        if let example = try? (draft.uploadNaming ?? UploadNaming()).relativePath(for: "TA_001.JPG") {
                            LabeledContent("Example", value: "TA_001.JPG → \(example)")
                        }
                        Text("Adds text to the server copy, with the suffix before the extension. Local filenames stay unchanged. RAW files and their XMP companions receive the same prefix and suffix. Leave both fields blank and the standard suffix off to keep original names.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("When uploading back to the download server, add the same prefix or suffix to the download job’s filename exclusions to prevent return copies from downloading again. Use separate one-way jobs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Metadata") {
                    LabeledContent("Automatic metadata") {
                        Label(
                            metadataStatus,
                            systemImage: currentMetadataAutomation?.isEnabled == true
                                ? "checkmark.circle.fill"
                                : "pause.circle"
                        )
                        .labelStyle(AccessibleStatusLabelStyle(
                            symbolColor: currentMetadataAutomation?.isEnabled == true ? .green : .secondary
                        ))
                    }
                    Button("Open Metadata Programming…") {
                        store.selectedJobID = draft.id
                        RegularWindowController.shared.prepareForOpening(windowID: "metadata-programming")
                        openWindow(id: "metadata-programming")
                    }
                    .accessibilityIdentifier("open-metadata-programming")
                    .disabled(session.isNewJob)
                    .help(session.isNewJob ? "Save this job before programming metadata." : "Open metadata programming for this job.")
                    if session.isNewJob {
                        Text("Save this job first, then open Metadata Programming to add photographers and their schedules. You can choose processed-folder and sorting preferences now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Assign permanent photographer profiles to filename initials, then program Headline, Description, and Keywords on a day timeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Metadata audit trail", isExpanded: $showMetadataAudit) {
                        MetadataAuditTrailView(entries: store.metadataAuditTrail(for: draft.id))
                            .frame(minHeight: 220, idealHeight: 300)
                            .padding(.top, 6)
                    }
                }

                Section("After metadata") {
                    Toggle(
                        "Move successfully tagged source files to a processed folder",
                        isOn: processedFolderEnabledBinding
                    )

                    if draft.movesProcessedFiles {
                        Picker("Processed files location", selection: processedFilesLocationBinding) {
                            ForEach(ProcessedFilesLocation.allCases) { location in
                                Text(location.title).tag(location)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch draft.effectiveProcessedFilesLocation {
                        case .customFolder:
                            LabeledContent("Processed folder") {
                                HStack {
                                    Text(customProcessedFolderPath)
                                        .foregroundStyle(draft.processedFolder?.localPath.isEmpty == false ? .primary : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Button("Choose…") { showProcessedFolderPicker = true }
                                }
                            }
                        case .processedSubfolder:
                            LabeledContent("Main folder") {
                                Text(draft.destinationEndpoint?.localPath.isEmpty == false
                                    ? draft.destinationEndpoint?.localPath ?? "Not selected"
                                    : "Not selected")
                                    .foregroundStyle(draft.destinationEndpoint?.localPath.isEmpty == false ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Downloads: Synced Files", systemImage: "folder")
                                Label("Processed copies: Processed Files", systemImage: "folder")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Toggle(
                            "Sort pictures into per Photographer sub-folders",
                            isOn: sortProcessedFilesByPhotographerBinding
                        )

                        if currentMetadataAutomation?.isEnabled != true {
                            Text("These folder preferences will be saved. Files will sync normally and stay at their source until automatic metadata is configured and enabled. Photographer sorting applies only to successfully tagged files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("After the synced and processed copies are verified, the original is removed from its source. Metadata skips, failures, and processed-file collisions leave the source untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Post-processing") {
                            Text("Keep source files in place").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Safety") {
                    if draft.supportsCaseVariantDownloads {
                        Toggle("Overwrite repeated filenames with different capitalization", isOn: Binding(
                            get: { session.draft.overwritesCaseVariantDownloads },
                            set: { session.draft.overwritesCaseVariantDownloads = $0 }
                        ))
                        Text("Uses the newest server file for names such as PHOTO.JPG and PHOTO.jpg, keeping one local filename. Equal timestamps use a consistent filename order. When off, both files are kept. Existing renamed copies are not removed. RAW/XMP companion conflicts still require manual renaming.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if hasLocalOneWayTarget {
                        Picker("File modification time", selection: $session.draft.preserveModificationDates) {
                            Text("Source modification time").tag(true)
                            Text("Download time").tag(false)
                        }
                        Text("Download time uses the time each file is saved locally, including processed copies, so date-modified sorting follows arrivals. Existing files without saved source history may be downloaded once.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("Preserve modification dates", isOn: $session.draft.preserveModificationDates)
                    }
                    Toggle("Verify file sizes", isOn: $session.draft.verifyFileSizes)
                    Toggle(
                        "Compare contents when size and date match",
                        isOn: matchingContentVerificationBinding
                    )
                    .help("Downloads matching files and compares SHA-256 checksums. This is slower, especially for remote folders.")

                    Toggle("Automatically delete old files from the local target", isOn: targetCleanupBinding)
                        .disabled(draft.targetCleanup == nil && !hasLocalOneWayTarget)

                    if draft.targetCleanup != nil {
                        LabeledContent("Delete target files older than") {
                            HStack {
                                Slider(value: targetCleanupSliderBinding, in: Double(targetCleanupHoursRange.lowerBound)...Double(targetCleanupHoursRange.upperBound))
                                    .frame(width: 220)
                                    .accessibilityLabel("Target cleanup age")
                                TextField("Hours", value: targetCleanupHoursBinding, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 64)
                                    .accessibilityLabel("Target cleanup age in hours")
                                Text("hours")
                            }
                        }
                        Text("\(targetCleanupLabel). Choose \(targetCleanupHoursRange.lowerBound)–\(targetCleanupHoursRange.upperBound) hours.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Cleanup removes only matching file types from the local target and never touches the source. RAW files and their XMP sidecars are removed together. The deletion age must be greater than the source file-age window.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !hasLocalOneWayTarget {
                        Text("Automatic cleanup is available for one-way jobs whose target is a local folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Deletion policy") {
                            Text("Never delete files").foregroundStyle(.secondary)
                        }
                    }

                    Text("Transfers are written to a temporary file first. Two-way sync keeps the newest copy and never deletes files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(session.isNewJob ? "Discard Draft" : "Delete Job", role: .destructive) {
                    showDeleteConfirmation = true
                }
                    .disabled(store.isJobBusy(draft.id))
                    .help(store.isJobBusy(draft.id) ? "Wait for the current job operation to finish." : "Delete this job.")
                Button("Reset Job…", role: .destructive) {
                    Task {
                        isPreparingReset = true
                        defer { isPreparingReset = false }
                        resetPreview = await store.resetPreview(for: draft.id)
                        showResetConfirmation = resetPreview != nil
                    }
                }
                    .disabled(resetUnavailableReason != nil)
                    .help(resetUnavailableReason ?? "Delete downloaded files and clear this job's download history.")
                Spacer()
                if let validationMessage = draft.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                        .lineLimit(3)
                } else if saveConfirmation {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .labelStyle(AccessibleStatusLabelStyle(symbolColor: .green))
                }
                Button("Sync Now") {
                    if save() { store.runNow(draft.id) }
                }
                .disabled(draft.validationMessage != nil || session.credentialLoadError != nil || store.isJobBusy(draft.id))
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.validationMessage != nil || session.credentialLoadError != nil)
                    .accessibilityIdentifier("save-job")
            }
            .padding(14)
        }
        .navigationTitle(draft.name)
        .onAppear {
            session.loadCredentials(using: store)
            if session.credentialLoadError != nil {
                showCredentialLoadError = true
            }
        }
        .fileImporter(
            isPresented: $showProcessedFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let bookmark = try FolderBookmark.create(for: url)
                    draft.processedFolder = Endpoint(
                        kind: .local,
                        localPath: bookmark.resolvedURL.path,
                        bookmark: bookmark.data
                    )
                    draft.processedFilesLocation = .customFolder
                } catch {
                    processedFolderError = "Folder access could not be saved: \(error.localizedDescription)"
                }
            case .failure(let error):
                processedFolderError = "The processed folder could not be selected: \(error.localizedDescription)"
            }
        }
        .alert("Processed Folder", isPresented: Binding(
            get: { processedFolderError != nil },
            set: { if !$0 { processedFolderError = nil } }
        )) {
            Button("OK") { processedFolderError = nil }
        } message: {
            Text(processedFolderError ?? "")
        }
        .alert("Saved Passwords", isPresented: $showCredentialLoadError) {
            Button("OK") {}
        } message: {
            Text(session.credentialLoadError ?? "")
        }
        .confirmationDialog(
            session.isNewJob ? "Discard “\(draft.name)”?" : "Delete “\(draft.name)”?",
            isPresented: $showDeleteConfirmation
        ) {
            Button(session.isNewJob ? "Discard Draft" : "Delete Job", role: .destructive) {
                if session.isNewJob {
                    session.markDiscarded()
                    onDiscardNewJob()
                } else {
                    store.removeJob(draft.id)
                }
            }
        } message: {
            Text(session.isNewJob
                ? "This job has not been saved, so no stored jobs or credentials will be changed."
                : "Files are not deleted, but this job and its saved credentials will be removed.")
        }
        .confirmationDialog("Reset “\(draft.name)”?", isPresented: $showResetConfirmation) {
            Button("Delete Downloads and Reset", role: .destructive) {
                draft.isEnabled = false
                draft.startsOnAppLaunch = false
                store.resetJob(draft.id)
                resetPreview = nil
            }
        } message: {
            Text(resetConfirmationMessage)
        }
    }

    private var matchingContentVerificationBinding: Binding<Bool> {
        Binding(
            get: { draft.verifiesMatchingFileContents },
            set: { draft.verifiesMatchingFileContents = $0 }
        )
    }

    @ViewBuilder
    private var syncStatusSection: some View {
        Section("Sync status") {
            if case .failed(let message, let retryAt) = currentPhase {
                Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(AccessibleStatusLabelStyle(symbolColor: .red))
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let retryAt {
                    Label(
                        "Automatic retry \(retryAt.formatted(date: .omitted, time: .shortened))",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let suggestion = recoverySuggestion(for: message) {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Retry Now", systemImage: "arrow.clockwise") {
                        if save() { store.runNow(draft.id) }
                    }
                    .disabled(store.isJobBusy(draft.id))
                    Button("Copy Error", systemImage: "doc.on.doc") {
                        copyToPasteboard(message)
                    }
                }
            } else if case .syncing = currentPhase {
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
            } else if !syncFailureHistory.isEmpty {
                if case .succeeded = currentPhase {
                    Label("The latest sync completed.", systemImage: "checkmark.circle.fill")
                        .labelStyle(AccessibleStatusLabelStyle(symbolColor: .green))
                } else {
                    Label("Previous sync errors are available below.", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
            }

            if !syncFailureHistory.isEmpty {
                DisclosureGroup(
                    "Recent error log (\(syncFailureHistory.count))",
                    isExpanded: $showSyncFailureHistory
                ) {
                    ScrollView {
                        // Keep selectable error text out of lazy view recycling to avoid
                        // vertically flipped messages after repeated history updates.
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(syncFailureHistory) { failure in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(failure.occurredAt.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(failure.message)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if failure.id != syncFailureHistory.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(minHeight: 90, idealHeight: 180, maxHeight: 240)

                    HStack {
                        Button("Copy Latest Error") {
                            if let message = syncFailureHistory.first?.message {
                                copyToPasteboard(message)
                            }
                        }
                        Spacer()
                        Button("Clear Error Log", role: .destructive) {
                            store.clearSyncFailureHistory(for: draft.id)
                        }
                    }
                }
            }
        }
    }

    private var currentPhase: JobPhase {
        store.phases[draft.id] ?? .stopped
    }

    private var syncFailureHistory: [SyncFailureRecord] {
        store.syncFailureHistory(for: draft.id)
    }

    private var shouldShowSyncStatus: Bool {
        if case .failed = currentPhase { return true }
        if case .syncing = currentPhase { return true }
        return !syncFailureHistory.isEmpty
    }

    private func recoverySuggestion(for message: String) -> String? {
        let lowercased = message.lowercased()
        if lowercased.contains("timed out connecting") {
            return "Check this Mac’s network or VPN and whether the server is reachable. No download or sub-folder sorting had started when this connection failed."
        }
        if lowercased.contains("processed folder already contains") {
            return "A different file is already using the intended processed path. The app will automatically finish recovery when an existing processed copy is byte-for-byte identical; otherwise it leaves both files untouched for review."
        }
        if lowercased.contains("password") || lowercased.contains("authentication") || lowercased.contains("login") {
            return "Check the saved username and password, then retry the job."
        }
        if lowercased.contains("permission") || lowercased.contains("access") {
            return "Review the source and destination permissions, then retry the job."
        }
        return nil
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // A stepped macOS slider draws a tick for every second, which looks like
    // an extra line at this range. Round the value without drawing tick marks.
    private var intervalSecondsBinding: Binding<Double> {
        Binding(
            get: { session.draft.intervalSeconds },
            set: { session.draft.intervalSeconds = $0.rounded() }
        )
    }

    private var intervalLabel: String {
        if draft.intervalSeconds < 60 { return "\(Int(draft.intervalSeconds)) sec" }
        return "\(Int(draft.intervalSeconds / 60)) min"
    }

    private var destinationLocationTitle: String {
        if draft.direction == .bidirectional { return "Location B" }
        return draft.usesManagedFolderStructure ? "Main Folder" : "Destination"
    }

    private var customProcessedFolderPath: String {
        guard let path = draft.processedFolder?.localPath, !path.isEmpty else { return "Not selected" }
        return path
    }

    private var savedJob: SyncJob? {
        store.jobs.first { $0.id == draft.id }
    }

    private var resetUnavailableReason: String? {
        guard let savedJob else { return "Save this job before resetting it." }
        guard draft == savedJob else { return "Save or discard the current changes before resetting this job." }
        if isPreparingReset { return "Preparing the reset preview." }
        if store.isJobBusy(draft.id) { return "Wait for the current job operation to finish." }
        return JobResetService.validationMessage(for: savedJob)
    }

    private var resetConfirmationMessage: String {
        guard let savedJob else { return "This job has not been saved." }
        let path = resetPreview?.downloadFolderPath
            ?? savedJob.localDestinationDisplayPath
            ?? "the local download folder"
        let fileCount = resetPreview?.filesToDelete ?? 0
        let fileDescription = fileCount == 1 ? "1 file" : "\(fileCount) files"
        let folderWarning: String
        if resetPreview?.deletesWholeManagedFolder == true {
            folderWarning = "Reset will permanently delete \(fileDescription) currently inside \(path). Processed Files and the source will not be changed."
        } else {
            folderWarning = "Reset will permanently delete \(fileDescription) recorded as downloads created by this job in \(path). Other files and the source will not be changed."
        }
        return "\(folderWarning) Transfer counts, metadata audit entries, error history, and saved source signatures will also be cleared. The job will be stopped and disabled at login. This cannot be undone."
    }

    private func filenameFilterBinding(_ keyPath: WritableKeyPath<FileFilter, String?>) -> Binding<String> {
        Binding(
            get: { session.draft.filter[keyPath: keyPath] ?? "" },
            set: { session.draft.filter[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func uploadNamingBinding(_ keyPath: WritableKeyPath<UploadNaming, String>) -> Binding<String> {
        Binding(
            get: { (session.draft.uploadNaming ?? UploadNaming())[keyPath: keyPath] },
            set: {
                var naming = session.draft.uploadNaming ?? UploadNaming()
                naming[keyPath: keyPath] = $0
                session.draft.uploadNaming = naming.isEnabled ? naming : nil
            }
        )
    }

    private var uploadStandardSuffixBinding: Binding<Bool> {
        Binding(
            get: { session.draft.uploadNaming?.addsStandardSuffix ?? false },
            set: {
                var naming = session.draft.uploadNaming ?? UploadNaming()
                naming.addsStandardSuffix = $0
                session.draft.uploadNaming = naming.isEnabled ? naming : nil
            }
        )
    }

    private var metadataStatus: String {
        guard let metadata = currentMetadataAutomation else { return "Not configured" }
        let profiles = metadata.photographers.count == 1
            ? "1 photographer"
            : "\(metadata.photographers.count) photographers"
        return metadata.isEnabled ? "On · \(profiles)" : "Off · \(profiles)"
    }

    private var currentMetadataAutomation: MetadataAutomation? {
        store.jobs.first(where: { $0.id == draft.id })?.metadataAutomation
    }

    private var recentHoursBinding: Binding<Int> {
        Binding(
            get: { draft.filter.recentHours ?? 0 },
            set: { value in
                draft.filter.recentHours = value == 0 ? nil : value
                if value > 0, let cleanup = draft.targetCleanup, cleanup.olderThanHours <= value {
                    draft.targetCleanup?.olderThanHours = value + 1
                }
            }
        )
    }

    private var startOnAppLaunchBinding: Binding<Bool> {
        Binding(
            get: { draft.startsOnAppLaunch },
            set: { draft.startsOnAppLaunch = $0 }
        )
    }

    private var latestSessionTransferCountBinding: Binding<Bool> {
        Binding(
            get: { draft.showsLatestSessionTransferCountOnly },
            set: { draft.showsLatestSessionTransferCountOnly = $0 }
        )
    }

    private var processedFolderEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.movesProcessedFiles },
            set: { enabled in
                if enabled {
                    if !draft.movesProcessedFiles {
                        draft.processedFilesLocation = .processedSubfolder
                    }
                } else {
                    draft.processedFolder = nil
                    draft.processedFilesLocation = nil
                    draft.sortsProcessedFilesByPhotographer = false
                }
            }
        )
    }

    private var processedFilesLocationBinding: Binding<ProcessedFilesLocation> {
        Binding(
            get: { draft.effectiveProcessedFilesLocation },
            set: { location in
                draft.processedFilesLocation = location
                if location == .customFolder, draft.processedFolder == nil {
                    draft.processedFolder = .local
                    showProcessedFolderPicker = true
                }
            }
        )
    }

    private var sortProcessedFilesByPhotographerBinding: Binding<Bool> {
        Binding(
            get: { draft.sortsProcessedFilesByPhotographer },
            set: { draft.sortsProcessedFilesByPhotographer = $0 }
        )
    }

    @ViewBuilder
    private var directionControl: some View {
        VStack {
            Spacer()
            if draft.direction == .bidirectional {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Two-way sync")
            } else {
                Button(action: swapSourceAndDestination) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap Source and Destination")
                .accessibilityLabel("Swap Source and Destination")
                .accessibilityHint("Exchanges the source and destination endpoints")
            }
            Spacer()
        }
        .font(.title3)
        .frame(width: 28)
        .frame(minHeight: 132)
    }

    private var twoWayBinding: Binding<Bool> {
        Binding(
            get: { draft.direction == .bidirectional },
            set: { enabled in
                if enabled, draft.direction == .rightToLeft {
                    let source = draft.right
                    draft.right = draft.left
                    draft.left = source

                    let sourcePassword = session.rightPassword
                    session.rightPassword = session.leftPassword
                    session.leftPassword = sourcePassword
                }
                draft.direction = enabled ? .bidirectional : .leftToRight
            }
        )
    }

    private var firstEndpointBinding: Binding<Endpoint> {
        Binding(
            get: { draft.direction == .rightToLeft ? draft.right : draft.left },
            set: {
                if draft.direction == .rightToLeft { draft.right = $0 }
                else { draft.left = $0 }
            }
        )
    }

    private var secondEndpointBinding: Binding<Endpoint> {
        Binding(
            get: { draft.direction == .rightToLeft ? draft.left : draft.right },
            set: {
                if draft.direction == .rightToLeft { draft.left = $0 }
                else { draft.right = $0 }
            }
        )
    }

    private var firstPasswordBinding: Binding<String> {
        Binding(
            get: { draft.direction == .rightToLeft ? session.rightPassword : session.leftPassword },
            set: {
                if draft.direction == .rightToLeft { session.rightPassword = $0 }
                else { session.leftPassword = $0 }
            }
        )
    }

    private var secondPasswordBinding: Binding<String> {
        Binding(
            get: { draft.direction == .rightToLeft ? session.leftPassword : session.rightPassword },
            set: {
                if draft.direction == .rightToLeft { session.leftPassword = $0 }
                else { session.rightPassword = $0 }
            }
        )
    }

    private func swapSourceAndDestination() {
        draft.direction = draft.direction == .rightToLeft ? .leftToRight : .rightToLeft
    }

    private var hasLocalOneWayTarget: Bool {
        guard draft.direction != .bidirectional else { return false }
        let target = draft.direction == .leftToRight ? draft.right : draft.left
        return target.kind == .local
    }

    private var targetCleanupBinding: Binding<Bool> {
        Binding(
            get: { draft.targetCleanup != nil },
            set: { enabled in
                if enabled {
                    let sourceHours = draft.filter.recentHours ?? 1
                    draft.filter.recentHours = sourceHours
                    draft.targetCleanup = TargetCleanup(olderThanHours: sourceHours + 1)
                } else {
                    draft.targetCleanup = nil
                }
            }
        )
    }

    private var targetCleanupHoursBinding: Binding<Int> {
        Binding(
            get: { draft.targetCleanup?.olderThanHours ?? 2 },
            set: { draft.targetCleanup?.olderThanHours = min(max($0, targetCleanupHoursRange.lowerBound), targetCleanupHoursRange.upperBound) }
        )
    }

    private var targetCleanupHoursRange: ClosedRange<Int> {
        let minimum = max(1, (draft.filter.recentHours ?? 0) + 1)
        return minimum...max(720, minimum + 1)
    }

    private var targetCleanupSliderBinding: Binding<Double> {
        Binding(
            get: { Double(targetCleanupHoursBinding.wrappedValue) },
            set: { targetCleanupHoursBinding.wrappedValue = Int($0.rounded()) }
        )
    }

    private var targetCleanupLabel: String {
        let hours = draft.targetCleanup?.olderThanHours ?? 2
        if hours == 1 { return "1 hour" }
        if hours.isMultiple(of: 24) {
            let days = hours / 24
            return days == 1 ? "1 day" : "\(days) days"
        }
        return "\(hours) hours"
    }

    @discardableResult
    private func save() -> Bool {
        guard session.save(using: store) else {
            saveConfirmation = false
            return false
        }
        saveConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saveConfirmation = false
        }
        return true
    }
}
