import SwiftUI

struct ServerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedProfileID: UUID?
    @State private var draft: ServerProfile?
    @State private var password = ""
    @State private var credentialLoadError: String?
    @State private var isNewProfile = false
    @State private var profilePendingDeletion: ServerProfile?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Known Servers")
                        .font(.headline)
                    Spacer()
                    Button(action: addProfile) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add Server")
                    Button(action: requestDeletion) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProfile == nil)
                    .help("Delete Server")
                }
                .padding(12)

                Divider()

                List(selection: $selectedProfileID) {
                    ForEach(displayedProfiles) { profile in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .fontWeight(.medium)
                            Text(profileSummary(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let count = store.serverProfileUsages(for: profile.id).count
                            if count > 0 {
                                Text(count == 1 ? "Used by 1 job" : "Used by \(count) jobs")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(profile.id)
                    }
                }
            }
            .frame(minWidth: 235, idealWidth: 260, maxWidth: 310)

            Group {
                if let draftBinding {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            usageSection(for: draftBinding.wrappedValue)

                            Form {
                                Section("Connection") {
                                    TextField("Name", text: draftBinding.name)
                                    Picker("Protocol", selection: draftBinding.kind) {
                                        Text(EndpointKind.ftp.title).tag(EndpointKind.ftp)
                                        Text(EndpointKind.ftps.title).tag(EndpointKind.ftps)
                                        Text(EndpointKind.sftp.title).tag(EndpointKind.sftp)
                                    }
                                    .onChange(of: draftBinding.wrappedValue.kind) { _, kind in
                                        draft?.port = kind.defaultPort
                                        if kind != .sftp { draft?.hostKeyFingerprint = "" }
                                    }
                                    TextField("Server", text: draftBinding.host, prompt: Text("photos.example.com"))
                                        .textContentType(.URL)
                                    TextField("Port", value: draftBinding.port, format: .number)
                                        .frame(maxWidth: 180)
                                    TextField("Username", text: draftBinding.username)
                                        .textContentType(.username)
                                    SecureField("Password", text: $password)
                                        .textContentType(.password)
                                    if !password.isEmpty {
                                        Button("Remove Saved Password", role: .destructive) {
                                            password = ""
                                        }
                                        .help("The password is removed from Keychain when the server is saved.")
                                    }
                                    if draftBinding.wrappedValue.kind == .sftp {
                                        TextField(
                                            "Host key fingerprint",
                                            text: draftBinding.hostKeyFingerprint,
                                            prompt: Text("SHA256:…")
                                        )
                                        .textContentType(.none)
                                        Text("Verify the fingerprint independently with the server administrator before saving it.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .formStyle(.grouped)

                            if let credentialLoadError {
                                Label(credentialLoadError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }

                            HStack {
                                Spacer()
                                Button("Revert", action: loadSelectedProfile)
                                    .disabled(!hasUnsavedChanges)
                                Button("Save", action: saveDraft)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(
                                        !hasUnsavedChanges
                                            || draftBinding.wrappedValue.validationMessage != nil
                                            || credentialLoadError != nil
                                    )
                            }
                        }
                        .padding(20)
                    }
                } else {
                    ContentUnavailableView(
                        "No server selected",
                        systemImage: "server.rack",
                        description: Text("Select a server or add a reusable FTP, FTPS, or SFTP connection.")
                    )
                }
            }
            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 740, minHeight: 500)
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = store.serverProfiles.first?.id
            }
            loadSelectedProfile()
        }
        .onChange(of: selectedProfileID) { _, selectedID in
            if isNewProfile, selectedID != draft?.id {
                isNewProfile = false
            }
            loadSelectedProfile()
        }
        .onChange(of: store.serverProfiles) { _, profiles in
            if let selectedProfileID,
               !isNewProfile,
               !profiles.contains(where: { $0.id == selectedProfileID }) {
                self.selectedProfileID = profiles.first?.id
            }
            loadSelectedProfile()
        }
        .confirmationDialog(
            "Delete server profile?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            presenting: profilePendingDeletion
        ) { profile in
            Button("Delete \(profile.name)", role: .destructive) {
                deleteProfile(profile)
            }
            .disabled(!store.serverProfileUsages(for: profile.id).isEmpty)
        } message: { profile in
            let usages = store.serverProfileUsages(for: profile.id)
            if usages.isEmpty {
                Text("This removes the server and its saved password.")
            } else {
                Text("Used by \(usageList(usages)). Choose another server in those jobs before deleting it.")
            }
        }
        .alert("Aagedal FTP Sync", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    private var selectedProfile: ServerProfile? {
        guard let selectedProfileID else { return nil }
        return store.serverProfiles.first { $0.id == selectedProfileID }
    }

    private var displayedProfiles: [ServerProfile] {
        var profiles = store.serverProfiles
        if isNewProfile, let draft, !profiles.contains(where: { $0.id == draft.id }) {
            profiles.append(draft)
        }
        return profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var draftBinding: Binding<ServerProfile>? {
        guard draft != nil else { return nil }
        return Binding(
            get: { draft ?? ServerProfile(name: "") },
            set: { draft = $0 }
        )
    }

    private var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        return isNewProfile
            || draft != store.serverProfiles.first(where: { $0.id == draft.id })
            || password != loadedPassword
    }

    @State private var loadedPassword = ""

    @ViewBuilder
    private func usageSection(for profile: ServerProfile) -> some View {
        let usages = store.serverProfileUsages(for: profile.id)
        VStack(alignment: .leading, spacing: 8) {
            Label(
                usages.isEmpty ? "Not used by any sync jobs" : "Used by sync jobs",
                systemImage: usages.isEmpty ? "link.badge.plus" : "link"
            )
            .font(.headline)

            if usages.isEmpty {
                Text("This server can be deleted safely. Jobs can select it from their connection settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Saving connection or trust changes updates every job listed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(usages) { usage in
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                        Text(usage.jobName)
                        Spacer()
                        Text(usage.locationDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func loadSelectedProfile() {
        guard !isNewProfile, let selectedProfile else {
            if selectedProfileID == nil {
                draft = nil
                password = ""
                loadedPassword = ""
                credentialLoadError = nil
            }
            return
        }
        draft = selectedProfile
        do {
            let savedPassword = try store.password(for: selectedProfile)
            password = savedPassword
            loadedPassword = savedPassword
            credentialLoadError = nil
        } catch {
            password = ""
            loadedPassword = ""
            credentialLoadError = "The saved password could not be loaded: \(error.localizedDescription)"
        }
    }

    private func addProfile() {
        let profile = ServerProfile(name: uniqueName())
        isNewProfile = true
        draft = profile
        selectedProfileID = profile.id
        password = ""
        loadedPassword = ""
        credentialLoadError = nil
    }

    private func saveDraft() {
        guard let draft, store.saveServerProfile(draft, password: password) else { return }
        isNewProfile = false
        self.draft = store.serverProfiles.first { $0.id == draft.id }
        loadSelectedProfile()
    }

    private func requestDeletion() {
        profilePendingDeletion = selectedProfile
    }

    private func deleteProfile(_ profile: ServerProfile) {
        guard store.removeServerProfile(profile.id) else {
            profilePendingDeletion = nil
            return
        }
        selectedProfileID = store.serverProfiles.first?.id
        isNewProfile = false
        loadSelectedProfile()
        profilePendingDeletion = nil
    }

    private func uniqueName() -> String {
        let usedNames = Set(store.serverProfiles.map { $0.name.lowercased() })
        var number = 1
        while usedNames.contains("server \(number)") { number += 1 }
        return "Server \(number)"
    }

    private func profileSummary(_ profile: ServerProfile) -> String {
        let port = profile.port == profile.kind.defaultPort ? "" : ":\(profile.port)"
        let host = profile.host.isEmpty ? "Not configured" : "\(profile.host)\(port)"
        return "\(profile.kind.rawValue.uppercased()) · \(host)"
    }

    private func usageList(_ usages: [ServerProfileUsage]) -> String {
        usages.map { "“\($0.jobName)” (\($0.locationDescription))" }.joined(separator: ", ")
    }
}
