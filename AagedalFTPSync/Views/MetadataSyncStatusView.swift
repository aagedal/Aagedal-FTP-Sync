import AppKit
import SwiftUI

struct MetadataSyncStatusView: View {
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    let jobID: UUID?
    var beforeSync: () -> Void = {}
    var openSettings: () -> Void
    @State private var showDetails = false
    @State private var showDiagnostics = false

    private var binding: MetadataCalendarBinding? { sync.binding(for: jobID) }
    private var activity: MetadataSyncActivity { jobID.map { sync.activity(for: $0) } ?? MetadataSyncActivity() }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if binding == nil { openSettings() } else { showDetails = true }
            } label: {
                HStack(spacing: 7) {
                    if binding != nil && activity.phase.isActive { ProgressView().controlSize(.small) }
                    Label(binding == nil ? "Calendar sync off" : activity.phase.title,
                          systemImage: binding == nil ? "icloud.slash" : activity.phase.symbol)
                    if let binding { Text(binding.snapshot.name).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("metadata-sync-status")
            .popover(isPresented: $showDetails) { details.padding(20).frame(width: 390) }
            Spacer()
            if let jobID, binding != nil {
                Button("Sync Now") {
                    beforeSync()
                    Task { await sync.refresh(jobID: jobID) }
                }.disabled(sync.busy)
            }
            Button { showDiagnostics = true } label: {
                Label("Sync Activity…", systemImage: "list.bullet.rectangle")
            }.accessibilityIdentifier("metadata-sync-activity")
            Button(binding == nil ? "Activate Sync…" : "Manage Sync…", action: openSettings)
                .accessibilityIdentifier("metadata-sharing-sync")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showDiagnostics) { MetadataSyncDiagnosticsView(jobID: jobID) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(activity.phase.title).font(.headline)
            Text(activity.detail).textSelection(.enabled)
            if let binding {
                Text(binding.snapshot.role == "reader" ? "Read-only calendar" : "Saved edits are shared with other editors.")
                Text(binding.range == nil ? "Sharing the entire calendar" : "Sharing a selected date range")
                    .foregroundStyle(.secondary)
            }
            if let date = activity.lastSuccess {
                HStack { Text("Last successful sync:"); Text(date, style: .relative); Text("ago") }
                    .font(.caption)
            }
            Text("Saved changes sync about every 10 seconds while the app is open, even when automatic file transfers are off. Offline edits sync after reconnecting.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("View Activity & Errors…") { showDetails = false; showDiagnostics = true }
                Button("Open Sync Settings…") { showDetails = false; openSettings() }
            }
        }
    }
}

struct MetadataSyncDiagnosticsView: View {
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    @Environment(\.dismiss) private var dismiss
    var jobID: UUID? = nil
    @State private var errorsOnly = false
    private var events: [MetadataSyncEvent] {
        sync.events.reversed().filter {
            (jobID == nil || $0.jobID == jobID || $0.jobID == nil) && (!errorsOnly || $0.isError)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Calendar Sync Activity").font(.title2)
                Spacer()
                Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
            }
            Text("Recent activity is saved on this Mac. Copied diagnostics exclude calendar content, server addresses and credentials.")
                .font(.caption).foregroundStyle(.secondary)
            if !sync.eventStorageError.isEmpty { Text(sync.eventStorageError).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if events.isEmpty { Text("No sync activity recorded yet.").foregroundStyle(.secondary) }
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(event.operation, systemImage: event.isError ? "exclamationmark.triangle" : "checkmark.circle")
                                Spacer()
                                Text(event.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                            }
                            Text(event.detail)
                            if let revision = event.revision { Text("Revision \(revision)").font(.caption).foregroundStyle(.secondary) }
                            if event.occurrences > 1 { Text("Repeated \(event.occurrences) times").font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sync.diagnosticText(jobID: jobID), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 700, height: 480)
    }
}
