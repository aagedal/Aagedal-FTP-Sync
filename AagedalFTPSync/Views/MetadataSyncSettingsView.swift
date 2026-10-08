import SwiftUI

struct MetadataSyncSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    @EnvironmentObject private var startup: Version3StartupController
    @State private var addingServer = false
    @State private var serverPendingRemoval: MetadataSyncAccount?
    @State private var serverActionError: String?
    @AppStorage("metadataSync.serverURL") private var savedAddress = ""
    @State private var address = ""
    @State private var setupKey = ""
    @State private var message: String?
    @State private var checkResults: [MetadataSyncServerCheck] = []
    @State private var checkTask: Task<Void, Never>?
    @State private var requestID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            serverSidebar
            Divider()
            VStack(spacing: 0) {
            Picker("Metadata sync section", selection: $store.metadataSyncSettingsTab) {
                Text("Servers").tag(MetadataSyncSettingsTab.calendars)
                Text("Members & Invitations").tag(MetadataSyncSettingsTab.members)
                Text("Hosting Checks").tag(MetadataSyncSettingsTab.hostingChecks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding()
            .accessibilityIdentifier("metadata-sync-section")

            switch store.metadataSyncSettingsTab {
            case .calendars:
                MetadataCalendarSettingsView(addingServer: addingServer)
                    .id(addingServer)
            case .members:
                MetadataCalendarSettingsView(managingMembers: true)
            case .hostingChecks:
                hostingForm
            }
            if let serverActionError { Text(serverActionError).padding().textSelection(.enabled) }
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { addingServer = sync.state.accounts.isEmpty }
        .onChange(of: sync.state.accounts.map(\.id)) { old, new in
            if new.isEmpty { addingServer = true }
            else if new.count > old.count { addingServer = false }
        }
        .confirmationDialog("Remove “\(serverPendingRemoval?.displayName ?? "")”?", isPresented: Binding(
            get: { serverPendingRemoval != nil }, set: { if !$0 { serverPendingRemoval = nil } }
        )) {
            Button("Remove Server and Detach Jobs", role: .destructive) {
                guard let account = serverPendingRemoval, activateIfNeeded() else { return }
                sync.removeAccount(account.id)
                serverPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { serverPendingRemoval = nil }
        } message: {
            Text("Remove this server from this Mac and detach its jobs. Local metadata and files are kept. The server and other Macs are unchanged. You will need another invitation to reconnect.")
        }
    }

    private var serverSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("Sync Servers").font(.headline)
                Spacer()
                Button {
                    addingServer = true
                    store.metadataSyncSettingsTab = .calendars
                } label: { sidebarIcon("plus") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Sync Server")
                    .accessibilityIdentifier("metadata-sync-server-add")
                    .help("Add Sync Server")
                    .disabled(sync.busy)
                Button { serverPendingRemoval = sync.account } label: { sidebarIcon("minus") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove Sync Server")
                    .accessibilityIdentifier("metadata-sync-server-remove")
                    .help("Remove server and detach its jobs, keeping local metadata")
                    .disabled(sync.busy || addingServer || sync.account == nil)
            }.padding(12)
            Divider()
            List(selection: Binding<UUID?>(
                get: { addingServer ? nil : sync.state.activeAccountID },
                set: { id in
                    guard let id, activateIfNeeded() else { return }
                    addingServer = false
                    sync.selectAccount(id)
                }
            )) {
                ForEach(sync.state.accounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName).fontWeight(.medium)
                        Text(account.address).font(.caption).foregroundStyle(.secondary)
                        let count = sync.state.bindings.filter { $0.accountID == account.id }.count
                        Text(account.registered ? "Attached jobs: \(count)" : "Setup pending")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(account.id)
                }
            }
            .accessibilityIdentifier("metadata-sync-server-list")
            .disabled(sync.busy)
        }.frame(width: 280)
    }

    private func sidebarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    private func activateIfNeeded() -> Bool {
        serverActionError = nil
        guard sync.isPaused else { return true }
        do {
            try startup.activateCalendarSync()
            guard !sync.isPaused else { serverActionError = startup.userFacingMessage; return false }
            return true
        } catch { serverActionError = startup.userFacingMessage; return false }
    }

    private var hostingForm: some View {
        Form {
            Section("Hosting Address") {
                Text("Test a deployment before adding it to Sync Servers.")
                TextField("Server URL", text: $address, prompt: Text("https://sync.example.com/"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .disabled(requestID != nil)
                Button("Check Server") { check(database: false) }
                    .disabled(requestID != nil || address.isEmpty)
            }
            Section("Hosting Compatibility") {
                Text("Check PHP and database compatibility before connecting a calendar.")
                    .foregroundStyle(.secondary)
                SecureField("Hosting check key", text: $setupKey)
                    .disabled(requestID != nil)
                Text("The server administrator generates this temporary key during setup. It is used only for the database check and is not saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check Database") { check(database: true) }
                    .disabled(requestID != nil || address.isEmpty || setupKey.isEmpty)
            }
            if requestID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking hosting…")
                    Button("Cancel", action: cancel)
                }
            }
            if let message {
                Text(message).textSelection(.enabled)
            }
            ForEach(checkResults, id: \.name) { result in
                Label(result.name, systemImage: result.passed ? "checkmark.circle" : "exclamationmark.triangle")
                    .labelStyle(AccessibleStatusLabelStyle(symbolColor: result.passed ? .green : .orange))
            }
        }
        .formStyle(.grouped)
        .controlSize(.large)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 600, minHeight: 440)
        .onAppear { address = savedAddress }
        .onDisappear { cancel(); setupKey = "" }
        .onChange(of: address) { _, _ in
            checkResults = []
            message = nil
            setupKey = ""
        }
    }

    private func check(database: Bool) {
        do {
            let server = try MetadataSyncServer(address: address)
            savedAddress = server.baseURL.absoluteString
            let id = UUID()
            requestID = id
            checkResults = []
            message = nil
            let key = database ? setupKey : nil
            checkTask = Task { @MainActor in
                do {
                    let info = try await MetadataSyncServerClient().check(server: server, setupKey: key)
                    guard requestID == id else { return }
                    checkResults = info.checks
                    let expected = database ? ["PHP runtime", "MySQL driver", "Database read/write", "Transaction rollback", "Unicode metadata"] : ["PHP runtime", "MySQL driver"]
                    let passed = expected.allSatisfy { name in info.checks.contains { $0.name == name && $0.passed } }
                    message = passed
                        ? (database ? "Hosting checks passed. Install the live sync schema and connect from Servers." : "Server reached. Run Check Database to verify MySQL access.")
                        : "The server responded, but some required hosting checks did not pass."
                } catch {
                    guard requestID == id else { return }
                    message = error.localizedDescription
                }
                if database { setupKey = "" }
                requestID = nil
                checkTask = nil
            }
        } catch { message = error.localizedDescription }
    }

    private func cancel() {
        checkTask?.cancel()
        checkTask = nil
        requestID = nil
    }
}
