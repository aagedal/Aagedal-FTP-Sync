import SwiftUI
import UniformTypeIdentifiers

struct JobsWindowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showConfigurationImporter = false
    @State private var showConfigurationExporter = false
    @State private var exportDocument = ConfigurationTransferFile()
    @State private var exportFilename = "Aagedal FTP Sync Package"
    @State private var pendingTransfer: PendingConfigurationTransfer?
    @State private var importSummary: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedJobID) {
                ForEach(store.jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name).fontWeight(.medium)
                        Text(job.endpointSummary)
                            .font(.caption).foregroundStyle(.secondary)
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
                        .buttonStyle(.borderless)
                        .keyboardShortcut("n", modifiers: .command)
                        Spacer()
                        Menu {
                            Button("Import Configuration Package…", systemImage: "square.and.arrow.down") {
                                showConfigurationImporter = true
                            }

                            Divider()

                            ForEach(ConfigurationTransferScope.allCases) { scope in
                                Button("Export \(scope.title)…", systemImage: "square.and.arrow.up") {
                                    pendingTransfer = PendingConfigurationTransfer(operation: .export(scope))
                                }
                                .disabled(scope != .metadata && store.jobs.isEmpty)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
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
            if let selectedID = store.selectedJobID,
               let job = store.jobs.first(where: { $0.id == selectedID }) {
                JobDetailEditor(job: job)
                    .id(job.id)
            } else if store.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No sync jobs", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a job to connect two folders or a folder and a server.")
                } actions: {
                    Button("Add Sync Job", action: addJob)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Select a sync job", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .onAppear {
            store.refreshLaunchAtLoginStatus()
            selectFirstIfNeeded()
        }
        .onChange(of: store.jobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
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
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLoginEnabled },
            set: { store.setLaunchAtLoginEnabled($0) }
        )
    }

    private func selectFirstIfNeeded() {
        if store.selectedJobID == nil || !store.jobs.contains(where: { $0.id == store.selectedJobID }) {
            store.selectedJobID = store.jobs.last?.id
        }
    }

    private func addJob() {
        _ = store.addJob()
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
        exportDocument = ConfigurationTransferFile(data: data)
        exportFilename = scope.defaultFilename
        DispatchQueue.main.async { showConfigurationExporter = true }
        return true
    }

    private func importConfiguration(_ data: Data, _ password: String?) -> Bool {
        guard let result = store.importConfiguration(from: data, password: password) else { return false }
        importSummary = result.summary
        return true
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
