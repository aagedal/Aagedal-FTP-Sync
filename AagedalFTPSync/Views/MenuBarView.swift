import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty { emptyState }
            else { jobList }
            Divider()
            footer
        }
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 520 : 390)
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
        .frame(height: min(
            CGFloat(store.jobs.count) * (dynamicTypeSize.isAccessibilitySize ? 138 : 82),
            dynamicTypeSize.isAccessibilitySize ? 510 : 360
        ))
    }

    private var footer: some View {
        // Accessibility text sizes can outgrow the panel; fall back to icons,
        // which keep their names for VoiceOver and still show tooltips.
        ViewThatFits(in: .horizontal) {
            footerControls.labelStyle(.titleAndIcon)
            footerControls.labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(12)
    }

    private var footerControls: some View {
        HStack(spacing: 8) {
            Button { openJobsWindow(adding: false) } label: {
                Label("Sync Jobs", systemImage: "rectangle.stack")
            }
            .help("Create and edit sync jobs, folders and servers")
            .accessibilityHint("Opens the Sync Jobs window")
            .accessibilityIdentifier("open-jobs-window")

            Button(action: openMetadataWindow) {
                Label("Metadata", systemImage: "tag")
            }
            .disabled(store.jobs.isEmpty)
            .help(store.jobs.isEmpty
                ? "Create a sync job before programming metadata"
                : "Schedule captions, photographers and keywords")
            .accessibilityHint("Opens the Metadata Programming window")
            .accessibilityIdentifier("open-metadata-window")

            Button { openSettingsWindow() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Servers, photographers, shared calendars and app preferences")
            .accessibilityHint("Opens the Settings window")

            Spacer(minLength: 0)

            Menu {
                Button("Start All Jobs", systemImage: "play.fill") { store.startAll() }
                    .disabled(store.jobs.isEmpty)
                Button("Stop All Jobs", systemImage: "stop.fill") { store.stopAll() }
                    .disabled(store.jobs.isEmpty)
                Divider()
                Button("About Aagedal FTP Sync", systemImage: "info.circle") {
                    RegularWindowController.shared.prepareForOpening(windowID: "about")
                    openWindow(id: "about")
                }
                Divider()
                Button("Quit Aagedal FTP Sync…", systemImage: "power", action: confirmQuit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Start or stop all jobs, About and Quit")
            .accessibilityLabel("More")
            .accessibilityHint("Starts or stops every job, shows About or quits")
        }
    }

    private func openJobsWindow(adding: Bool) {
        if adding { store.requestNewJobDraft() }
        RegularWindowController.shared.prepareForOpening(windowID: "jobs")
        openWindow(id: "jobs")
    }

    private func openMetadataWindow() {
        if store.selectedJobID.flatMap({ id in store.jobs.first(where: { $0.id == id }) }) == nil {
            store.selectedJobID = store.jobs.first?.id
        }
        dismiss()
        DispatchQueue.main.async {
            RegularWindowController.shared.prepareForOpening(windowID: "metadata-programming")
            openWindow(id: "metadata-programming")
        }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showQuickControls = false
    let job: SyncJob
    let phase: JobPhase

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        syncButton
                        jobSummary
                        Spacer(minLength: 8)
                        automaticSyncButton
                    }
                    HStack(spacing: 18) {
                        Spacer()
                        quickControlsButton
                        folderButton
                    }
                }
            } else {
                HStack(spacing: 10) {
                    syncButton
                    jobSummary
                    Spacer()
                    quickControlsButton
                    folderButton
                    automaticSyncButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var syncButton: some View {
        Button { store.runNow(job.id) } label: {
            Image(systemName: phase == .syncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .disabled(store.isJobBusy(job.id))
        .help(store.resettingJobs.contains(job.id) ? "Wait for Reset Job to finish." : "Sync Now")
        .accessibilityLabel("Sync \(job.name) Now")
        .accessibilityHint("Starts this sync job immediately")
    }

    private var jobSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.name).fontWeight(.medium).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Image(systemName: job.direction.symbol).font(.caption).foregroundStyle(.secondary)
            }
            Label(store.resettingJobs.contains(job.id) ? "Resetting downloads…" : phase.label, systemImage: statusSymbol)
                .font(.caption)
                .labelStyle(AccessibleStatusLabelStyle(symbolColor: statusColor))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .help(phase.label)
            if case .failed = phase {
                Button("View error details…", action: openJobSettings)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.tint)
            } else {
                Text(activityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
    }

    private var quickControlsButton: some View {
        Button { showQuickControls.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
        .help("Job Controls: frequency, file type, settings and metadata")
        .accessibilityLabel("Job Controls for \(job.name)")
        .accessibilityHint("Opens sync frequency, file filter, job settings and metadata shortcuts")
        .popover(isPresented: $showQuickControls, arrowEdge: .trailing) {
            JobQuickControls(job: job, onOpenMetadata: openMetadataProgramming)
                .environmentObject(store)
        }
    }

    private func openMetadataProgramming() {
        showQuickControls = false
        store.selectedJobID = job.id
        dismiss()
        DispatchQueue.main.async {
            RegularWindowController.shared.prepareForOpening(windowID: "metadata-programming")
            openWindow(id: "metadata-programming")
        }
    }

    private var folderButton: some View {
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
    }

    private var automaticSyncButton: some View {
        Button {
            store.setEnabled(!job.isEnabled, for: job.id)
        } label: {
            Label(
                job.isEnabled ? "Stop" : "Start",
                systemImage: job.isEnabled ? "stop.fill" : "play.fill"
            )
        }
        .disabled(store.resettingJobs.contains(job.id))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .tint(job.isEnabled ? Color.red : Color.green)
        .help(job.isEnabled ? "Stop Automatic Sync" : "Start Automatic Sync")
    }

    private var statusSymbol: String {
        if case .failed = phase { return "xmark.octagon.fill" }
        if case .succeeded(_, _, _, _, let conflicts, let metadataReport, _, let pendingSourceFiles) = phase,
           !conflicts.isEmpty || metadataReport.failed > 0 || !pendingSourceFiles.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        if case .syncing = phase { return "arrow.triangle.2.circlepath" }
        return "circle.fill"
    }

    private func openJobSettings() {
        store.selectedJobID = job.id
        RegularWindowController.shared.prepareForOpening(windowID: "jobs")
        openWindow(id: "jobs")
    }

    private var statusColor: Color {
        if case .failed = phase { return .red }
        if case .succeeded(_, _, _, _, let conflicts, let metadataReport, _, let pendingSourceFiles) = phase,
           !conflicts.isEmpty || metadataReport.failed > 0 || !pendingSourceFiles.isEmpty {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let job: SyncJob
    let onOpenMetadata: () -> Void
    @State private var intervalSeconds: Double
    @State private var ageIndex: Double
    @State private var intervalWasEdited = false
    @State private var ageWasEdited = false
    @State private var ageEditingOptions: [Int?] = []

    init(job: SyncJob, onOpenMetadata: @escaping () -> Void) {
        self.job = job
        self.onOpenMetadata = onOpenMetadata
        _intervalSeconds = State(initialValue: job.intervalSeconds)
        let index = FileAgeChoices.hours(including: job.filter.recentHours).firstIndex(of: job.filter.recentHours) ?? 0
        _ageIndex = State(initialValue: Double(index))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentJob.name)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Text(currentJob.isEnabled ? "Automatic sync is running" : "Automatic sync is paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: currentJob.isEnabled ? "play.fill" : "pause.fill")
                    .foregroundStyle(currentJob.isEnabled ? .green : .secondary)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { jobShortcuts }
                VStack(alignment: .leading, spacing: 8) { jobShortcuts }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

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
                    value: intervalSliderBinding,
                    in: 5...300,
                    step: 1,
                    onEditingChanged: { editing in
                        if editing {
                            intervalSeconds = displayedIntervalSeconds
                            intervalWasEdited = true
                        }
                        if !editing { commitInterval() }
                    }
                )
                HStack {
                    Text("5 sec")
                    Spacer()
                    Text("5 min")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("File age")
                    Spacer()
                    Text(ageLabel)
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: ageSliderBinding,
                    in: Double(minimumAgeIndex)...Double(ageOptions.count - 1),
                    step: 1,
                    onEditingChanged: { editing in
                        if editing && !ageWasEdited {
                            ageIndex = ageSliderBinding.wrappedValue
                            ageEditingOptions = ageOptions
                            ageWasEdited = true
                        }
                        if !editing { commitFileAge() }
                    }
                )
                HStack {
                    Text(currentJob.targetCleanup == nil ? "Any age" : "Last hour")
                    Spacer()
                    Text(FileAgeChoices.title(for: ageOptions.last ?? nil))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if currentJob.targetCleanup != nil {
                    Text("Automatic cleanup requires a file-age limit. Turn off cleanup in Job Settings to choose Any age.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 460 : 340)
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
    private var jobShortcuts: some View {
        Button(action: openJobSettings) {
            Label("Job Settings", systemImage: "gearshape")
        }
        .help("Edit this job in the Sync Jobs window")
        Button(action: onOpenMetadata) {
            Label("Metadata", systemImage: "tag")
        }
        .help("Open Metadata Programming for this job")
        .accessibilityLabel("Metadata Programming for \(currentJob.name)")
        localFolderControl
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
        let seconds = Int(displayedIntervalSeconds)
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes)m \(remainder)s"
    }

    private var minimumAgeIndex: Int { currentJob.targetCleanup == nil ? 0 : 1 }

    private var ageOptions: [Int?] {
        // Freeze ordinal choices during a gesture so an external custom-age
        // change cannot reinterpret the slider position under the user's hand.
        ageWasEdited ? ageEditingOptions : FileAgeChoices.hours(including: currentJob.filter.recentHours)
    }

    private var displayedIntervalSeconds: Double {
        // Idle controls show committed settings, including after failed saves.
        intervalWasEdited ? intervalSeconds : currentJob.intervalSeconds
    }

    private var intervalSliderBinding: Binding<Double> {
        Binding(get: { displayedIntervalSeconds }, set: {
            intervalSeconds = $0
            intervalWasEdited = true
        })
    }

    private var ageSliderBinding: Binding<Double> {
        Binding(
            get: {
                let savedIndex = Double(ageOptions.firstIndex(of: currentJob.filter.recentHours) ?? minimumAgeIndex)
                return max(Double(minimumAgeIndex), ageWasEdited ? ageIndex : savedIndex)
            },
            set: {
                if !ageWasEdited { ageEditingOptions = ageOptions }
                ageIndex = $0
                ageWasEdited = true
            }
        )
    }

    private var selectedAge: Int? {
        let index = min(max(Int(ageSliderBinding.wrappedValue.rounded()), minimumAgeIndex), ageOptions.count - 1)
        return ageOptions[index]
    }

    private var ageLabel: String {
        FileAgeChoices.title(for: selectedAge)
    }

    private func commitInterval() {
        guard intervalWasEdited else { return }
        intervalWasEdited = false
        guard abs(currentJob.intervalSeconds - intervalSeconds) > 0.001 else { return }
        store.updateInterval(jobID: job.id, seconds: intervalSeconds)
    }

    private func commitFileAge() {
        guard ageWasEdited else { return }
        let requestedAge = selectedAge
        ageWasEdited = false
        guard currentJob.filter.recentHours != requestedAge else { return }
        store.updateFileAge(jobID: job.id, recentHours: requestedAge)
    }
}

/// Keep saved custom windows selectable instead of presenting them as Any age.
enum FileAgeChoices {
    static func hours(including selected: Int?) -> [Int?] {
        var hours: Set<Int> = [1, 3, 6, 12, 24, 48, 168]
        if let selected, selected > 0 { hours.insert(selected) }
        return [nil] + hours.sorted().map(Optional.some)
    }

    static func title(for hours: Int?) -> String {
        guard let hours else { return "Any age" }
        if hours == 1 { return "Last hour" }
        if hours.isMultiple(of: 24) {
            let days = hours / 24
            return days == 1 ? "Last day" : "Last \(days) days"
        }
        return "Last \(hours) hours"
    }
}
