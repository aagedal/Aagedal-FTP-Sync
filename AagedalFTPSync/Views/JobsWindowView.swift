import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JobsWindowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @StateObject private var editingSession = JobEditingSession()
    @State private var showConfigurationImporter = false
    @State private var showConfigurationExporter = false
    @State private var showSupportBundleExporter = false
    @State private var exportDocument = ConfigurationTransferFile()
    @State private var supportBundleDocument = RedactedSupportBundleFile()
    @State private var exportFilename = "Aagedal FTP Sync Package"
    @State private var pendingTransfer: PendingConfigurationTransfer?
    @State private var importSummary: String?
    @State private var pendingEditorTransition: PendingEditorTransition?
    @State private var handledNewJobDraftRequestID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: editorSelectionBinding) {
                ForEach(displayedJobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name).fontWeight(.medium)
                        Text(job.endpointSummary)
                            .font(.caption).foregroundStyle(.secondary)
                        if editingSession.isNewJob, editingSession.jobID == job.id {
                            Text("Unsaved draft")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(job.id)
                }
            }
            .navigationTitle("Sync Jobs")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: launchAtLoginBinding) {
                            Label("Launch at Login", systemImage: "power")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if store.launchAtLoginRequiresApproval {
                            Text("Approval required in System Settings.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Open Login Items…") {
                                store.openLoginItemsSettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

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
                            Button("Manage Servers…", systemImage: "server.rack") {
                                openServersWindow()
                            }

                            Divider()

                            Button("Import Configuration Package…", systemImage: "square.and.arrow.down") {
                                if let url = UITestSupport.configurationPackageURL {
                                    loadConfigurationPackage(.success([url]))
                                } else {
                                    showConfigurationImporter = true
                                }
                            }
                            .accessibilityIdentifier("import-configuration")

                            Divider()

                            ForEach(ConfigurationTransferScope.allCases) { scope in
                                Button("Export \(scope.title)…", systemImage: "square.and.arrow.up") {
                                    pendingTransfer = PendingConfigurationTransfer(operation: .export(scope))
                                }
                                .accessibilityIdentifier("export-\(scope.rawValue)")
                                .disabled(scope != .metadata && store.jobs.isEmpty)
                            }

                            Divider()

                            Button("Export Redacted Support Bundle…", systemImage: "lifepreserver") {
                                prepareSupportBundleExport()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("configuration-transfer-menu")
                        .accessibilityLabel("Configuration Actions")
                        .accessibilityHint("Imports or exports configuration packages and support data")
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Import or export configuration packages")
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
            store.refreshLaunchAtLoginStatus()
            selectFirstIfNeeded()
            handleNewJobDraftRequest()
        }
        .onChange(of: store.jobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: store.newJobDraftRequestID) { _, _ in handleNewJobDraftRequest() }
        .onChange(of: store.selectedJobID) { _, selectedJobID in
            guard selectedJobID != editingSession.jobID else { return }
            requestSelection(selectedJobID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshLaunchAtLoginStatus() }
        }
        .fileImporter(
            isPresented: $showConfigurationImporter,
            allowedContentTypes: [.aagedalFTPSyncConfiguration],
            allowsMultipleSelection: false,
            onCompletion: loadConfigurationPackage
        )
        .fileExporter(
            isPresented: $showConfigurationExporter,
            document: exportDocument,
            contentType: .aagedalFTPSyncConfiguration,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                store.alertMessage = "The configuration could not be exported: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $showSupportBundleExporter,
            document: supportBundleDocument,
            contentType: .json,
            defaultFilename: "Aagedal FTP Sync Support Bundle"
        ) { result in
            if case .failure(let error) = result {
                store.alertMessage = "The support bundle could not be exported: \(error.localizedDescription)"
            }
        }
        .sheet(item: $pendingTransfer) { transfer in
            ConfigurationTransferOptionsView(
                operation: transfer.operation,
                onExport: prepareConfigurationExport,
                onImport: importConfiguration
            )
        }
        .alert("Aagedal FTP Sync", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .alert("Configuration Imported", isPresented: Binding(
            get: { importSummary != nil },
            set: { if !$0 { importSummary = nil } }
        )) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(importSummary ?? "")
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
        .background(JobWindowCloseGuard(closeDecision: closeDecision))
    }

    private var displayedJobs: [SyncJob] {
        guard editingSession.isNewJob else { return store.jobs }
        return store.jobs + [editingSession.draft]
    }

    private var editorSelectionBinding: Binding<UUID?> {
        Binding(
            get: { editingSession.jobID },
            set: { jobID in requestSelection(jobID) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLoginEnabled },
            set: { store.setLaunchAtLoginEnabled($0) }
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

    private func openServersWindow() {
        RegularWindowController.shared.prepareForOpening(windowID: "servers")
        openWindow(id: "servers")
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

    private func loadConfigurationPackage(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= ConfigurationTransferCodec.maximumFileSize else {
                throw ConfigurationTransferError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let protection = try ConfigurationTransferCodec.protection(of: data)
            pendingTransfer = PendingConfigurationTransfer(operation: .importPackage(data, protection))
        } catch {
            store.alertMessage = "The configuration could not be opened: \(error.localizedDescription)"
        }
    }

    private func prepareConfigurationExport(
        _ scope: ConfigurationTransferScope,
        _ password: String?
    ) -> Bool {
        guard let data = store.configurationExportData(scope: scope, password: password) else { return false }
        if let url = UITestSupport.configurationPackageURL {
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                store.alertMessage = "The configuration could not be exported: \(error.localizedDescription)"
                return false
            }
        }
        exportDocument = ConfigurationTransferFile(data: data)
        exportFilename = scope.defaultFilename
        DispatchQueue.main.async { showConfigurationExporter = true }
        return true
    }

    private func prepareSupportBundleExport() {
        guard let data = store.supportBundleData() else { return }
        supportBundleDocument = RedactedSupportBundleFile(data: data)
        DispatchQueue.main.async { showSupportBundleExporter = true }
    }

    private func importConfiguration(_ data: Data, _ password: String?) -> Bool {
        guard let result = store.importConfiguration(from: data, password: password) else { return false }
        importSummary = result.summary
        return true
    }
}

private enum PendingEditorTransition: Equatable {
    case selection(UUID?)
    case newJob
}

private struct JobWindowCloseGuard: NSViewRepresentable {
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
