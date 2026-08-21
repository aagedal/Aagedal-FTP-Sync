import SwiftUI
import UniformTypeIdentifiers

struct JobDetailEditor: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft: SyncJob
    @State private var leftPassword = ""
    @State private var rightPassword = ""
    @State private var showDeleteConfirmation = false
    @State private var saveConfirmation = false

    init(job: SyncJob) {
        _draft = State(initialValue: job)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Job") {
                    TextField("Name", text: $draft.name)
                    Picker("Direction", selection: $draft.direction) {
                        ForEach(SyncDirection.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Run automatically", isOn: $draft.isEnabled)
                    LabeledContent("Check every") {
                        HStack {
                            Slider(value: $draft.intervalSeconds, in: 2...300, step: 1)
                                .frame(width: 220)
                            Text(intervalLabel).monospacedDigit().frame(width: 72, alignment: .trailing)
                        }
                    }
                }

                Section("Left side") {
                    EndpointEditor(endpoint: $draft.left, password: $leftPassword)
                }

                Section("Right side") {
                    EndpointEditor(endpoint: $draft.right, password: $rightPassword)
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
                        Text("Last 6 hours").tag(6)
                        Text("Last 12 hours").tag(12)
                        Text("Last 24 hours").tag(24)
                        Text("Last 48 hours").tag(48)
                        Text("Last 7 days").tag(168)
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
                        Text("Only matching file types in the local target are removed. The source is never touched. The deletion age must be greater than the source file-age window.")
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
                    save()
                    store.runNow(draft.id)
                }
                .disabled(draft.validationMessage != nil)
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
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $showDeleteConfirmation) {
            Button("Delete Job", role: .destructive) { store.removeJob(draft.id) }
        } message: {
            Text("Files are not deleted, but this job and its saved credentials will be removed.")
        }
    }

    private var intervalLabel: String {
        if draft.intervalSeconds < 60 { return "\(Int(draft.intervalSeconds)) sec" }
        return "\(Int(draft.intervalSeconds / 60)) min"
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

    private func save() {
        store.saveJob(draft, leftPassword: leftPassword, rightPassword: rightPassword)
        saveConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saveConfirmation = false
        }
    }
}

private struct EndpointEditor: View {
    @Binding var endpoint: Endpoint
    @Binding var password: String
    @State private var showFolderPicker = false
    @State private var folderError: String?

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
                if endpoint.kind == .ftp {
                    Label("FTP sends credentials and files without encryption. Prefer SFTP or FTPS.", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.orange)
                } else if endpoint.kind == .ftps {
                    Text("FTPS uses implicit TLS (normally port 990) and validates the server certificate.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("On first connection, the SSH host key is recorded; later changes are rejected.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !endpoint.host.isEmpty {
                        Button("Forget trusted host key") {
                            UserDefaults.standard.removeObject(forKey: "trusted-ssh-host-key.\(endpoint.host.lowercased()):\(endpoint.port)")
                        }
                        .controlSize(.small)
                    }
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
    }
}
