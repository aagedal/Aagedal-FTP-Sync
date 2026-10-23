import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JobsWindowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var editingSession = JobEditingSession()
    @State private var pendingEditorTransition: PendingEditorTransition?
    @State private var handledNewJobDraftRequestID: UUID?
    @State private var selectionRefreshID = UUID()

    // Split from the presentation modifiers below to keep each expression
    // within the compiler's type-checking limits.
    private var jobsSplitView: some View {
        NavigationSplitView {
            List(selection: editorSelectionBinding) {
                ForEach(displayedJobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name).fontWeight(.medium)
                        Text(job.endpointSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        if editingSession.isNewJob, editingSession.jobID == job.id {
                            Label("Unsaved draft", systemImage: "pencil.circle.fill")
                                .font(.caption2)
                                .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(job.id)
                }
            }
            .id(selectionRefreshID)
            .navigationTitle("Sync Jobs")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Button(action: addJob) {
                            Label("Add Sync Job", systemImage: "plus")
                        }
                        .accessibilityIdentifier("add-sync-job")
                        .buttonStyle(.borderless)
                        .keyboardShortcut("n", modifiers: .command)
                        Spacer()
                        Menu {
                            Button("Server Settings…", systemImage: "server.rack") {
                                openSettingsTab(.servers)
                            }
                            Button("Import or Export Configuration…", systemImage: "square.and.arrow.up.on.square") {
                                openSettingsTab(.general)
                            }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier("jobs-settings-menu")
                        .accessibilityLabel("Settings Shortcuts")
                        .accessibilityHint("Opens server settings or configuration import and export")
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Server settings and configuration packages")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background(.bar)
            }
        } detail: {
            if editingSession.hasJob {
                JobDetailEditor(
                    session: editingSession,
                    onDiscardNewJob: { selectFirstAvailableJob() }
                )
                .id(editingSession.draft.id)
            } else if displayedJobs.isEmpty {
                ContentUnavailableView {
                    Label("No sync jobs", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a job to connect two folders or a folder and a server.")
                } actions: {
                    Button("Add Sync Job", action: addJob)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("add-sync-job-empty-state")
                }
            } else {
                ContentUnavailableView("Select a sync job", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .accessibilityIdentifier("jobs-window-content")
        .onAppear {
            UITestSupport.activateJobsWindow()
            selectFirstIfNeeded()
            handleNewJobDraftRequest()
        }
        .onChange(of: store.jobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: store.jobs) { _, jobs in
            if let latest = jobs.first(where: { $0.id == editingSession.jobID }) {
                editingSession.refreshSharedControls(from: latest)
            }
        }
        .onChange(of: store.serverProfiles) { _, _ in
            editingSession.refreshServerProfiles(using: store)
        }
        .onChange(of: store.newJobDraftRequestID) { _, _ in handleNewJobDraftRequest() }
        .onChange(of: store.selectedJobID) { _, selectedJobID in
            guard selectedJobID != editingSession.jobID else { return }
            requestSelection(selectedJobID)
        }
    }

    var body: some View {
        jobsSplitView
        .alert("Aagedal FTP Sync", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { presented in
                guard !presented, let dismissedMessage = store.alertMessage else { return }
                // SwiftUI can write the presentation binding during a view update.
                // Clear only the alert being dismissed after that update completes.
                DispatchQueue.main.async {
                    if store.alertMessage == dismissedMessage { store.alertMessage = nil }
                }
            }
        )) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .confirmationDialog(
            editingSession.isNewJob ? "Discard this unsaved job?" : "Save changes to “\(editingSession.draft.name)”?",
            isPresented: Binding(
                get: { pendingEditorTransition != nil },
                set: { if !$0 { pendingEditorTransition = nil } }
            )
        ) {
            Button("Save Changes") {
                guard editingSession.save(using: store) else { return }
                completePendingEditorTransition()
            }
            .disabled(editingSession.draft.validationMessage != nil || editingSession.credentialLoadError != nil)

            Button(editingSession.isNewJob ? "Discard Draft" : "Discard Changes", role: .destructive) {
                editingSession.markDiscarded()
                completePendingEditorTransition()
            }

            Button("Cancel", role: .cancel) { cancelPendingEditorTransition() }
        } message: {
            Text("Your edits have not been saved.")
        }
        .background(UnsavedChangesWindowGuard(closeDecision: closeDecision))
    }

    private var displayedJobs: [SyncJob] {
        guard editingSession.isNewJob else { return store.jobs }
        return store.jobs + [editingSession.draft]
    }

    private var editorSelectionBinding: Binding<UUID?> {
        Binding(
            get: { editingSession.jobID },
            set: { jobID in
                // List can write its selection while SwiftUI is updating views.
                // Defer the entire transition, including unsaved-change prompts,
                // so it does not publish observable state during that update.
                DispatchQueue.main.async {
                    requestSelection(jobID)
                }
            }
        )
    }

    private func selectFirstIfNeeded() {
        if let editingID = editingSession.jobID {
            if editingSession.isNewJob || store.jobs.contains(where: { $0.id == editingID }) {
                return
            }
            editingSession.clear()
        }
        selectFirstAvailableJob()
    }

    private func addJob() {
        guard !editingSession.hasUnsavedChanges else {
            pendingEditorTransition = .newJob
            return
        }
        beginNewJob()
    }

    private func openSettingsTab(_ tab: AppSettingsTab) {
        store.settingsTab = tab
        RegularWindowController.shared.prepareForOpening()
        openSettings()
    }

    private func handleNewJobDraftRequest() {
        guard let requestID = store.newJobDraftRequestID,
              requestID != handledNewJobDraftRequestID else { return }
        handledNewJobDraftRequestID = requestID
        addJob()
    }

    private func beginNewJob() {
        editingSession.beginNewJob(store.makeJobDraft())
    }

    private func selectFirstAvailableJob() {
        let selection = store.selectedJobID.flatMap { selectedID in
            store.jobs.first(where: { $0.id == selectedID })
        } ?? store.jobs.last
        guard let selection else {
            editingSession.clear()
            store.selectedJobID = nil
            return
        }
        editingSession.edit(selection)
        store.selectedJobID = selection.id
    }

    private func requestSelection(_ jobID: UUID?) {
        guard jobID != editingSession.jobID else { return }
        guard !editingSession.hasUnsavedChanges else {
            pendingEditorTransition = .selection(jobID)
            return
        }
        select(jobID)
    }

    private func select(_ jobID: UUID?) {
        guard let jobID,
              let job = store.jobs.first(where: { $0.id == jobID }) else {
            editingSession.clear()
            store.selectedJobID = nil
            return
        }
        editingSession.edit(job)
        store.selectedJobID = job.id
    }

    private func completePendingEditorTransition() {
        let transition = pendingEditorTransition
        pendingEditorTransition = nil
        switch transition {
        case .selection(let jobID): select(jobID)
        case .newJob: beginNewJob()
        case nil: break
        }
    }

    private func cancelPendingEditorTransition() {
        pendingEditorTransition = nil
        // AppKit can keep the declined row selected even though the binding
        // still points to this draft. Restore it so choosing that row again
        // requests a transition, including when this is an unsaved new job.
        selectionRefreshID = UUID()
        guard !editingSession.isNewJob else { return }
        store.selectedJobID = editingSession.jobID
    }

    private func closeDecision() -> Bool {
        guard editingSession.hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = editingSession.isNewJob
            ? "Save this new job before closing?"
            : "Save changes to “\(editingSession.draft.name)” before closing?"
        alert.informativeText = "Your edits will be lost if you discard them."
        alert.addButton(withTitle: "Save Changes")
        alert.addButton(withTitle: editingSession.isNewJob ? "Discard Draft" : "Discard Changes")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return editingSession.save(using: store)
        case .alertSecondButtonReturn:
            editingSession.markDiscarded()
            return true
        default:
            return false
        }
    }
}

private enum PendingEditorTransition: Equatable {
    case selection(UUID?)
    case newJob
}

struct UnsavedChangesWindowGuard: NSViewRepresentable {
    let closeDecision: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(closeDecision: closeDecision)
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        context.coordinator.closeDecision = closeDecision
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class TrackingView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var closeDecision: @MainActor () -> Bool
        private weak var window: NSWindow?
        nonisolated(unsafe) private weak var forwardedDelegate: NSWindowDelegate?

        init(closeDecision: @escaping @MainActor () -> Bool) {
            self.closeDecision = closeDecision
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            forwardedDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if window?.delegate === self {
                window?.delegate = forwardedDelegate
            }
            window = nil
            forwardedDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard closeDecision() else { return false }
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}

private extension SyncJob {
    var endpointSummary: String {
        switch direction {
        case .leftToRight:
            "\(left.kind.rawValue.uppercased()) → \(right.kind.rawValue.uppercased())"
        case .rightToLeft:
            "\(right.kind.rawValue.uppercased()) → \(left.kind.rawValue.uppercased())"
        case .bidirectional:
            "\(left.kind.rawValue.uppercased()) ↔ \(right.kind.rawValue.uppercased())"
        }
    }
}
