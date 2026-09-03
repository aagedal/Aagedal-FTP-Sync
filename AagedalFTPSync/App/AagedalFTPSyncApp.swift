import AppKit
import SwiftUI

@main
struct AagedalFTPSyncApp: App {
    @StateObject private var store: AppStore

    init() {
        _store = StateObject(wrappedValue: UITestSupport.makeStore() ?? AppStore())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            MenuBarActivityLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Aagedal FTP Sync", id: "jobs") {
            JobsWindowView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 580)
                .background(RegularWindowTracker())
        }
        .defaultSize(width: 920, height: 650)

        Window("About Aagedal FTP Sync", id: "about") {
            AboutView()
                .frame(width: 430, height: 330)
                .background(RegularWindowTracker())
        }
        .windowResizability(.contentSize)

        Window("Metadata Programming", id: "metadata-programming") {
            MetadataProgrammingView()
                .environmentObject(store)
                .background(RegularWindowTracker())
        }
        .defaultSize(width: 1180, height: 760)

        Window("Photographers", id: "photographers") {
            PhotographerSettingsView()
                .environmentObject(store)
                .background(RegularWindowTracker())
        }
        .defaultSize(width: 700, height: 450)

        Window("Servers", id: "servers") {
            ServerSettingsView()
                .environmentObject(store)
                .background(RegularWindowTracker())
        }
        .defaultSize(width: 780, height: 560)

        Settings {
            TabView {
                ServerSettingsView()
                    .tabItem { Label("Servers", systemImage: "server.rack") }
                PhotographerSettingsView()
                    .tabItem { Label("Photographers", systemImage: "person.2") }
            }
            .environmentObject(store)
            .background(RegularWindowTracker())
        }
    }
}

@MainActor
final class RegularWindowController {
    static let shared = RegularWindowController()

    private var visibleWindowIDs = Set<UUID>()

    func prepareForOpening() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func windowDidOpen(id: UUID) {
        visibleWindowIDs.insert(id)
        prepareForOpening()
    }

    func windowDidClose(id: UUID) {
        visibleWindowIDs.remove(id)
        guard visibleWindowIDs.isEmpty else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

private struct RegularWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView {
        TrackingView()
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    @MainActor
    final class TrackingView: NSView {
        private let trackingID = UUID()
        private weak var trackedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, trackedWindow !== window else { return }

            trackedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            RegularWindowController.shared.windowDidOpen(id: trackingID)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: trackedWindow
            )
            trackedWindow = nil
            RegularWindowController.shared.windowDidClose(id: trackingID)
        }
    }
}

private struct MenuBarActivityLabel: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let count = store.transferredFileCount()
        let state = MenuBarActivityState(phases: Array(store.phases.values))
        HStack(spacing: 3) {
            Image(systemName: state.systemImageName)
                .foregroundStyle(foregroundStyle(for: state.severity))
            if count > 0 {
                Text(count > 999 ? "999+" : "\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay {
                        Capsule().stroke(lineWidth: 1)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel(transferredFileCount: count))
    }

    private func foregroundStyle(for severity: MenuBarActivityState.Severity) -> Color {
        switch severity {
        case .failed: .red
        case .warning: .orange
        case .syncing, .normal: .primary
        }
    }
}

struct MenuBarActivityState: Equatable {
    enum Severity: Equatable {
        case normal
        case syncing
        case warning
        case failed
    }

    let failedJobCount: Int
    let warningJobCount: Int
    let syncingJobCount: Int

    init(phases: [JobPhase]) {
        failedJobCount = phases.count { phase in
            if case .failed = phase { return true }
            return false
        }
        warningJobCount = phases.count { phase in
            guard case .succeeded(
                _, _, _, _, let conflicts, let metadataReport, _
            ) = phase else { return false }
            return !conflicts.isEmpty || metadataReport.failed > 0
        }
        syncingJobCount = phases.count { $0 == .syncing }
    }

    var severity: Severity {
        if failedJobCount > 0 { return .failed }
        if warningJobCount > 0 { return .warning }
        if syncingJobCount > 0 { return .syncing }
        return .normal
    }

    var systemImageName: String {
        switch severity {
        case .failed: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.triangle"
        case .syncing: "arrow.triangle.2.circlepath"
        case .normal: "arrow.triangle.2.circlepath.circle"
        }
    }

    func accessibilityLabel(transferredFileCount: Int) -> String {
        var details: [String] = []
        if failedJobCount > 0 {
            details.append(jobCountDescription(failedJobCount, singular: "failed", plural: "failed"))
        }
        if warningJobCount > 0 {
            details.append(jobCountDescription(
                warningJobCount,
                singular: "needs attention",
                plural: "need attention"
            ))
        }
        if syncingJobCount > 0 {
            details.append(jobCountDescription(syncingJobCount, singular: "syncing", plural: "syncing"))
        }
        if transferredFileCount > 0 {
            let files = transferredFileCount == 1 ? "1 file" : "\(transferredFileCount) files"
            details.append("\(files) synced since the jobs started")
        }
        guard !details.isEmpty else { return "Aagedal FTP Sync" }
        return "Aagedal FTP Sync, " + details.joined(separator: ", ")
    }

    private func jobCountDescription(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 job \(singular)" : "\(count) jobs \(plural)"
    }
}
