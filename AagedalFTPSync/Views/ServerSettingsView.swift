import AppKit
import SwiftUI

@MainActor
final class ServerProfileEditingSession: ObservableObject {
    @Published var draft: ServerProfile?
    @Published var password = ""
    @Published private(set) var credentialLoadError: String?
    private var savedProfile: ServerProfile?
    private var loadedPassword = ""

    var isNewProfile: Bool { draft != nil && savedProfile == nil }
    var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        return isNewProfile || draft != savedProfile || password != loadedPassword
    }

    func edit(_ profile: ServerProfile?, using store: AppStore) {
        draft = profile
        savedProfile = profile
        password = ""
        loadedPassword = ""
        credentialLoadError = nil
        if profile != nil { retryCredentials(using: store) }
    }

    func beginNew(_ profile: ServerProfile) {
        draft = profile
        savedProfile = nil
        password = ""
        loadedPassword = ""
        credentialLoadError = nil
    }

    func retryCredentials(using store: AppStore) {
        guard let savedProfile else { return }
        do {
            let saved = try store.password(for: savedProfile)
            if password == loadedPassword { password = saved }
            loadedPassword = saved
            credentialLoadError = nil
        } catch {
            credentialLoadError = "The saved password could not be loaded: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(using store: AppStore) -> Bool {
        guard let draft, credentialLoadError == nil else { return false }
        if let savedProfile, store.serverProfiles.first(where: { $0.id == draft.id }) != savedProfile {
            store.alertMessage = "This server changed in another window or was removed. Your edits are still here. Revert to load the latest saved settings before editing again."
            return false
        }
        guard store.saveServerProfile(draft, password: password) else { return false }
        savedProfile = store.serverProfiles.first(where: { $0.id == draft.id })
        self.draft = savedProfile
        loadedPassword = password
        return true
    }

    func confirmLeavingDraft(using store: AppStore) -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(draft?.name ?? "Server")”?"
        alert.informativeText = "Your server settings and password edits have not been saved."
        alert.addButton(withTitle: "Save Changes").isEnabled = draft?.validationMessage == nil && credentialLoadError == nil
        alert.addButton(withTitle: isNewProfile ? "Discard Draft" : "Discard Changes")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(using: store)
        case .alertSecondButtonReturn:
            edit(store.serverProfiles.first(where: { $0.id == draft?.id }), using: store)
            return true
        default: return false
        }
    }
}

