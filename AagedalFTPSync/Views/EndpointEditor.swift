import SwiftUI
import UniformTypeIdentifiers

struct EndpointSummaryCard: View {
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
                HStack {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    if !password.isEmpty {
                        Button("Remove Saved Password", role: .destructive) {
                            password = ""
                        }
                        .help("The password is removed from Keychain when the job is saved.")
                    }
                }
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
