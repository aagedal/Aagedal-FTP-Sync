import AppKit
import SwiftUI

struct MetadataCalendarSettingsView: View {
    var managingMembers = false
    var addingServer = true
    var fixedJobID: UUID? = nil
    var beforeAttachment: () -> Bool = { true }
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    @EnvironmentObject private var startup: Version3StartupController
    @AppStorage("metadataSync.serverURL") private var savedAddress = ""
    @State private var address = ""
    @State private var serverName = ""
    @State private var editedServerName = ""
    @State private var firstTimeSetup = false
    @State private var deviceName = Host.current().localizedName ?? "My Mac"
    @State private var setupKey = ""
    @State private var invite = ""
    @State private var calendarName = "Shared calendar"
    @State private var jobID: UUID?
    @State private var calendarID: UUID?
    @State private var resolution: MetadataCalendarConflictReview?
    @State private var reviewError: String?
    @State private var hasChosenCalendar = false
    @State private var showDiagnostics = false
    @State private var migrationToAbandon: MetadataCalendarMigrationJournal?
    @State private var activationMessage: String?


    private var selectedBinding: MetadataCalendarBinding? { sync.binding(for: jobID) }
    private var availableCalendars: [MetadataCalendarSummary] {
        sync.calendars.filter { calendar in
            !sync.state.bindings.contains {
                $0.accountID == sync.account?.id && $0.id == calendar.id && $0.jobID != jobID
            }
        }
    }
    private var selectedCalendar: MetadataCalendarSummary? { sync.calendars.first { $0.id == calendarID } }
    var body: some View {
        Form {
            if managingMembers {
                if let account = sync.account, account.registered {
                    if sync.calendars.isEmpty {
                        Section("Members & Invitations") {
                            Text(sync.busy ? "Loading invitations and members…" : "This server has no shared calendars yet. Attach a job to create one.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(sync.calendars) { calendar in
                        MetadataCalendarAccessView(accountID: account.id, calendar: calendar,
                            showsCalendarName: sync.calendars.count > 1)
                            .id(account.id.uuidString + calendar.id.uuidString)
                    }
                } else {
                    Section("Members & Invitations") {
                        Text("Select a connected sync server from the list.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if fixedJobID == nil {
                if !addingServer { savedServers }
                else {
                Section("Add a sync server") {
                    Picker("Connection method", selection: $firstTimeSetup) {
                        Text("Join existing server").tag(false)
                        Text("Initialize Sync server").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("metadata-sync-connection-method")
                    .disabled(sync.busy)
                    TextField("Server name", text: $serverName, prompt: Text("e.g. Newsroom"))
                        .accessibilityIdentifier("metadata-sync-server-name")
                        .disabled(sync.busy)
                    connectionFields
                }
                }
            } else {
                Section("Calendar on this Mac") {
                    if let binding = selectedBinding {
                        if sync.isPaused {
                            Button("Resume Calendar Sync") { _ = startCalendarSyncIfNeeded() }
                        }
                        let activity = sync.activity(for: binding.jobID)
                        Label(activity.phase.title, systemImage: activity.phase.symbol)
                        Text("Linked to “\(binding.snapshot.name)”").font(.headline)
                        LabeledContent("Sync server", value: sync.state.accounts.first { $0.id == binding.accountID }?.displayName ?? "Unavailable")
                            .textSelection(.enabled)
                        Text(binding.snapshot.compatibility == .templates ? "Template-enabled calendar" : "Classic calendar")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(activity.detail).textSelection(.enabled)
                        if let date = activity.lastSuccess { Text("Last successful sync: \(date.formatted())").font(.caption) }
                        if binding.conflict != nil {
                            Button("Resolve Conflicts…") {
                                do { resolution = try sync.conflictReview(binding); reviewError = nil }
                                catch { reviewError = error.localizedDescription }
                            }.disabled(sync.busy)
                            if let reviewError { Text(reviewError).foregroundStyle(.secondary) }
                        }
                        if binding.snapshot.compatibility == .legacy, binding.snapshot.role == "owner",
                           binding.snapshot.range == nil {
                            Button("Create Template-Enabled Calendar…") { sync.prepareMigration(binding) }
                                .disabled(sync.busy || sync.state.pendingMigrations.contains(where: \.isPending))
                            Text("Review a new calendar for this job. The classic calendar stays separate, and its participants must be invited to the new calendar.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Calendar sync is off for this job", systemImage: "icloud.slash")
                        Text("Choose a shared calendar or create one from this job, then activate sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Saved changes sync shortly after editing. Updates from other Macs are checked about every 10 seconds while the app is running. Offline edits are kept on this Mac and retried automatically, even when automatic file transfers are off.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("View Sync Activity & Errors…") { showDiagnostics = true }
                        Spacer()
                        if let binding = selectedBinding {
                            Button("Detach and Keep Local Metadata") { sync.detach(binding) }
                                .disabled(sync.busy)
                        }
                    }
                }
                if selectedBinding == nil {
                    Section("Attach to a sync server") {
                        if sync.state.accounts.contains(where: \.registered) {
                            serverPicker
                            if sync.isPaused {
                                Button("Load Server Calendars") {
                                    guard startCalendarSyncIfNeeded() else { return }
                                    Task { await sync.refresh() }
                                }
                            } else if sync.account?.registered == true {
                                calendarSetup
                            }
                        } else {
                            Text("Add a sync server in Settings → Sync Servers first.")
                        }
                        Button("Manage Sync Servers…", action: openServerSettings)
                    }
                }
                if let pending = sync.state.pendingReceive, pending.source.id == fixedJobID {
                    Section("Sync activation pending") {
                        Text("Finish linking “\(pending.duplicate.name)” to its downloaded calendar. Any saved copy stays paused until you enable it.")
                        Button("Finish Activating Sync") { sync.retryPendingReceive() }
                        Button("Cancel Pending Link") { sync.cancelPendingReceive() }
                    }
                }
                ForEach(sync.state.pendingMigrations.filter { $0.isPending && $0.source.jobID == fixedJobID }) { journal in
                    Section("Calendar migration pending") {
                        Text("“\(journal.source.snapshot.name)” still uses its classic calendar on this Mac.")
                        LabeledContent("Local job", value: store.jobs.first(where: { $0.id == journal.source.jobID })?.name ?? journal.source.jobID.uuidString)
                        LabeledContent("Server", value: journal.serverAddress).textSelection(.enabled)
                        Text(journal.phase == .serverConfirmed
                             ? "The new template calendar was confirmed. Finish linking it after reviewing any local edits made since migration began."
                             : "The saved creation request may have reached the server. Retry checks the same new calendar and preserves your original calendar.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(journal.phase == .serverConfirmed ? "Finish Calendar Migration" : "Retry Migration") {
                            sync.retryMigration(journal.destinationID)
                        }.disabled(sync.busy)
                        Button("Keep Using Classic Calendar…") { migrationToAbandon = journal }.disabled(sync.busy)
                    }
                }
            }
            if let activationMessage { Text(activationMessage).textSelection(.enabled) }
            if !sync.message.isEmpty { Text(sync.message).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .controlSize(.large)
        .textFieldStyle(.roundedBorder)
        .overlay(alignment: .topTrailing) {
            if sync.busy {
                HStack { ProgressView().controlSize(.small); Text(sync.currentOperation ?? "Updating…").font(.caption) }
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
            }
        }
        .onAppear {
            address = sync.account?.address ?? savedAddress
            jobID = fixedJobID
            editedServerName = sync.account?.name ?? ""
            if let job = store.jobs.first(where: { $0.id == jobID }) { calendarName = job.name }
            if managingMembers, sync.account?.registered == true { _ = startCalendarSyncIfNeeded() }
            sync.selectProtocol(.templates)
            selectJobServer()
            selectSuggestedCalendar()
        }
        .onDisappear { setupKey = ""; invite = ""; sync.invitation = ""; sync.migrationProposal = nil }
        .onChange(of: calendarID) { _, _ in sync.clearSharingDetails() }
        .onChange(of: jobID) { _, id in
            sync.clearSharingDetails()
            hasChosenCalendar = false
            if let job = store.jobs.first(where: { $0.id == id }) { calendarName = job.name }
            selectJobServer()
            selectSuggestedCalendar()
        }
        .onChange(of: sync.suggestedCalendarID) { _, id in
            if let id { calendarID = id; hasChosenCalendar = true }
        }
        .onChange(of: sync.calendars.map(\.id)) { _, _ in selectSuggestedCalendar() }
        .onChange(of: sync.discoveryProtocol) { _, _ in
            calendarID = nil
            hasChosenCalendar = false
            sync.clearSharingDetails()
        }
        .onChange(of: sync.account?.name) { _, name in editedServerName = name ?? "" }
        .onChange(of: sync.state.activeAccountID) { _, _ in
            address = sync.account?.address ?? savedAddress
            editedServerName = sync.account?.name ?? ""
            calendarID = nil
            hasChosenCalendar = false
            selectSuggestedCalendar()
        }
        .sheet(isPresented: $showDiagnostics) { MetadataSyncDiagnosticsView(jobID: jobID) }
        .onChange(of: sync.receivedJobID) { _, id in
            if let id { store.selectedJobID = id }
        }
        .sheet(item: Binding(get: {
            sync.receiveProposal?.source.id == fixedJobID ? sync.receiveProposal : nil
        }, set: { sync.receiveProposal = $0 })) { proposal in
            VStack(alignment: .leading, spacing: 16) {
                Text("Activate sync in a copy?").font(.headline)
                Text("“\(proposal.source.name)” already has metadata programming or a calendar link.")
                Text("Create “\(proposal.duplicate.name)” with the same connections, folders and local processing settings, and sync it with “\(proposal.calendar.name)” (\(proposal.calendar.document.clips.count) clips). The copy gets only the calendar content shared with you.")
                Text("The original keeps its current calendar. Automatic running and startup at app launch will be disabled on the original. The new copy also starts paused so you can review it before enabling it.")
                if !sync.message.isEmpty { Text(sync.message).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel", role: .cancel) { sync.receiveProposal = nil }
                    Spacer()
                    Button("Duplicate & Activate Sync") { sync.confirmReceive(proposal) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 570)
            .disabled(sync.busy)
        }
        .sheet(item: $resolution) { review in
            MetadataCalendarConflictView(review: review)
        }
        .sheet(item: Binding(get: {
            sync.migrationProposal?.source.jobID == fixedJobID ? sync.migrationProposal : nil
        }, set: { sync.migrationProposal = $0 })) { journal in
            VStack(alignment: .leading, spacing: 16) {
                Text("Create a template-enabled calendar?").font(.headline)
                Text("Create a new calendar from “\(journal.source.snapshot.name)” at revision \(journal.source.snapshot.revision), then link the local job “\(store.jobs.first(where: { $0.id == journal.source.jobID })?.name ?? "Unavailable job")” to it.")
                LabeledContent("Server", value: journal.serverAddress).textSelection(.enabled)
                Text("The current calendar stays unchanged and future edits are not mirrored to it. Other participants keep the classic calendar until you invite them to the new one. Every participant in the new calendar needs 3.0; existing invitations and access grants are not copied.")
                Text("The reviewed metadata remains literal until you explicitly enable variables. Unsynced edits or a changed calendar require a fresh review.")
                    .font(.caption).foregroundStyle(.secondary)
                if !sync.message.isEmpty { Text(sync.message).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel", role: .cancel) { sync.migrationProposal = nil }
                    Spacer()
                    Button("Create and Link New Calendar") { sync.confirmMigration(journal) }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 590).disabled(sync.busy)
        }
        .alert("Keep using the classic calendar?", isPresented: Binding(
            get: { migrationToAbandon != nil }, set: { if !$0 { migrationToAbandon = nil } }), presenting: migrationToAbandon) { journal in
                Button("Keep Using Classic Calendar") { sync.cancelMigration(journal.destinationID); migrationToAbandon = nil }
                Button("Cancel", role: .cancel) { migrationToAbandon = nil }
            } message: { journal in
                Text("Keep “\(store.jobs.first(where: { $0.id == journal.source.jobID })?.name ?? journal.source.jobID.uuidString)” linked to “\(journal.source.snapshot.name)” on \(journal.serverAddress). Your current local edits are kept. Any new calendar already created remains on that server with its owner's access; no invitations were copied. The saved migration record is retained for recovery history.")
            }
    }

    private var serverPicker: some View {
        Picker("Saved server", selection: Binding(get: { sync.state.activeAccountID }, set: { if let id = $0, startCalendarSyncIfNeeded() { sync.selectAccount(id) } })) {
            ForEach(sync.state.accounts) { account in
                Text(account.displayName + (account.registered ? " · \(sync.state.bindings.filter { $0.accountID == account.id }.count) jobs" : " (setup pending)")).tag(Optional(account.id))
            }
        }.disabled(sync.busy)
    }

    private var savedServers: some View {
        Section("Sync Servers") {
            if let account = sync.account {
                LabeledContent("Server URL", value: account.address).textSelection(.enabled)
                TextField("Server name", text: $editedServerName)
                Button("Save Name") {
                    guard startCalendarSyncIfNeeded() else { return }
                    sync.renameAccount(account.id, name: editedServerName)
                }.disabled(sync.busy || editedServerName == (account.name ?? ""))
            }
            Text("Add and name servers here. Attach each job in Job settings → Metadata Sync.")
                .foregroundStyle(.secondary)
        }
    }

    private func openServerSettings() {
        store.settingsTab = .metadataSync
        store.metadataSyncSettingsTab = .calendars
        RegularWindowController.shared.prepareForOpening()
        openSettings()
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if firstTimeSetup {
                Text("Initialize a newly installed 3.0 sync server. Attach jobs from their settings afterwards.")
                    .foregroundStyle(.secondary)
                serverAddressField
                SecureField("Temporary setup key", text: $setupKey)
                Text("Enable first-device setup in the private server configuration, then enter its setup key.")
                    .foregroundStyle(.secondary)
                Button("Initialize Server") {
                    guard startCalendarSyncIfNeeded() else { return }
                    calendarID = nil
                    hasChosenCalendar = true
                    sync.register(address: address, deviceName: deviceName, setupKey: setupKey, invite: nil, protocolVersion: .templates, serverName: serverName)
                    setupKey = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(setupKey.isEmpty || address.isEmpty || deviceName.isEmpty)
            } else {
                TextField("Paste join string", text: $invite, axis: .vertical)
                    .lineLimit(3...5)
                    .privacySensitive()
                    .autocorrectionDisabled()
                    .font(.body)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("metadata-sync-invitation")
                if let server = try? MetadataSyncInvitation(invite).address {
                    LabeledContent("Server from invitation", value: server)
                        .textSelection(.enabled)
                } else if !invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    serverAddressField
                    Text("This code needs a server URL. You can also paste a complete join string that includes it.")
                        .foregroundStyle(.secondary)
                }
                Button("Add Sync Server") {
                    do {
                        let invitation = try MetadataSyncInvitation(invite)
                        _ = try MetadataSyncServer(address: invitation.address ?? address)
                    } catch {
                        activationMessage = error.localizedDescription
                        return
                    }
                    guard startCalendarSyncIfNeeded() else { return }
                    sync.register(address: address, deviceName: deviceName, setupKey: nil, invite: invite, protocolVersion: .templates, serverName: serverName)
                    invite = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceName.isEmpty)
                .accessibilityIdentifier("metadata-sync-server-connect")
            }
        }
        .disabled(sync.busy)
        .padding(.vertical, 8)
        .onChange(of: firstTimeSetup) { _, _ in setupKey = ""; invite = "" }
    }

    /// Connecting is the user's explicit consent to start the paused sync runtime.
    /// Keep the input intact when startup admission fails so the user can retry.
    private func startCalendarSyncIfNeeded() -> Bool {
        activationMessage = nil
        guard sync.isPaused else { return true }
        do {
            try startup.activateCalendarSync()
            guard !sync.isPaused else {
                activationMessage = startup.userFacingMessage
                return false
            }
            return true
        } catch {
            activationMessage = startup.userFacingMessage
            return false
        }
    }

    private var serverAddressField: some View {
        TextField("Server URL", text: $address, prompt: Text("https://sync.example.com/"))
            .textContentType(.URL)
            .autocorrectionDisabled()
    }

    private var calendarSetup: some View {
        Group {
            Picker("Calendar to sync", selection: Binding(get: { calendarID }, set: {
                calendarID = $0
                hasChosenCalendar = true
            })) {
                Text("New shared calendar from this job").tag(nil as UUID?)
                ForEach(availableCalendars) { calendar in Text(calendar.name).tag(Optional(calendar.id)) }
            }
            if let selectedCalendar {
                Text(selectedCalendar.role == "reader"
                     ? "This invitation is read-only. Updates from the shared calendar will appear on this Mac; local edits will not be sent."
                     : "Changes sync both ways between this job and the shared calendar. Everyone with editing access can make changes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("For the initial setup, this job will use the shared calendar’s programming. If it already has programming, you’ll be offered a copy to preserve the original.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Calendar name", text: $calendarName)
                Text("Creates a shared calendar using this job’s programming. Once another Mac joins and activates sync, saved changes sync both ways.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Attach Job") {
                guard let jobID, beforeAttachment(), startCalendarSyncIfNeeded() else { return }
                if let calendarID { sync.attach(calendarID: calendarID, jobID: jobID, protocolVersion: .templates) }
                else { sync.publish(jobID: jobID, name: calendarName, range: nil, protocolVersion: .templates) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(sync.busy || jobID == nil || activationUnavailable)
            Text("Attaching saves this job’s settings. Metadata syncs automatically; file transfers remain independent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activationUnavailable: Bool {
        if let calendarID {
            return selectedCalendar == nil || sync.state.bindings.contains { $0.id == calendarID && $0.accountID == sync.account?.id }
        }
        return selectedBinding != nil || calendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectJobServer() {
        guard let binding = selectedBinding else { return }
        if sync.account?.id != binding.accountID { sync.selectAccount(binding.accountID) }
    }

    private func selectSuggestedCalendar() {
        if managingMembers {
            if calendarID == nil || !sync.calendars.contains(where: { $0.id == calendarID }) {
                calendarID = sync.calendars.first?.id
            }
            return
        }
        if let binding = selectedBinding, binding.accountID == sync.account?.id,
           binding.snapshot.compatibility.protocolVersion == sync.discoveryProtocol { calendarID = binding.id }
        else if !hasChosenCalendar {
            calendarID = availableCalendars.first(where: { $0.id == sync.suggestedCalendarID })?.id
                ?? (availableCalendars.count == 1 ? availableCalendars[0].id : nil)
        } else if let calendarID, !sync.calendars.contains(where: { $0.id == calendarID }) {
            self.calendarID = nil
        }
    }

}

/// Each calendar owns its invitation and member state, so a server with several
/// calendars can show every member list without a calendar selector.
private struct MetadataCalendarAccessView: View {
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    let accountID: UUID
    let calendar: MetadataCalendarSummary
    let showsCalendarName: Bool
    @State private var members: [MetadataCalendarMember] = []
    @State private var invitation = ""
    @State private var includeServerAddress = true
    @State private var role = "editor"
    @State private var inviteLimited = false
    @State private var inviteStart = Calendar.current.startOfDay(for: Date())
    @State private var inviteEnd = Calendar.current.startOfDay(for: Date())
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?

    private var invitationRange: MetadataSharingRange? {
        dateRange(limited: inviteLimited, start: inviteStart, end: inviteEnd,
                  zone: calendar.timeZone)
    }
    private func dateRange(limited: Bool, start: Date, end: Date, zone: String) -> MetadataSharingRange? {
        guard limited else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let first = calendar.date(from: Calendar.current.dateComponents([.year, .month, .day], from: start)) ?? start
        let last = calendar.date(from: Calendar.current.dateComponents([.year, .month, .day], from: end)) ?? end
        return MetadataSharingRange(start: first, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    var body: some View {
        Group {
            if calendar.role == "owner" {
                Section(showsCalendarName ? "Invite to “\(calendar.name)”" : "Invite another Mac") {
                    Picker("Permission", selection: $role) {
                        Text("Can edit").tag("editor")
                        Text("Read only").tag("reader")
                    }
                    dateRangeControls(limited: $inviteLimited, start: $inviteStart, end: $inviteEnd)
                    Button("Create Invitation") {
                        run(.init(action: "createInvite", calendarID: calendar.id, role: role,
                            rangeStart: invitationRange?.start, rangeEnd: invitationRange?.end))
                    }.disabled(sync.busy || loading || invitationRange.map { $0.end <= $0.start } == true)
                    if !invitation.isEmpty {
                        Toggle("Include server URL (recommended)", isOn: $includeServerAddress)
                        Button(includeServerAddress ? "Copy Invitation & Server URL" : "Copy Invitation Code") {
                            let address = sync.state.accounts.first { $0.id == accountID }?.address
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MetadataSyncInvitation.copyText(token: invitation,
                                address: includeServerAddress ? address : nil,
                                protocolVersion: calendar.compatibility.protocolVersion), forType: .string)
                        }
                        Text("Send this invitation privately. It works for one Mac and expires after 24 hours.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section(showsCalendarName ? "Members · \(calendar.name)" : "Members") {
                if calendar.role != "owner" {
                    Text("Only the calendar owner can view members and manage access.")
                        .foregroundStyle(.secondary)
                } else if loading {
                    ProgressView("Loading members…")
                } else if members.isEmpty && errorMessage == nil {
                    Text("No members found.").foregroundStyle(.secondary)
                }
                ForEach(members) { member in
                    HStack {
                        Text("\(member.name) · \(member.role)")
                        Spacer()
                        if calendar.role == "owner", member.role != "owner" {
                            Button("Revoke Access", role: .destructive) {
                                run(.init(action: "revokeMember", calendarID: calendar.id, deviceID: member.id))
                            }.disabled(sync.busy || loading)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).textSelection(.enabled)
                    Button("Retry") { run(.init(action: "listMembers", calendarID: calendar.id)) }
                        .disabled(sync.busy || loading)
                }
                if calendar.role == "owner" {
                    Button("Revoke All Invitations", role: .destructive) {
                        run(.init(action: "revokeInvites", calendarID: calendar.id))
                    }.disabled(sync.busy || loading)
                    Text("Revocation stops future sync. Previously downloaded metadata remains on the recipient’s device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard calendar.role == "owner" else { loading = false; return }
            await perform(.init(action: "listMembers", calendarID: calendar.id))
        }
        .onDisappear { operation?.cancel(); invitation = "" }
    }

    private func run(_ request: MetadataCalendarRequest) {
        operation?.cancel()
        operation = Task { await perform(request) }
    }

    private func perform(_ request: MetadataCalendarRequest) async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            // Calendar discovery or another panel may already be using the coordinator.
            while sync.busy { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
            let response = try await sync.calendarAccessRequest(request, accountID: accountID,
                protocolVersion: calendar.compatibility.protocolVersion)
            try Task.checkCancellation()
            if request.action == "createInvite" { invitation = response.inviteToken ?? "" }
            else if request.action == "listMembers" { members = response.members ?? [] }
            else {
                if request.action == "revokeInvites" { invitation = "" }
                let refreshed = try await sync.calendarAccessRequest(.init(action: "listMembers", calendarID: calendar.id),
                    accountID: accountID, protocolVersion: calendar.compatibility.protocolVersion)
                try Task.checkCancellation()
                members = refreshed.members ?? []
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    private func dateRangeControls(limited: Binding<Bool>, start: Binding<Date>, end: Binding<Date>) -> some View {
        Group {
            Toggle("Limit to a date range", isOn: limited)
            if limited.wrappedValue {
                DatePicker("From", selection: start, displayedComponents: .date)
                DatePicker("Through", selection: end, displayedComponents: .date)
                Text("Only clips entirely inside these dates are shared. Clips crossing a boundary are excluded. Date-range recipients can edit clips but cannot change photographer details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
