import AppKit
import SwiftUI

/// The builder is invoked only after both stores have been admitted together.
/// Window restoration must never instantiate store-backed views during recovery.
struct StartupGate<Content: View>: View {
    @ObservedObject var startup: Version3StartupController
    @ViewBuilder let content: (Version3StartupController.Session) -> Content

    var body: some View {
        Group {
            if let session = startup.session {
                VStack(spacing: 0) {
                    if startup.requiresRelaunchAfterConflict {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(startup.userFacingMessage, systemImage: "exclamationmark.triangle")
                            StartupWindowButton()
                        }.padding(12)
                    } else {
                        StartupPauseNotice(calendar: session.calendar)
                    }
                    content(session)
                        .disabled(startup.requiresRelaunchAfterConflict || !startup.otherRunningCopies.isEmpty)
                }
                .environmentObject(session.store)
                .environmentObject(session.calendar)
                .applyingUITestDynamicTypeSize()
            } else {
                Version3StartupView(startup: startup)
            }
        }
        .task { await startup.load() }
    }
}

private struct StartupPauseNotice: View {
    @ObservedObject var calendar: MetadataCalendarCoordinator
    var body: some View {
        if calendar.isPaused {
            HStack {
                Image(systemName: "pause.circle")
                Text("Calendar sync is paused. Review the migrated jobs before starting work.")
                    .font(.callout)
                Spacer()
                StartupWindowButton()
            }
            .padding(10)
            .background(.quaternary)
        }
    }
}

struct StartupWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Startup and Recovery…") {
            RegularWindowController.shared.prepareForOpening(windowID: "startup")
            openWindow(id: "startup")
        }
        .accessibilityIdentifier("startup.open")
    }
}

struct StartupMenuLabel: View {
    @ObservedObject var startup: Version3StartupController
    @Environment(\.openWindow) private var openWindow
    @State private var openedAttention = false
    @State private var openedConflict = false