struct ServerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedProfileID: UUID?
    @State private var selectionRefreshID = UUID()
    @StateObject private var session: ServerProfileEditingSession
    @State private var profilePendingDeletion: ServerProfile?
    private let protectsWindowClose: Bool

    init(session: ServerProfileEditingSession = ServerProfileEditingSession(), protectsWindowClose: Bool = true) {
        _session = StateObject(wrappedValue: session)
        self.protectsWindowClose = protectsWindowClose
    }

    private var draft: ServerProfile? {
        get { session.draft }
        nonmutating set { session.draft = newValue }
    }
    private var password: String { session.password }
    private var credentialLoadError: String? { session.credentialLoadError }
    private var isNewProfile: Bool { session.isNewProfile }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Text("FTP Servers")
                        .font(.headline)
                    Spacer()
                    Button(action: addProfile) {
                        toolbarIcon("plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Server")
                    .accessibilityHint("Creates a new shared server profile")
                    .help("Add Server")
                    Button(action: duplicateProfile) {
                        toolbarIcon("plus.square.on.square")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedProfile == nil || hasUnsavedChanges || credentialLoadError != nil)
                    .accessibilityLabel("Duplicate Server")
                    .accessibilityHint("Creates a copy of the selected server profile")
                    .help("Duplicate Server")
                    Button(action: requestDeletion) {
                        toolbarIcon("minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedProfile == nil)
                    .accessibilityIdentifier("server.delete")
                    .accessibilityLabel("Delete Server")
                    .accessibilityHint("Deletes the selected server profile")
                    .help("Delete Server")
                }
                .padding(12)

                Divider()

                List(selection: selectionBinding) {
                    ForEach(displayedProfiles) { profile in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .fontWeight(.medium)
                            if profile.id == draft?.id, hasUnsavedChanges {
                                Label("Unsaved changes", systemImage: "pencil.circle")
                                    .font(.caption)
                            }
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
                .id(selectionRefreshID)
            }
            .frame(width: 280)

            Divider()

            Group {
                if let draftBinding {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            usageSection(for: draftBinding.wrappedValue)

                            Form {
                                Section("Connection") {
                                    TextField("Name", text: draftBinding.name)
                                        .accessibilityIdentifier("server.name")
                                    Picker("Protocol", selection: protocolBinding) {
                                        Text(EndpointKind.ftp.title).tag(EndpointKind.ftp)
                                        Text(EndpointKind.ftps.title).tag(EndpointKind.ftps)
                                        Text(EndpointKind.sftp.title).tag(EndpointKind.sftp)
                                    }
                                    .accessibilityIdentifier("server.protocol")
                                    TextField("Server", text: draftBinding.host, prompt: Text("photos.example.com"))
                                        .textContentType(.URL)
                                    TextField("Port", value: draftBinding.port, format: .number)
                                        .accessibilityIdentifier("server.port")
                                        .frame(maxWidth: 180)
                                    TextField("Username", text: draftBinding.username)
                                        .textContentType(.username)
                                    SecureField("Password", text: $session.password)
                                        .textContentType(.password)
                                    if !password.isEmpty {
                                        Button("Remove Saved Password", role: .destructive) {
                                            session.password = ""
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
                                    .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                                    .textSelection(.enabled)
                                Button("Retry Loading Password") { session.retryCredentials(using: store) }
                            }

                            HStack {
                                if let message = draftBinding.wrappedValue.validationMessage {
                                    Label(message, systemImage: "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(isNewProfile ? "Discard Draft" : "Revert", action: discardDraft)
                                    .disabled(!hasUnsavedChanges)
                                Button("Save") { saveDraft() }
                                    .accessibilityIdentifier("server.save")
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
            if hasUnsavedChanges {
                selectedProfileID = draft?.id
            } else {
                selectedProfileID = store.serverProfiles.first(where: { $0.id == draft?.id })?.id
                    ?? selectedProfile?.id ?? store.serverProfiles.first?.id
                loadSelectedProfile()
            }
        }
        .onChange(of: store.serverProfiles) { _, profiles in
            guard !hasUnsavedChanges else { return }
            if let selectedProfileID,
               !isNewProfile,
               !profiles.contains(where: { $0.id == selectedProfileID }) {
                self.selectedProfileID = profiles.first?.id
            }
            loadSelectedProfile()
        }
        .background {
            if protectsWindowClose {
                UnsavedChangesWindowGuard(closeDecision: confirmLeavingDraft)
            }
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

    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    private var selectedProfile: ServerProfile? {
        guard let selectedProfileID else { return nil }
        return store.serverProfiles.first { $0.id == selectedProfileID }
    }

    private var displayedProfiles: [ServerProfile] {
        var profiles = store.serverProfiles
        if let draft, !profiles.contains(where: { $0.id == draft.id }) {
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

    private var protocolBinding: Binding<EndpointKind> {
        Binding(get: { draft?.kind ?? .ftps }, set: { kind in
            guard draft?.kind != kind else { return }
            draft?.kind = kind
            draft?.port = kind.defaultPort
            if kind != .sftp { draft?.hostKeyFingerprint = "" }
        })
    }

    private var hasUnsavedChanges: Bool {
        session.hasUnsavedChanges
    }

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
        session.edit(selectedProfile, using: store)
    }

    private func addProfile() {
        guard confirmLeavingDraft() else { return }
        let profile = ServerProfile(name: uniqueName())
        session.beginNew(profile)
        selectedProfileID = profile.id
    }

    @discardableResult
    private func saveDraft() -> Bool {
        session.save(using: store)
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(get: { selectedProfileID }, set: { id in
            DispatchQueue.main.async {
                guard id != selectedProfileID else { return }
                guard confirmLeavingDraft() else {
                    // AppKit can retain the proposed row selection after a
                    // declined binding write. Restore it so the same row can
                    // be selected again after Cancel.
                    selectionRefreshID = UUID()
                    return
                }
                selectedProfileID = id
                loadSelectedProfile()
            }
        })
    }

    private func discardDraft() {
        if isNewProfile || selectedProfile == nil { selectedProfileID = store.serverProfiles.first?.id }
        loadSelectedProfile()
    }

    private func confirmLeavingDraft() -> Bool {
        guard session.confirmLeavingDraft(using: store) else { return false }
        if draft == nil { discardDraft() }
        return true
    }

    private func duplicateProfile() {
        guard let selectedProfile,
              let duplicate = store.duplicateServerProfile(selectedProfile.id) else { return }
        selectedProfileID = duplicate.id
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
