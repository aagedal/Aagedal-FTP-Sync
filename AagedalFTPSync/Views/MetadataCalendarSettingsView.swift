import AppKit
import SwiftUI

struct MetadataCalendarSettingsView: View {
    var managingMembers = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    @EnvironmentObject private var startup: Version3StartupController
    @AppStorage("metadataSync.serverURL") private var savedAddress = ""
    @State private var address = ""
    @State private var firstTimeSetup = false
    @State private var includeServerAddress = true
    @State private var deviceName = Host.current().localizedName ?? "My Mac"
    @State private var setupKey = ""
    @State private var invite = ""
    @State private var calendarName = "Shared calendar"
    @State private var jobID: UUID?
    @State private var calendarID: UUID?
    @State private var role = "editor"
    @State private var resolution: MetadataCalendarConflictReview?
    @State private var reviewError: String?
    @State private var hasChosenCalendar = false
    @State private var showDiagnostics = false
    @State private var inviteLimited = false
    @State private var inviteStart = Calendar.current.startOfDay(for: Date())
    @State private var inviteEnd = Calendar.current.startOfDay(for: Date())
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
    private var invitationRange: MetadataSharingRange? {
        dateRange(limited: inviteLimited, start: inviteStart, end: inviteEnd,
                  zone: selectedBinding?.snapshot.timeZone ?? TimeZone.current.identifier)
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
        Form {
            if managingMembers {
                Section("Members & Invitations") {
                    jobPicker
                    if let binding = selectedBinding {
                        LabeledContent("Calendar", value: binding.snapshot.name)
                        LabeledContent("Server", value: sync.state.accounts.first { $0.id == binding.accountID }?.address ?? "Unavailable")
                    } else {
                        Text("Connect this job to a server in Calendar Sync first.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let binding = selectedBinding, binding.accountID == sync.account?.id {
                    if binding.snapshot.role == "owner" {
                        invitationSection(binding)
                    } else {
                        Section {
                            Text("Only the calendar owner can invite people or manage members.")
                        }
                    }
                }
            } else {
                Section {
                    Picker("Connection method", selection: $firstTimeSetup) {
                        Text("Connect job to server").tag(false)
                        Text("Initialize Sync server").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("metadata-sync-connection-method")
                    .disabled(sync.busy)
                    jobPicker
                    connectionFields
                }
                if sync.isPaused {
                    Section("Calendar sync") {
                        Text("Calendar sync is paused. Start it when you are ready to share saved metadata changes.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Start Calendar Sync") {
                            do { try startup.activateCalendarSync() }
                            catch { /* The controller keeps the precise failure message. */ }
                            activationMessage = startup.userFacingMessage
                        }
                        .disabled(startup.isTestSession || startup.requiresRelaunchAfterConflict
                                  || !startup.otherRunningCopies.isEmpty)
                        .accessibilityIdentifier("metadata-calendar-start")
                        if let activationMessage {
                            Text(activationMessage).textSelection(.enabled)
                        }
                    }
                }
                Section("Calendar on this Mac") {
                    if let binding = selectedBinding {
                        let activity = sync.activity(for: binding.jobID)
                        Label(activity.phase.title, systemImage: activity.phase.symbol)
                        Text("Linked to “\(binding.snapshot.name)”").font(.headline)
                        LabeledContent("Sync server", value: sync.state.accounts.first { $0.id == binding.accountID }?.address ?? "Unavailable")
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
                if sync.account?.registered == true, selectedBinding == nil {
                    Section("Use a saved server") {
                        serverPicker
                        calendarSetup
                    }
                }
                if let pending = sync.state.pendingReceive {
                    Section("Sync activation pending") {
                        Text("Finish linking “\(pending.duplicate.name)” to its downloaded calendar. Any saved copy stays paused until you enable it.")
                        Button("Finish Activating Sync") { sync.retryPendingReceive() }
                        Button("Cancel Pending Link") { sync.cancelPendingReceive() }
                    }
                }
                ForEach(sync.state.pendingMigrations.filter(\.isPending)) { journal in
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
            jobID = store.selectedJobID ?? store.jobs.first?.id
            if let job = store.jobs.first(where: { $0.id == jobID }) { calendarName = job.name }
            sync.selectProtocol(.templates)
            selectJobServer()
            selectSuggestedCalendar()
        }
        .onDisappear { setupKey = ""; invite = ""; sync.invitation = ""; sync.migrationProposal = nil }
        .onChange(of: calendarID) { _, _ in sync.clearSharingDetails() }
        .onChange(of: jobID) { _, id in
            store.selectedJobID = id
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
        .onChange(of: sync.state.activeAccountID) { _, _ in
            address = sync.account?.address ?? savedAddress
            calendarID = nil
            hasChosenCalendar = false
            selectSuggestedCalendar()
        }
        .sheet(isPresented: $showDiagnostics) { MetadataSyncDiagnosticsView(jobID: jobID) }
        .onChange(of: sync.receivedJobID) { _, id in
            if let id { jobID = id }
        }
        .sheet(item: $sync.receiveProposal) { proposal in
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
        .sheet(item: $sync.migrationProposal) { journal in
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
        Picker("Saved server", selection: Binding(get: { sync.state.activeAccountID }, set: { if let id = $0 { sync.selectAccount(id) } })) {
            ForEach(sync.state.accounts) { account in
                Text(account.address + (account.registered ? " · \(sync.state.bindings.filter { $0.accountID == account.id }.count) jobs" : " (setup pending)")).tag(Optional(account.id))
            }
        }.disabled(sync.busy)
    }

    private var jobPicker: some View {
        Picker("Sync Job", selection: $jobID) {
            Text("Select a job").tag(nil as UUID?)
            ForEach(store.jobs) { job in Text(job.name).tag(Optional(job.id)) }
        }.disabled(sync.busy)
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if firstTimeSetup {
                Text("Initialize a newly installed 3.0 sync server, then create a calendar for this job.")
                    .foregroundStyle(.secondary)
                serverAddressField
                SecureField("Temporary setup key", text: $setupKey)
                Text("Enable first-device setup in the private server configuration, then enter its setup key.")
                    .foregroundStyle(.secondary)
                Button("Initialize Server") {
                    calendarID = nil
                    hasChosenCalendar = true
                    sync.register(address: address, deviceName: deviceName, setupKey: setupKey, invite: nil, protocolVersion: .templates)
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
                Button("Connect Job") {
                    sync.register(address: address, deviceName: deviceName, setupKey: nil, invite: invite, protocolVersion: .templates, connectingJobID: jobID)
                    invite = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(jobID == nil || invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceName.isEmpty)
            }
        }
        .disabled(sync.busy || sync.isPaused)
        .padding(.vertical, 8)
        .onChange(of: firstTimeSetup) { _, _ in setupKey = ""; invite = "" }
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
            Button("Activate Sync") {
                guard let jobID else { return }
                if let calendarID { sync.attach(calendarID: calendarID, jobID: jobID, protocolVersion: .templates) }
                else { sync.publish(jobID: jobID, name: calendarName, range: nil, protocolVersion: .templates) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(sync.busy || jobID == nil || activationUnavailable)
            Text("Saved edits sync shortly after editing; updates from other Macs are checked about every 10 seconds while the app is open. Only calendar metadata is shared; file transfer settings, passwords and work hours stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activationUnavailable: Bool {
        if let calendarID {
            return selectedCalendar == nil || sync.state.bindings.contains { $0.id == calendarID && $0.accountID == sync.account?.id }
        }
        return selectedBinding != nil || calendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func invitationSection(_ binding: MetadataCalendarBinding) -> some View {
        Section("Invite another Mac") {
            Picker("Permission", selection: $role) {
                Text("Can edit").tag("editor")
                Text("Read only").tag("reader")
            }
            dateRangeControls(limited: $inviteLimited, start: $inviteStart, end: $inviteEnd)
            Button("Create Invitation") { sync.createInvite(calendarID: binding.id, role: role, range: invitationRange) }
                .disabled(sync.busy || invitationRange.map { $0.end <= $0.start } == true)
            if !sync.invitation.isEmpty {
                Toggle("Include server URL (recommended)", isOn: $includeServerAddress)
                Button(includeServerAddress ? "Copy Invitation & Server URL" : "Copy Invitation Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MetadataSyncInvitation.copyText(
                        token: sync.invitation, address: includeServerAddress ? sync.account?.address : nil,
                        protocolVersion: binding.snapshot.compatibility.protocolVersion), forType: .string)
                }
                Text("Send this invitation privately. It works for one Mac and expires after 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Members") {
            Button("Show Members") { sync.manageMembers(calendarID: binding.id) }.disabled(sync.busy)
            ForEach(sync.members) { member in
                HStack {
                    Text("\(member.name) · \(member.role)")
                    Spacer()
                    if member.role != "owner" {
                        Button("Revoke Access", role: .destructive) { sync.manageMembers(calendarID: binding.id, revoke: member.id) }.disabled(sync.busy)
                    }
                }
            }
            Button("Revoke All Invitations", role: .destructive) { sync.manageMembers(calendarID: binding.id, revokeInvites: true) }.disabled(sync.busy)
            Text("Revocation stops future sync. Previously downloaded metadata remains on the recipient’s device.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func selectJobServer() {
        guard let binding = selectedBinding else { return }
        if sync.account?.id != binding.accountID { sync.selectAccount(binding.accountID) }
    }

    private func selectSuggestedCalendar() {
        if let binding = selectedBinding, binding.accountID == sync.account?.id,
           binding.snapshot.compatibility.protocolVersion == sync.discoveryProtocol { calendarID = binding.id }
        else if !hasChosenCalendar {
            calendarID = availableCalendars.first(where: { $0.id == sync.suggestedCalendarID })?.id
                ?? (availableCalendars.count == 1 ? availableCalendars[0].id : nil)
        } else if let calendarID, !sync.calendars.contains(where: { $0.id == calendarID }) {
            self.calendarID = nil
        }
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
