import AppKit
import SwiftUI

struct MetadataCalendarSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    @AppStorage("metadataSync.serverURL") private var savedAddress = ""
    @State private var address = ""
    @State private var deviceName = Host.current().localizedName ?? "My Mac"
    @State private var setupKey = ""
    @State private var invite = ""
    @State private var calendarName = "Shared calendar"
    @State private var jobID: UUID?
    @State private var calendarID: UUID?
    @State private var limited = false
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.startOfDay(for: Date())
    @State private var role = "editor"
    @State private var resolution: MetadataCalendarConflictReview?
    @State private var reviewError: String?
    @State private var hasChosenCalendar = false
    @State private var showDiagnostics = false
    @State private var inviteLimited = false
    @State private var inviteStart = Calendar.current.startOfDay(for: Date())
    @State private var inviteEnd = Calendar.current.startOfDay(for: Date())
    @State private var migrationToAbandon: MetadataCalendarMigrationJournal?


    private var selectedBinding: MetadataCalendarBinding? { sync.binding(for: jobID) }
    private var selectedCalendar: MetadataCalendarSummary? { sync.calendars.first { $0.id == calendarID } }
    private var invitationRange: MetadataSharingRange? {
        dateRange(limited: inviteLimited, start: inviteStart, end: inviteEnd,
                  zone: selectedBinding?.snapshot.timeZone ?? TimeZone.current.identifier)
    }
    private var publicationRange: MetadataSharingRange? {
        dateRange(limited: limited, start: start, end: end, zone: TimeZone.current.identifier)
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
            Section("Calendar type") {
                Picker("Browse and create", selection: Binding(get: { sync.discoveryProtocol }, set: { sync.selectProtocol($0) })) {
                    Text("Classic — compatible with 2.x").tag(MetadataCalendarProtocol.legacy)
                    Text("Template-enabled — requires 3.0").tag(MetadataCalendarProtocol.templates)
                }.disabled(sync.busy)
                Text(sync.discoveryProtocol == .templates
                     ? "Template-enabled calendars require an upgraded server and 3.0 on every participating Mac. They are separate calendars; existing classic calendars are not converted or mirrored."
                     : "Classic calendars keep text literal, including braces. Choose template-enabled when creating a new calendar that will use metadata variables.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Calendar on this Mac") {
                Picker("Local job", selection: $jobID) {
                    Text("Select a job").tag(nil as UUID?)
                    ForEach(store.jobs) { job in Text(job.name).tag(Optional(job.id)) }
                }
                if let binding = selectedBinding {
                    let activity = sync.activity(for: binding.jobID)
                    Label(activity.phase.title, systemImage: activity.phase.symbol)
                    Text("Linked to “\(binding.snapshot.name)”").font(.headline)
                    Text(binding.snapshot.compatibility == .templates ? "Template-enabled calendar" : "Classic calendar")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(activity.detail).textSelection(.enabled)
                    if let date = activity.lastSuccess { Text("Last successful sync: \(date.formatted())").font(.caption) }
                    Button(activity.phase == .offline || activity.phase == .failed ? "Retry Now" : "Sync Now") {
                        Task { await sync.refresh(jobID: binding.jobID) }
                    }.disabled(activity.phase.isActive)
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
                    DisclosureGroup("Stop sharing this job") {
                        Button("Detach and Keep Local Metadata") { sync.detach(binding) }.disabled(sync.busy)
                    }
                } else {
                    Label("Calendar sync is off for this job", systemImage: "icloud.slash")
                    Text("Choose a shared calendar or create one from this job, then activate sync.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Saved changes sync shortly after editing. Updates from other Macs are checked about every 10 seconds while the app is running. Offline edits are kept on this Mac and retried automatically, even when automatic file transfers are off.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("View Sync Activity & Errors…") { showDiagnostics = true }
            }
            if sync.account?.registered == true {
                Section("Server") {
                    LabeledContent("Connected", value: sync.account?.address ?? "")
                    DisclosureGroup("Join another invitation or connect another server") { connectionFields }
                    if sync.state.accounts.count > 1 { serverPicker }
                }
                Section {
                    if selectedBinding == nil {
                        calendarSetup
                    } else {
                        DisclosureGroup("Link another calendar") { calendarSetup }
                    }
                }
                if let binding = selectedBinding, binding.snapshot.role == "owner",
                   binding.accountID == sync.account?.id {
                    invitationSection(binding)
                }
            } else {
                Section("1. Connect") {
                    Text("Joining someone’s calendar only needs their invitation. First-device setup is for the server administrator.")
                        .font(.caption).foregroundStyle(.secondary)
                    connectionFields
                    if !sync.state.accounts.isEmpty { serverPicker }
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
            if !sync.message.isEmpty { Text(sync.message).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .overlay(alignment: .topTrailing) {
            if sync.busy {
                HStack { ProgressView().controlSize(.small); Text(sync.currentOperation ?? "Updating…").font(.caption) }
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
            }
        }
        .onAppear {
            address = sync.account?.address ?? savedAddress
            jobID = store.selectedJobID ?? store.jobs.first?.id
            selectSuggestedCalendar()
        }
        .onDisappear { setupKey = ""; invite = ""; sync.invitation = ""; sync.migrationProposal = nil }
        .onChange(of: calendarID) { _, _ in sync.clearSharingDetails() }
        .onChange(of: jobID) { _, id in
            sync.clearSharingDetails()
            hasChosenCalendar = false
            if let job = store.jobs.first(where: { $0.id == id }) { calendarName = job.name }
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
                Text(account.address + (account.registered ? "" : " (setup pending)")).tag(Optional(account.id))
            }
        }.disabled(sync.busy)
    }

    private var connectionFields: some View {
        Group {
            TextField("Server URL", text: $address, prompt: Text("https://sync.example.com/"))
            TextField("This Mac’s name", text: $deviceName)
            SecureField("Paste invitation", text: $invite)
            Text("Paste the whole copied invitation, including its server address, or enter the address and invitation code separately.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Join Calendar") {
                sync.register(address: address, deviceName: deviceName, setupKey: nil, invite: invite, protocolVersion: sync.discoveryProtocol)
                invite = ""
            }.disabled(sync.busy || invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceName.isEmpty)
            DisclosureGroup("Server administrator: connect the first Mac") {
                SecureField("Temporary setup key", text: $setupKey)
                Text("Enable first-device setup in the private server configuration, then connect with its setup key.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Connect First Mac") {
                    calendarID = nil
                    hasChosenCalendar = true
                    sync.register(address: address, deviceName: deviceName, setupKey: setupKey, invite: nil, protocolVersion: sync.discoveryProtocol)
                    setupKey = ""
                }.disabled(sync.busy || setupKey.isEmpty || address.isEmpty || deviceName.isEmpty)
            }
        }
    }

    private var calendarSetup: some View {
        Group {
            Picker("Calendar to sync", selection: Binding(get: { calendarID }, set: {
                calendarID = $0
                hasChosenCalendar = true
            })) {
                Text("New shared calendar from this job").tag(nil as UUID?)
                ForEach(sync.calendars) { calendar in Text(calendar.name).tag(Optional(calendar.id)) }
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
                dateRangeControls(limited: $limited, start: $start, end: $end)
                Text("Creates a shared calendar using this job’s programming. Once another Mac joins and activates sync, saved changes sync both ways.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Activate Sync") {
                guard let jobID else { return }
                if let calendarID { sync.attach(calendarID: calendarID, jobID: jobID, protocolVersion: sync.discoveryProtocol) }
                else { sync.publish(jobID: jobID, name: calendarName, range: publicationRange, protocolVersion: sync.discoveryProtocol) }
            }.disabled(sync.busy || jobID == nil || activationUnavailable)
            Text("Saved edits sync shortly after editing; updates from other Macs are checked about every 10 seconds while the app is open. Only calendar metadata is shared; file transfer settings, passwords and work hours stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activationUnavailable: Bool {
        if let calendarID {
            return selectedCalendar == nil || sync.state.bindings.contains { $0.id == calendarID && $0.accountID == sync.account?.id }
        }
        return selectedBinding != nil || calendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            publicationRange.map { $0.end <= $0.start } == true
    }

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
                Button("Copy Invitation") {
                    NSPasteboard.general.clearContents()
                    let prefix = binding.snapshot.compatibility == .templates ? "Aagedal template calendar invitation\n" : ""
                    NSPasteboard.general.setString(prefix + "Server: \(sync.account?.address ?? "")\nInvitation: \(sync.invitation)", forType: .string)
                }
                Text("Send this invitation privately. It works for one Mac and expires after 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Manage access") {
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
    }

    private func selectSuggestedCalendar() {
        if let binding = selectedBinding, binding.accountID == sync.account?.id,
           binding.snapshot.compatibility.protocolVersion == sync.discoveryProtocol { calendarID = binding.id }
        else if !hasChosenCalendar {
            calendarID = sync.suggestedCalendarID ?? (sync.calendars.count == 1 ? sync.calendars[0].id : nil)
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
