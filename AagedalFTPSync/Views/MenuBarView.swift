import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty { emptyState }
            else { jobList }
            Divider()
            footer
        }
        .frame(width: 390)
        .alert("Aagedal FTP Sync", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aagedal FTP Sync").font(.headline)
                Text(store.activeCount == 1 ? "1 active job" : "\(store.activeCount) active jobs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isSyncing { ProgressView().controlSize(.small) }
        }
        .padding(16)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No sync jobs", systemImage: "folder.badge.plus")
        } description: {
            Text("Connect a server or choose two local folders.")
        } actions: {
            Button("Create Sync Job") { openJobsWindow(adding: true) }
                .buttonStyle(.borderedProminent)
        }
        .frame(height: 210)
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.jobs) { job in
                    MenuJobRow(job: job, phase: store.phases[job.id] ?? .stopped)
                    Divider().padding(.leading, 16)
                }
            }
        }
        .frame(maxHeight: 360)
    }

    private var footer: some View {
        HStack {
            Menu("All Jobs") {
                Button("Start All", systemImage: "play.fill") { store.startAll() }
                Button("Stop All", systemImage: "stop.fill") { store.stopAll() }
            }
            .menuStyle(.borderlessButton)
            Spacer()
            Button("Settings…") { openJobsWindow(adding: false) }
                .buttonStyle(.plain)
            Button("About") {
                openWindow(id: "about")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(12)
    }

    private func openJobsWindow(adding: Bool) {
        if adding { _ = store.addJob() }
        openWindow(id: "jobs")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct MenuJobRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let job: SyncJob
    let phase: JobPhase

    var body: some View {
        HStack(spacing: 10) {
            Button { store.runNow(job.id) } label: {
                Image(systemName: phase == .syncing ? "arrow.triangle.2.circlepath" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(phase == .syncing)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(job.name).fontWeight(.medium).lineLimit(1)
                    Image(systemName: job.direction.symbol).font(.caption).foregroundStyle(.secondary)
                }
                Text(phase.label).font(.caption).foregroundStyle(statusColor).lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(FilterPreset.allCases) { preset in
                    Button {
                        store.updateFilter(jobID: job.id, preset: preset)
                    } label: {
                        if preset == job.filter.preset { Label(preset.title, systemImage: "checkmark") }
                        else { Text(preset.title) }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Quick file filter")
            Toggle("", isOn: Binding(
                get: { job.isEnabled },
                set: { store.setEnabled($0, for: job.id) }
            ))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            Button {
                openWindow(id: "jobs")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var statusColor: Color {
        if case .failed = phase { return .red }
        return .secondary
    }
}
