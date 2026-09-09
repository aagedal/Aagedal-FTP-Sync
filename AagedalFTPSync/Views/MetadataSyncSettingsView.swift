import SwiftUI

struct MetadataSyncSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("metadataSync.serverURL") private var savedAddress = ""
    @State private var address = ""
    @State private var setupKey = ""
    @State private var message: String?
    @State private var checkResults: [MetadataSyncServerCheck] = []
    @State private var checkTask: Task<Void, Never>?
    @State private var requestID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Metadata sync section", selection: $store.metadataSyncSettingsTab) {
                Text("Calendar Sync").tag(MetadataSyncSettingsTab.calendars)
                Text("Hosting Checks").tag(MetadataSyncSettingsTab.hostingChecks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding()
            .accessibilityIdentifier("metadata-sync-section")

            switch store.metadataSyncSettingsTab {
            case .calendars:
                MetadataCalendarSettingsView()
            case .hostingChecks:
                hostingForm
            }
        }.frame(minWidth: 680, minHeight: 600)
    }

    private var hostingForm: some View {
        Form {
            Section("Metadata Sync Server") {
                Text("Connect to a server hosted by you or your organization.")
                TextField("Server URL", text: $address, prompt: Text("https://sync.example.com/"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .disabled(requestID != nil)
                HStack {
                    Button("Save Server", action: save)
                        .disabled(requestID != nil || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Check Server") { check(database: false) }
                        .disabled(requestID != nil || address.isEmpty)
                    Button("Remove Server") {
                        savedAddress = ""
                        address = ""
                        setupKey = ""
                        checkResults = []
                        message = "Server address removed."
                    }
                    .disabled(requestID != nil || savedAddress.isEmpty)
                }
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
        .frame(minWidth: 600, minHeight: 440)
        .onAppear { address = savedAddress }
        .onDisappear { cancel(); setupKey = "" }
        .onChange(of: address) { _, _ in
            checkResults = []
            message = nil
            setupKey = ""
        }
    }

    private func save() {
        do {
            let server = try MetadataSyncServer(address: address)
            savedAddress = server.baseURL.absoluteString
            message = "Server address saved. Open Calendar Sync to register or join."
        } catch { message = error.localizedDescription }
    }

    private func check(database: Bool) {
        do {
            let server = try MetadataSyncServer(address: address)
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
                        ? (database ? "Hosting checks passed. Install the live sync schema and connect from Calendar Sync." : "Server reached. Run Check Database to verify MySQL access.")
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