    var body: some View {
        Group {
            if startup.requiresRelaunchAfterConflict {
                Label("FTP Sync writer conflict", systemImage: "exclamationmark.triangle")
            } else if let session = startup.session {
                MenuBarActivityLabel(store: session.store)
            } else {
                Label(startup.busy ? "FTP Sync loading" : "FTP Sync needs attention",
                      systemImage: startup.busy ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
            }
        }
        .task {
            await startup.load()
            showAttentionIfNeeded()
        }
        .onChange(of: startup.phase) { _, _ in showAttentionIfNeeded() }
        .onChange(of: startup.requiresRelaunchAfterConflict) { _, _ in showAttentionIfNeeded() }
    }

    private func showAttentionIfNeeded() {
        if startup.requiresRelaunchAfterConflict, !openedConflict, !startup.isTestSession {
            openedConflict = true
            RegularWindowController.shared.prepareForOpening(windowID: "startup")
            openWindow(id: "startup")
            return
        }
        guard !openedAttention, !startup.isTestSession, !startup.busy,
              startup.session == nil, startup.phase != .idle else { return }
        openedAttention = true
        RegularWindowController.shared.prepareForOpening(windowID: "startup")
        openWindow(id: "startup")
    }
}

struct RuntimeSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        TabView(selection: $store.settingsTab) {
            ServerSettingsView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
                .tag(AppSettingsTab.servers)
            PhotographerSettingsView()
                .tabItem { Label("Photographers", systemImage: "person.2") }
                .tag(AppSettingsTab.photographers)
            MetadataSyncSettingsView()
                .tabItem { Label("Metadata Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(AppSettingsTab.metadataSync)
            if let controller = store.peopleLibraryController {
                PeopleLibrarySettingsView(controller: controller)
                    .tabItem { Label("People Library", systemImage: "person.crop.rectangle.stack") }
                    .tag(AppSettingsTab.peopleLibrary)
            }
        }
    }
}

struct Version3StartupView: View {
    @ObservedObject var startup: Version3StartupController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(title, systemImage: startup.session == nil ? "externaldrive.badge.checkmark" : "checkmark.circle")
                    .font(.title2.bold())
                Text(startup.userFacingMessage)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("startup.message")
                if startup.requiresRelaunchAfterConflict {
                    Text("New work is blocked and active operations are being cancelled. Keep this app open until its file operations settle, then quit and reopen it after closing the other copies.")
                } else if startup.busy {
                    ProgressView("Checking saved data…")
                } else if let session = startup.session {
                    Text("Jobs stay stopped until you start them. Review their folders, credentials and saved programming first.")
                    if session.calendar.isPaused {
                        Button("Start Calendar Sync") {
                            do { try startup.activateCalendarSync() } catch { /* Controller presents the reason. */ }
                        }
                        .accessibilityIdentifier("startup.startCalendar")
                    } else {
                        Text("Calendar sync is active.").foregroundStyle(.secondary)
                    }
                } else {
                    if !startup.otherRunningCopies.isEmpty {
                        Label("Close the other running copies before continuing.", systemImage: "exclamationmark.triangle")
                        ForEach(startup.otherRunningCopies) { copy in Text(copy.name) }
                        Button("Check Again") { startup.refreshRunningCopies() }
                    }
                    if startup.phase == .selection, let catalog = startup.catalog {
                        Text("Choose the saved source for each library. The originals are retained, and old text keeps its literal meaning. Choosing a backup replaces that library's primary data in the new copy.")
                        ForEach(catalog.primaries, id: \.filename) { primary in
                            Picker(primary.filename, selection: sourceBinding(primary.filename)) {
                                Text("Choose a source").tag(Optional<Version3MigrationDriver.Source>.none)
                                ForEach(primary.choices, id: \.self) { source in
                                    Text(sourceTitle(source)).tag(Optional(source))
                                }
                            }
                            .accessibilityIdentifier("startup.source.\(primary.filename)")
                        }
                        Picker("Original file history", selection: $startup.signatureSelection) {
                            Text("Choose a source").tag(Optional<Version3MigrationDriver.Signatures>.none)
                            ForEach(catalog.signatureChoices, id: \.self) { source in
                                Text(signatureTitle(source)).tag(Optional(source))
                            }
                        }
                        acknowledgment
                        Button("Prepare 3.0 Copy") { Task { await startup.migrate() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canContinue || startup.signatureSelection == nil || !allPrimariesSelected)
                            .accessibilityIdentifier("startup.migrate")
                    } else if startup.phase == .existing {
                        Text("An existing 3.0 installation or recovery record was found. Opening validates its complete saved state. Recovery uses the already prepared copy; it does not import newer changes from 2.9.")
                        acknowledgment
                        HStack {
                            Button("Open Saved 3.0 Data") { Task { await startup.openExisting() } }
                                .disabled(!canContinue)
                                .accessibilityIdentifier("startup.openExisting")
                            Button("Recover Prepared Copy") { Task { await startup.recoverPrepared() } }
                                .disabled(!canContinue)
                                .accessibilityIdentifier("startup.recover")
                        }
                    } else if startup.phase == .recovery {
                        Text("Saved data has been left in place. Resolve the reported problem before trying again. A failed startup never opens empty replacement libraries.")
                        if startup.canRetryInspection {
                            Button("Inspect Again") { Task { await startup.retryInspection() } }
                        } else {
                            Text("Quit and reopen the app after resolving the problem.").font(.callout.bold())
                        }
                    }
                }
                if !startup.recoveryDetail.isEmpty {
                    DisclosureGroup("Recovery details") {
                        Text(startup.recoveryDetail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let root = startup.rootURL {
                    Divider()
                    Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Show Saved Data in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path) }
                }
                Divider()
                Button("Quit Aagedal FTP Sync") { NSApplication.shared.terminate(nil) }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task { await startup.load() }
    }

    private var title: String {
        if startup.session != nil { return "Review before starting" }
        return startup.phase == .selection ? "Prepare your saved data for 3.0" : "Startup and Recovery"
    }
    private var canContinue: Bool {
        startup.userConfirmedOtherCopiesClosed && startup.otherRunningCopies.isEmpty && !startup.busy
    }
    private var acknowledgment: some View {
        Toggle("I have quit all other copies of Aagedal FTP Sync and will keep them closed while using this copy.",
               isOn: $startup.userConfirmedOtherCopiesClosed)
            .accessibilityIdentifier("startup.closedOtherCopies")
    }
    private var allPrimariesSelected: Bool {
        guard let catalog = startup.catalog else { return false }
        return catalog.primaries.allSatisfy { startup.primarySelections[$0.filename] != nil }
    }
    private func sourceBinding(_ name: String) -> Binding<Version3MigrationDriver.Source?> {
        Binding(get: { startup.primarySelections[name] },
                set: { startup.primarySelections[name] = $0 })
    }
    private func sourceTitle(_ source: Version3MigrationDriver.Source) -> String {
        switch source {
        case .absent: "No saved file — initialize empty"
        case .file(let path): path.hasSuffix(".backup") ? "Backup: \(path)" : "Primary: \(path)"
        }
    }
    private func signatureTitle(_ source: Version3MigrationDriver.Signatures) -> String {
        switch source {
        case .absent: "No saved history — initialize empty"
        case .json(let path): "Legacy JSON: \(path)"
        case .sqlite(let path): "SQLite: \(path)"
        }
    }
}
