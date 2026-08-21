import AppKit
import SwiftUI

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
                    LabeledContent("Deletion policy") {
                        Text("Never delete files").foregroundStyle(.secondary)
                    }
                    Text("Transfers are written to a temporary file first. Two-way sync keeps the newest copy and does not propagate deletions.")
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
        Binding(get: { draft.filter.recentHours ?? 0 }, set: { draft.filter.recentHours = $0 == 0 ? nil : $0 })
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

    var body: some View {
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
                    Button("Choose…") { chooseFolder() }
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for this sync job"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                endpoint.localPath = url.path
                endpoint.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                endpoint.localPath = ""
                endpoint.bookmark = nil
            }
        }
    }
}
