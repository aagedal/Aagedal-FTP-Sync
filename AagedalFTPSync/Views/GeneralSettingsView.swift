import AppKit
import SwiftUI

/// The first Settings tab: app-wide preferences, a map of the app's windows,
/// and configuration transfer, so new users have one place to start.
struct GeneralSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var showConfigurationImporter = false
    @State private var showConfigurationExporter = false
    @State private var showSupportBundleExporter = false
    @State private var exportDocument = ConfigurationTransferFile()
    @State private var supportBundleDocument = RedactedSupportBundleFile()
    @State private var exportFilename = "Aagedal FTP Sync Package"
    @State private var pendingTransfer: PendingConfigurationTransfer?
    @State private var importSummary: String?

    var body: some View {
        form
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
            .onAppear { store.refreshLaunchAtLoginStatus() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.refreshLaunchAtLoginStatus() }
            }
    }

    private var form: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { store.launchAtLoginEnabled },
                    set: { store.setLaunchAtLoginEnabled($0) }
                ))
                .accessibilityIdentifier("launch-at-login")

                if store.launchAtLoginRequiresApproval {
                    Label("Approval required in System Settings.", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                    Button("Open Login Items…") { store.openLoginItemsSettings() }
                }
            }

            Section {
                windowRow(
                    "Sync Jobs",
                    systemImage: "rectangle.stack",
                    detail: "Create jobs, choose folders and servers, and set file filters.",
                    windowID: "jobs"
                )
                windowRow(
                    "Metadata Programming",
                    systemImage: "tag",
                    detail: "Schedule captions, photographers and keywords for each job.",
                    windowID: "metadata-programming"
                )
                windowRow(
                    "Photographer Map",
                    systemImage: "map",
                    detail: "See where photographers were and edit place-based metadata.",
                    windowID: "photographer-map"
                )
            } header: {
                Text("Windows")
            } footer: {
                Text("Servers, photographers, shared calendars, voice memos and the People Library are configured in the other tabs of this window.")
            }

            Section("Configuration") {
                LabeledContent("Configuration package") {
                    configurationMenu
                }
                LabeledContent("Troubleshooting") {
                    Button("Export Redacted Support Bundle…", action: prepareSupportBundleExport)
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Button("About Aagedal FTP Sync…") {
                    RegularWindowController.shared.prepareForOpening(windowID: "about")
                    openWindow(id: "about")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 460)
    }

    private func windowRow(_ title: String, systemImage: String, detail: String, windowID: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open") {
                RegularWindowController.shared.prepareForOpening(windowID: windowID)
                openWindow(id: windowID)
            }
            .accessibilityLabel("Open \(title)")
        }
    }

    private var configurationMenu: some View {
        Menu("Import or Export") {
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
        }
        .accessibilityIdentifier("configuration-transfer-menu")
        .accessibilityHint("Imports or exports configuration packages")
        .fixedSize()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
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

    private func importConfiguration(_ data: Data, _ password: String?, _ allowAppleCoordinates: Bool) -> Bool {
        guard let result = store.importConfiguration(from: data, password: password, allowImportedAppleCoordinates: allowAppleCoordinates) else { return false }
        importSummary = result.summary
        return true
    }
}
