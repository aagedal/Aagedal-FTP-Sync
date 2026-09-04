import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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
        // MenuBarExtra windows do not propose an intrinsic height to ScrollView.
        // A max height alone therefore lets the list collapse to zero, hiding every job row.
        .frame(height: min(CGFloat(store.jobs.count) * 82, 360))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Menu {
                Button("Start All", systemImage: "play.fill") { store.startAll() }
                Button("Stop All", systemImage: "stop.fill") { store.stopAll() }
            } label: {
                Image(systemName: "playpause.fill")
            }
            .menuStyle(.borderlessButton)
            .help("All Jobs")
            .accessibilityLabel("All Jobs")
            .accessibilityHint("Starts or stops every sync job")
            Spacer()
            Button { openJobsWindow(adding: false) } label: {
                Image(systemName: "rectangle.stack")
            }
                .buttonStyle(.plain)
                .help("Jobs")
                .accessibilityLabel("Jobs")
                .accessibilityHint("Opens the sync jobs window")
                .accessibilityIdentifier("open-jobs-window")
            Button { openSettingsWindow() } label: {
                Image(systemName: "gearshape")
            }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens server and photographer settings")
            Button {
                RegularWindowController.shared.prepareForOpening(windowID: "about")
                openWindow(id: "about")
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("About")
            .accessibilityLabel("About")
            .accessibilityHint("Opens information about Aagedal FTP Sync")
            Button(action: confirmQuit) {
                Image(systemName: "power")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Quit")
            .accessibilityLabel("Quit")
            .accessibilityHint("Asks for confirmation before quitting")
        }
        .padding(12)
    }

    private func openJobsWindow(adding: Bool) {
        if adding { store.requestNewJobDraft() }
        RegularWindowController.shared.prepareForOpening(windowID: "jobs")
        openWindow(id: "jobs")
    }

    private func openSettingsWindow() {
        RegularWindowController.shared.prepareForOpening()
        openSettings()
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Quit Aagedal FTP Sync?"
        alert.informativeText = "Automatic sync jobs will stop until you open the app again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct MenuJobRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var showQuickControls = false
    let job: SyncJob
    let phase: JobPhase

    var body: some View {
        HStack(spacing: 10) {
            Button { store.runNow(job.id) } label: {
                Image(systemName: phase == .syncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(phase == .syncing)
            .help("Sync Now")
            .accessibilityLabel("Sync \(job.name) Now")
            .accessibilityHint("Starts this sync job immediately")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(job.name).fontWeight(.medium).lineLimit(1)
                    Image(systemName: job.direction.symbol).font(.caption).foregroundStyle(.secondary)
                }
                Text(phase.label)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .help(phase.label)
                if case .failed = phase {
                    Button("View error details…", action: openJobSettings)
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                } else {
                    Text(activityLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { showQuickControls.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Quick Controls")
            .accessibilityLabel("Quick Controls for \(job.name)")
            .accessibilityHint("Opens automatic-sync and scheduling controls")
            .popover(isPresented: $showQuickControls, arrowEdge: .trailing) {
                JobQuickControls(job: job)
                    .environmentObject(store)
            }
            Button {
                store.selectedJobID = job.id
                RegularWindowController.shared.prepareForOpening(windowID: "metadata-programming")
                openWindow(id: "metadata-programming")
            } label: {
                Image(systemName: "tag")
            }
            .buttonStyle(.plain)
            .help("Metadata Programming")
            .accessibilityLabel("Metadata Programming for \(job.name)")
            .accessibilityHint("Opens the metadata schedule for this job")
            Button {
                store.revealDownloadFolder(for: job)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .disabled(job.localDestinationDisplayPath == nil)
            .help(
                job.localDestinationDisplayPath == nil
                    ? "No Local Download Folder"
                    : "Reveal Download Folder in Finder"
            )
            .accessibilityLabel("Reveal Download Folder in Finder")
            .accessibilityHint("Opens this job’s local download folder")
            Button {
                store.setEnabled(!job.isEnabled, for: job.id)
            } label: {
                Label(
                    job.isEnabled ? "Stop" : "Start",
                    systemImage: job.isEnabled ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .tint(job.isEnabled ? Color.red : Color.green)
            .help(job.isEnabled ? "Stop Automatic Sync" : "Start Automatic Sync")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func openJobSettings() {
        store.selectedJobID = job.id
        RegularWindowController.shared.prepareForOpening(windowID: "jobs")
        openWindow(id: "jobs")
    }

    private var statusColor: Color {
        if case .failed = phase { return .red }
        if case .succeeded(_, _, _, _, let conflicts, let metadataReport, _) = phase,
           !conflicts.isEmpty || metadataReport.failed > 0 {
            return .orange
        }
        return .secondary
    }

    private var activityLabel: String {
        let count = store.transferredFileCount(for: job.id)
        let files = count == 1 ? "1 file" : "\(count) files"
        if job.showsLatestSessionTransferCountOnly {
            return "\(files) synced in latest session"
        }
        return "\(files) synced since job started"
    }

}

private struct LocalFolderShortcut: Identifiable {
    let title: String
    let endpoint: Endpoint

    var id: String { title }
}

private extension SyncJob {
    var localFolderShortcuts: [LocalFolderShortcut] {
        switch direction {
        case .leftToRight:
            return localShortcuts(source: left, destination: right)
        case .rightToLeft:
            return localShortcuts(source: right, destination: left)
        case .bidirectional:
            return [
                localShortcut(title: "Open Location A", endpoint: left),
                localShortcut(title: "Open Location B", endpoint: right),
            ].compactMap { $0 }
        }
    }

    private func localShortcuts(source: Endpoint, destination: Endpoint) -> [LocalFolderShortcut] {
        [
            localShortcut(title: "Open Source Folder", endpoint: source),
            localShortcut(title: "Open Destination Folder", endpoint: destination),
        ].compactMap { $0 }
    }

    private func localShortcut(title: String, endpoint: Endpoint) -> LocalFolderShortcut? {
        guard endpoint.kind == .local else { return nil }
        return LocalFolderShortcut(title: title, endpoint: endpoint)
    }
}

private struct JobQuickControls: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let job: SyncJob
    @State private var intervalSeconds: Double
    @State private var ageIndex: Double
    @State private var intervalWasEdited = false
    @State private var ageWasEdited = false

    private static let ageOptions: [Int?] = [nil, 1, 3, 6, 12, 24, 48, 168]

    init(job: SyncJob) {
        self.job = job
        _intervalSeconds = State(initialValue: job.intervalSeconds)
        let index = Self.ageOptions.firstIndex(of: job.filter.recentHours) ?? 0
        _ageIndex = State(initialValue: Double(index))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentJob.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(currentJob.isEnabled ? "Automatic sync is running" : "Automatic sync is paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: currentJob.isEnabled ? "play.fill" : "pause.fill")
                    .foregroundStyle(currentJob.isEnabled ? .green : .secondary)
            }

            Divider()

            HStack(spacing: 12) {
                localFolderControl
                Button(action: openJobSettings) {
                    Label("Job Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }

            Picker("File type", selection: filterBinding) {
                ForEach(FilterPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Sync frequency")
                    Spacer()
                    Text(intervalLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $intervalSeconds,
                    in: 2...300,
                    step: 1,
                    onEditingChanged: { editing in
                        if editing { intervalWasEdited = true }
                        if !editing { commitInterval() }
                    }
                )
                HStack {
                    Text("2 sec")
                    Spacer()
                    Text("5 min")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("File age")
                    Spacer()
                    Text(ageLabel)
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $ageIndex,
                    in: 0...Double(Self.ageOptions.count - 1),
                    step: 1,
                    onEditingChanged: { editing in
                        if editing { ageWasEdited = true }
                        if !editing { commitFileAge() }
                    }
                )
                HStack {
                    Text("Any age")
                    Spacer()
                    Text("7 days")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onDisappear {
            commitInterval()
            commitFileAge()
        }
    }

    private var filterBinding: Binding<FilterPreset> {
        Binding(
            get: { currentJob.filter.preset },
            set: { store.updateFilter(jobID: job.id, preset: $0) }
        )
    }

    @ViewBuilder
    private var localFolderControl: some View {
        let shortcuts = currentJob.localFolderShortcuts
        if shortcuts.count == 1, let shortcut = shortcuts.first {
            Button {
                store.openLocalFolder(shortcut.endpoint)
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .help(shortcut.title)
        } else if shortcuts.count > 1 {
            Menu {
                ForEach(shortcuts) { shortcut in
                    Button(shortcut.title, systemImage: "folder") {
                        store.openLocalFolder(shortcut.endpoint)
                    }
                }
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open Local Folder")
        }
    }

    private func openJobSettings() {
        store.selectedJobID = job.id
        RegularWindowController.shared.prepareForOpening(windowID: "jobs")
        openWindow(id: "jobs")
    }

    private var currentJob: SyncJob {
        store.jobs.first(where: { $0.id == job.id }) ?? job
    }

    private var intervalLabel: String {
        let seconds = Int(intervalSeconds)
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes)m \(remainder)s"
    }

    private var selectedAge: Int? {
        let index = min(max(Int(ageIndex.rounded()), 0), Self.ageOptions.count - 1)
        return Self.ageOptions[index]
    }

    private var ageLabel: String {
        guard let hours = selectedAge else { return "Any age" }
        if hours == 1 { return "Last hour" }
        if hours.isMultiple(of: 24) {
            let days = hours / 24
            return days == 1 ? "Last day" : "Last \(days) days"
        }
        return "Last \(hours) hours"
    }

    private func commitInterval() {
        guard intervalWasEdited else { return }
        intervalWasEdited = false
        guard abs(currentJob.intervalSeconds - intervalSeconds) > 0.001 else { return }
        store.updateInterval(jobID: job.id, seconds: intervalSeconds)
    }

    private func commitFileAge() {
        guard ageWasEdited else { return }
        ageWasEdited = false
        guard currentJob.filter.recentHours != selectedAge else { return }
        store.updateFileAge(jobID: job.id, recentHours: selectedAge)
    }
}
