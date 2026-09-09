import AppKit
import SwiftUI

struct MetadataCalendarSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    @AppStorage("metadataSync.serverURL") private var savedAddress = ""
    @State private var address = ""
    @State private var deviceName = "My Mac"
    @State private var setupKey = ""
    @State private var invite = ""
    @State private var calendarName = "Shared calendar"
    @State private var jobID: UUID?
    @State private var calendarID: UUID?
    @State private var limited = false
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.startOfDay(for: Date())
    @State private var role = "editor"
    @State private var resolution: MetadataCalendarBinding?

    private var range: MetadataSharingRange? {
        guard limited else { return nil }
        return range(in: selectedCalendar?.timeZone ?? TimeZone.current.identifier)
    }
    private func range(in zone: String) -> MetadataSharingRange? {
        guard limited else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let first = calendar.date(from: Calendar.current.dateComponents([.year, .month, .day], from: start)) ?? start
        let last = calendar.date(from: Calendar.current.dateComponents([.year, .month, .day], from: end)) ?? end
        return MetadataSharingRange(start: first, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }
    private var validRange: Bool { range.map { $0.end > $0.start } ?? true }
    private var selectedCalendar: MetadataCalendarSummary? { sync.calendars.first { $0.id == calendarID } }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Server URL", text: $address, prompt: Text("https://sync.example.com/"))
                TextField("Device name", text: $deviceName)
                SecureField("Invitation", text: $invite)
                Button("Join with Invitation") {
                    sync.register(address: address, deviceName: deviceName, setupKey: nil, invite: invite)
                    invite = ""
                }.disabled(invite.isEmpty || address.isEmpty || deviceName.isEmpty)
                DisclosureGroup("First device on a new server") {
                    SecureField("Temporary setup key", text: $setupKey)
                    Text("The server administrator must enable bootstrap in the private configuration. Subsequent devices join using invitations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Register First Device") {
                        sync.register(address: address, deviceName: deviceName, setupKey: setupKey, invite: nil)
                        setupKey = ""
                    }.disabled(setupKey.isEmpty || address.isEmpty || deviceName.isEmpty)
                }
                if !sync.state.accounts.isEmpty {
                    Picker("Saved server", selection: Binding(get: { sync.state.activeAccountID }, set: { if let id = $0 { sync.selectAccount(id) } })) {
                        ForEach(sync.state.accounts) { account in
                            Text(account.address + (account.registered ? "" : " (setup pending)")).tag(Optional(account.id))
                        }
                    }
                    if sync.account?.registered == false {
                        Text("Setup is pending because device registration has not completed. After correcting the server setup, retry registration using the same server URL; the saved device identity will be reused.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Device keys are saved in Keychain. Sync runs about every 10 seconds while the app is running. Saved offline edits are sent after reconnecting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sync.account?.registered == true {
                Section("Calendars") {
                    Picker("Local job", selection: $jobID) {
                        Text("Select a job").tag(nil as UUID?)
                        ForEach(store.jobs) { job in Text(job.name).tag(Optional(job.id)) }
                    }
                    TextField("New calendar name", text: $calendarName)
                    rangeControls
                    Button("Publish Job’s Metadata Calendar") {
                        if let jobID { sync.publish(jobID: jobID, name: calendarName, range: range(in: TimeZone.current.identifier)) }
                    }.disabled(jobID == nil || calendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !validRange)
                    Text("Publishing shares photographer names and initials, copyright, clip text, times, keywords and locations. FTP settings, processing policies and work hours stay on this Mac. A job can link to one calendar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Server calendar", selection: $calendarID) {
                        Text("Select a calendar").tag(nil as UUID?)
                        ForEach(sync.calendars) { calendar in
                            Text("\(calendar.name) (\(calendar.role))").tag(Optional(calendar.id))
                        }
                    }
                    if let selectedCalendar {
                        Text("Calendar time zone: \(selectedCalendar.timeZone)").font(.caption)
                    }
                    Button("Receive Calendar…") {
                        if let calendarID, let jobID { sync.attach(calendarID: calendarID, jobID: jobID) }
                    }.disabled(calendarID == nil || jobID == nil)
                    Text("If this job already has metadata programming or a calendar link, you can receive into a copy and disable automatic running of the original.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sync Now") { Task { await sync.refresh() } }
                }
                if selectedCalendar?.role == "owner", let calendarID {
                    Section("Share Selected Calendar") {
                        Picker("Permission", selection: $role) {
                            Text("Can edit").tag("editor")
                            Text("Read only").tag("reader")
                        }
                        Text(limited ? "Invitation uses the date range above." : "Invitation shares the entire calendar.")
                        Button("Create Invitation") { sync.createInvite(calendarID: calendarID, role: role, range: range) }.disabled(!validRange)
                        if !sync.invitation.isEmpty {
                            SecureField("New invitation", text: $sync.invitation)
                            Button("Copy Server URL and Invitation") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("Server: \(sync.account?.address ?? "")\nInvitation: \(sync.invitation)", forType: .string)
                            }
                        }
                        Button("Show Members") { sync.manageMembers(calendarID: calendarID) }
                        ForEach(sync.members) { member in
                            HStack {
                                Text("\(member.name) · \(member.role)")
                                Spacer()
                                if member.role != "owner" {
                                    Button("Revoke Access", role: .destructive) { sync.manageMembers(calendarID: calendarID, revoke: member.id) }
                                }
                            }
                        }
                        Button("Revoke All Invitations", role: .destructive) { sync.manageMembers(calendarID: calendarID, revokeInvites: true) }
                        Text("Revocation stops future sync. Previously downloaded metadata remains on the recipient’s device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let pending = sync.state.pendingReceive {
                Section("Receive pending") {
                    Text("Finish linking “\(pending.duplicate.name)” to its downloaded calendar. Any saved copy stays paused until you enable it.")
                    Button("Finish Receiving") { sync.retryPendingReceive() }
                    Button("Cancel Pending Link") { sync.cancelPendingReceive() }
                }
            }
            ForEach(sync.state.bindings) { binding in
                Section(binding.snapshot.name) {
                    Text(store.jobs.first(where: { $0.id == binding.jobID })?.name ?? "Missing local job")
                    Text(sync.bindingMessages[binding.id] ?? "Waiting to sync")
                    if let conflict = binding.conflict {
                        Text("Conflict with server revision \(conflict.revision). Both versions are retained until you choose a resolution.")
                        Button("Resolve Conflict…") { resolution = binding }
                    }
                    Button("Detach and Keep Local Metadata") { sync.detach(binding) }
                }
            }
            if !sync.message.isEmpty { Text(sync.message).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .disabled(sync.busy)
        .overlay(alignment: .topTrailing) { if sync.busy { ProgressView().controlSize(.small).padding() } }
        .onAppear { address = sync.account?.address ?? savedAddress; jobID = store.selectedJobID }
        .onDisappear { setupKey = ""; invite = ""; sync.invitation = "" }
        .onChange(of: calendarID) { _, _ in sync.clearSharingDetails() }
        .onChange(of: sync.receivedJobID) { _, id in
            if let id { jobID = id }
        }
        .sheet(item: $sync.receiveProposal) { proposal in
            VStack(alignment: .leading, spacing: 16) {
                Text("Receive into a copy?").font(.headline)
                Text("“\(proposal.source.name)” already has metadata programming or a calendar link.")
                Text("Create “\(proposal.duplicate.name)” with the same connections, folders and local processing settings, and receive “\(proposal.calendar.name)” into it (\(proposal.calendar.document.clips.count) clips). The copy gets only the calendar content shared with you.")
                Text("The original keeps its current calendar. Automatic running and startup at app launch will be disabled on the original. The new copy also starts paused so you can review it before enabling it.")
                if !sync.message.isEmpty { Text(sync.message).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel", role: .cancel) { sync.receiveProposal = nil }
                    Spacer()
                    Button("Duplicate and Receive") { sync.confirmReceive(proposal) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 570)
            .disabled(sync.busy)
        }
        .sheet(item: $resolution) { binding in
            VStack(alignment: .leading, spacing: 16) {
                Text("Resolve \(binding.snapshot.name)").font(.headline)
                Text("Choosing a version replaces the shared portion of this calendar. Detaching keeps your local version without sending it.")
                if let remote = binding.conflict {
                    Text("Server revision \(remote.revision): \(remote.document.clips.count) clips, \(remote.document.photographers.count) photographers.")
                    HStack(alignment: .top, spacing: 20) {
                        conflictPreview("Local version", document: SharedMetadataDocument(store.jobs.first(where: { $0.id == binding.jobID })?.metadataAutomation ?? MetadataAutomation()).restricted(to: binding.range, timeZone: binding.snapshot.timeZone))
                        conflictPreview("Server version", document: remote.document)
                    }.frame(height: 300)
                }
                HStack {
                    Button("Cancel") { resolution = nil }
                    Button("Use Server Version") { sync.resolve(binding, keepLocal: false); resolution = nil }
                    if binding.snapshot.role != "reader" {
                        Button("Keep Local Version") { sync.resolve(binding, keepLocal: true); resolution = nil }
                    }
                }
            }.padding().frame(width: 800)
        }
    }

    private func conflictPreview(_ title: String, document: SharedMetadataDocument) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(document.photographers) { profile in
                        Text("\(profile.creator) · \(profile.filenamePrefix)\n\(profile.copyrightNotice)")
                    }
                    ForEach(document.clips) { clip in
                        Text("\(clip.name)\n\(clip.startsAt.formatted()) – \(clip.endsAt.formatted())\n\(clip.fields.headline)\n\(clip.fields.description)\n\(clip.fields.keywords.joined(separator: ", "))")
                        if let gps = clip.gpsPosition {
                            Text("Location: \(gps.label ?? "") \(gps.latitude), \(gps.longitude)")
                        }
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rangeControls: some View {
        Group {
            Toggle("Limit to a date range", isOn: $limited)
            if limited {
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("Through", selection: $end, displayedComponents: .date)
                Text("Only clips entirely inside these dates are shared. Clips crossing a boundary are excluded. Date-range recipients can edit clips but cannot change photographer details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
