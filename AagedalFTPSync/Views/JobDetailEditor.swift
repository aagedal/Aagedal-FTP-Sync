import SwiftUI
import UniformTypeIdentifiers

struct JobDetailEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var draft: SyncJob
    @State private var leftPassword = ""
    @State private var rightPassword = ""
    @State private var showDeleteConfirmation = false
    @State private var saveConfirmation = false
    @State private var showMetadataAudit = false
    @State private var showSyncFailureHistory = false
    @State private var showProcessedFolderPicker = false
    @State private var processedFolderError: String?

    init(job: SyncJob) {
        _draft = State(initialValue: job)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Job") {
                    TextField("Name", text: $draft.name)
                    Toggle("Two-way sync", isOn: twoWayBinding)
                    Toggle("Run automatically", isOn: $draft.isEnabled)
                    Toggle("Start this job when the app launches", isOn: startOnAppLaunchBinding)
                    Toggle("Show latest sync session count only", isOn: latestSessionTransferCountBinding)
                        .help("A sync session is one scheduled check or a manual Sync Now run.")
                    LabeledContent("Check every") {
                        HStack {
                            Slider(value: $draft.intervalSeconds, in: 2...300, step: 1)
                                .frame(width: 220)
                            Text(intervalLabel).monospacedDigit().frame(width: 72, alignment: .trailing)
                        }
                    }
                }

                if shouldShowSyncStatus {
                    syncStatusSection
                }

                Section("Locations") {
                    HStack(alignment: .top, spacing: 12) {
                        EndpointSummaryCard(
                            title: draft.direction == .bidirectional ? "Location A" : "Source",
                            endpoint: firstEndpointBinding,
                            password: firstPasswordBinding
                        )

                        directionControl

                        EndpointSummaryCard(
                            title: destinationLocationTitle,
                            endpoint: secondEndpointBinding,
                            password: secondPasswordBinding
                        )
                    }
                    .padding(.vertical, 4)
                }

                Section("File filter") {
                    Picker("Quick filter", selection: $draft.filter.preset) {
                        ForEach(FilterPreset.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.filter.preset == .custom {
                        TextField("Extensions", text: $draft.filter.customExtensions, prompt: Text("jpg, jpeg, cr3, nef"))
                        Text("Separate extensions with commas or spaces.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Include hidden files", isOn: $draft.filter.includeHiddenFiles)
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

                Section("Metadata") {
                    LabeledContent("Automatic metadata") {
                        Text(metadataStatus)
                            .foregroundStyle(currentMetadataAutomation?.isEnabled == true ? .green : .secondary)
                    }
                    Button("Open Metadata Programming…") {
                        store.selectedJobID = draft.id
                        RegularWindowController.shared.prepareForOpening()
                        openWindow(id: "metadata-programming")
                        NSApplication.shared.activate(ignoringOtherApps: true)
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
                    Toggle("Preserve modification dates", isOn: $draft.preserveModificationDates)
                    Toggle("Verify file sizes", isOn: $draft.verifyFileSizes)

                    Toggle("Automatically delete old files from the local target", isOn: targetCleanupBinding)
                        .disabled(draft.targetCleanup == nil && !hasLocalOneWayTarget)

                    if draft.targetCleanup != nil {
                        Stepper(value: targetCleanupHoursBinding, in: 1...720) {
                            LabeledContent("Delete target files older than") {
                                Text(targetCleanupLabel).monospacedDigit()
                            }
                        }
                        Text("Cleanup removes only matching file types from the local target and never touches the source. The deletion age must be greater than the source file-age window.")
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
                Button("Delete Job", role: .destructive) { showDeleteConfirmation = true }
                Spacer()
                if let validationMessage = draft.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if saveConfirmation {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("Sync Now") {
                    if save() { store.runNow(draft.id) }
                }
                .disabled(draft.validationMessage != nil || store.isJobBusy(draft.id))
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.validationMessage != nil)
            }
            .padding(14)
        }
        .navigationTitle(draft.name)
        .onAppear {
            leftPassword = store.password(for: draft.left)
            rightPassword = store.password(for: draft.right)
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
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $showDeleteConfirmation) {
            Button("Delete Job", role: .destructive) { store.removeJob(draft.id) }
        } message: {
            Text("Files are not deleted, but this job and its saved credentials will be removed.")
        }
    }

    @ViewBuilder
    private var syncStatusSection: some View {
        Section("Sync status") {
            if case .failed(let message, let retryAt) = currentPhase {
                Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
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
                        .foregroundStyle(.green)
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
                        LazyVStack(alignment: .leading, spacing: 10) {
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
                        draft.processedFilesLocation = .customFolder
                        draft.processedFolder = .local
                        showProcessedFolderPicker = true
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

                    let sourcePassword = rightPassword
                    rightPassword = leftPassword
                    leftPassword = sourcePassword
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
            get: { draft.direction == .rightToLeft ? rightPassword : leftPassword },
            set: {
                if draft.direction == .rightToLeft { rightPassword = $0 }
                else { leftPassword = $0 }
            }
        )
    }

    private var secondPasswordBinding: Binding<String> {
        Binding(
            get: { draft.direction == .rightToLeft ? leftPassword : rightPassword },
            set: {
                if draft.direction == .rightToLeft { leftPassword = $0 }
                else { rightPassword = $0 }
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
            set: { draft.targetCleanup?.olderThanHours = $0 }
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
        // Metadata is edited in its own window. Merge the latest persisted programming
        // so an older job-settings draft cannot overwrite it.
        draft.metadataAutomation = store.jobs.first(where: { $0.id == draft.id })?.metadataAutomation
        guard store.saveJob(draft, leftPassword: leftPassword, rightPassword: rightPassword) else {
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

private struct EndpointSummaryCard: View {
    let title: String
    @Binding var endpoint: Endpoint
    @Binding var password: String
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Edit Settings…", systemImage: "gearshape") {
                        showSettings = true
                    }
                    Divider()
                    Menu("Connection Type") {
                        ForEach(EndpointKind.allCases) { kind in
                            Button {
                                setKind(kind)
                            } label: {
                                if kind == endpoint.kind {
                                    Label(kind.title, systemImage: "checkmark")
                                } else {
                                    Text(kind.title)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("\(title) settings")
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: endpoint.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(endpoint.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(endpoint.cardLocation)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            if endpoint.validationMessage == nil {
                Label("Configured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Needs setup", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .sheet(isPresented: $showSettings) {
            EndpointSettingsSheet(
                title: title,
                endpoint: $endpoint,
                password: $password
            )
        }
    }

    private func setKind(_ kind: EndpointKind) {
        guard kind != endpoint.kind else { return }
        endpoint.kind = kind
        if kind.isRemote { endpoint.port = kind.defaultPort }
    }
}

private struct EndpointSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var endpoint: Endpoint
    @Binding var password: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: endpoint.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(title) Settings")
                        .font(.headline)
                    Text(endpoint.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            Form {
                Section("Connection") {
                    EndpointEditor(endpoint: $endpoint, password: $password)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: endpoint.kind == .local ? 300 : 500)
    }
}

private extension EndpointKind {
    var systemImage: String {
        switch self {
        case .local: "folder.fill"
        case .ftp: "network"
        case .ftps: "lock.shield.fill"
        case .sftp: "terminal.fill"
        }
    }
}

private extension Endpoint {
    var cardLocation: String {
        if kind == .local {
            return localPath.isEmpty ? "Choose a folder" : localPath
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return "Enter a server address" }
        let portSuffix = port == kind.defaultPort ? "" : ":\(port)"
        let path = remotePath.isEmpty ? "/" : remotePath
        return "\(kind.rawValue)://\(trimmedHost)\(portSuffix)\(path)"
    }
}

private struct EndpointEditor: View {
    @Binding var endpoint: Endpoint
    @Binding var password: String
    @State private var showFolderPicker = false
    @State private var folderError: String?
    @State private var connectionTestState = ConnectionTestState.idle
    @State private var connectionTestTask: Task<Void, Never>?

    var body: some View {
        Group {
            Picker("Type", selection: $endpoint.kind) {
                ForEach(EndpointKind.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: endpoint.kind) { oldKind, newKind in
                if oldKind != newKind, newKind.isRemote { endpoint.port = newKind.defaultPort }
            }

            if endpoint.kind == .local {
                LabeledContent("Folder") {
                    HStack {
                        Text(endpoint.localPath.isEmpty ? "Not selected" : endpoint.localPath)
                            .foregroundStyle(endpoint.localPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { showFolderPicker = true }
                    }
                }
            } else {
                TextField("Server", text: $endpoint.host, prompt: Text("photos.example.com"))
                    .textContentType(.URL)
                TextField("Port", value: $endpoint.port, format: .number)
                    .frame(maxWidth: 180)
                TextField("Username", text: $endpoint.username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                TextField("Remote folder", text: $endpoint.remotePath, prompt: Text("/incoming"))
                connectionTestControls
                if endpoint.kind == .ftp {
                    Label("FTP sends credentials and files without encryption. Prefer SFTP or FTPS.", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.orange)
                } else if endpoint.kind == .ftps {
                    Text("FTPS uses implicit TLS (normally port 990) and validates the server certificate.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField(
                        "Host key fingerprint",
                        text: $endpoint.hostKeyFingerprint,
                        prompt: Text("SHA256:…")
                    )
                    .textContentType(.none)
                    Text("Test the connection to discover the fingerprint, verify it with the server administrator, then trust it. SFTP stays blocked until the fingerprint is saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let bookmark = try FolderBookmark.create(for: url)
                    endpoint.localPath = bookmark.resolvedURL.path
                    endpoint.bookmark = bookmark.data
                } catch {
                    folderError = "Folder access could not be saved: \(error.localizedDescription)"
                }
            case .failure(let error):
                folderError = "The folder could not be selected: \(error.localizedDescription)"
            }
        }
        .alert("Folder Access", isPresented: Binding(
            get: { folderError != nil },
            set: { if !$0 { folderError = nil } }
        )) {
            Button("OK") { folderError = nil }
        } message: {
            Text(folderError ?? "")
        }
        .onChange(of: endpoint) { _, _ in resetConnectionTest() }
        .onChange(of: password) { _, _ in resetConnectionTest() }
        .onDisappear { connectionTestTask?.cancel() }
    }

    @ViewBuilder
    private var connectionTestControls: some View {
        HStack {
            Button(action: testConnection) {
                if connectionTestState == .testing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                    }
                } else {
                    Label("Test Connection", systemImage: "network")
                }
            }
            .disabled(endpoint.connectionValidationMessage != nil || connectionTestState == .testing)

            if connectionTestState == .succeeded {
                Label("Connection successful", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }

        if case .failed(let message) = connectionTestState {
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .textSelection(.enabled)
        }

        if case .awaitingHostKey(let hostID, let fingerprint) = connectionTestState {
            VStack(alignment: .leading, spacing: 6) {
                Label("Verify the SSH host key for \(hostID) before continuing.", systemImage: "key.horizontal")
                    .foregroundStyle(.orange)
                Text(fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Trust Verified Fingerprint") {
                    endpoint.hostKeyFingerprint = fingerprint
                }
                .controlSize(.small)
                .help("Only trust this fingerprint after comparing it with a value supplied independently by the server administrator.")
            }
            .font(.caption)
        }
    }

    private func testConnection() {
        connectionTestTask?.cancel()
        connectionTestState = .testing
        let candidate = endpoint
        let candidatePassword = password
        connectionTestTask = Task {
            do {
                try await EndpointConnectionTester.test(endpoint: candidate, password: candidatePassword)
                try Task.checkCancellation()
                connectionTestState = .succeeded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if case let AppError.untrustedSSHHostKey(hostID, fingerprint) = error {
                    connectionTestState = .awaitingHostKey(hostID: hostID, fingerprint: fingerprint)
                } else {
                    connectionTestState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func resetConnectionTest() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        connectionTestState = .idle
    }
}

private enum ConnectionTestState: Equatable {
    case idle
    case testing
    case succeeded
    case awaitingHostKey(hostID: String, fingerprint: String)
    case failed(String)
}
