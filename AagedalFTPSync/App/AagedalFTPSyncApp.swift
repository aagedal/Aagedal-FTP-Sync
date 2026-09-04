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
                .applyingUITestDynamicTypeSize()
        } label: {
            MenuBarActivityLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Aagedal FTP Sync", id: "jobs") {
            JobsWindowView()
                .environmentObject(store)
                .applyingUITestDynamicTypeSize()
                .frame(minWidth: 820, minHeight: 580)
                .background(RegularWindowTracker(windowID: "jobs"))
        }
        .defaultSize(width: 920, height: 650)

        Window("About Aagedal FTP Sync", id: "about") {
            AboutView()
                .applyingUITestDynamicTypeSize()
                .frame(width: 430, height: 330)
                .background(RegularWindowTracker(windowID: "about"))
        }
        .windowResizability(.contentSize)

        Window("Metadata Programming", id: "metadata-programming") {
            MetadataProgrammingView()
                .environmentObject(store)
                .applyingUITestDynamicTypeSize()
                .background(RegularWindowTracker(windowID: "metadata-programming"))
        }
        .defaultSize(width: 1180, height: 760)

        Window("Photographers", id: "photographers") {
            PhotographerSettingsView()
                .environmentObject(store)
                .applyingUITestDynamicTypeSize()
                .background(RegularWindowTracker(windowID: "photographers"))
        }
        .defaultSize(width: 700, height: 450)

        Window("Photographer Map", id: "photographer-map") {
            PhotographerMapView()
                .environmentObject(store)
                .applyingUITestDynamicTypeSize()
                .background(RegularWindowTracker(windowID: "photographer-map"))
        }
        .defaultSize(width: 1120, height: 760)

        Window("Servers", id: "servers") {
            ServerSettingsView()
                .environmentObject(store)
                .applyingUITestDynamicTypeSize()
                .background(RegularWindowTracker(windowID: "servers"))
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
            .applyingUITestDynamicTypeSize()
            .background(RegularWindowTracker())
        }
    }
}

/// Status colors remain useful as a quick visual cue, but the readable words
/// use the platform's primary text color so meaning never depends on a
/// low-contrast red, orange, or green foreground.
struct AccessibleStatusLabelStyle: LabelStyle {
    let symbolColor: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon
                .foregroundStyle(symbolColor)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

@MainActor
final class RegularWindowController {
    static let shared = RegularWindowController()

    private var visibleWindowIDs = Set<UUID>()
    private var windowsByID: [String: NSWindow] = [:]

    func prepareForOpening(windowID: String? = nil) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard let windowID else { return }
        bringToFront(windowID)

        // SwiftUI may finish opening or restoring a Window scene on the next
        // run-loop pass, so repeat the targeted ordering once it has settled.
        DispatchQueue.main.async { [weak self] in
            self?.bringToFront(windowID)
        }
    }

    func windowDidOpen(id: UUID, windowID: String?, window: NSWindow) {
        visibleWindowIDs.insert(id)
        if let windowID {
            windowsByID[windowID] = window
        }
        prepareForOpening(windowID: windowID)
    }

    func windowDidClose(id: UUID, windowID: String?, window: NSWindow?) {
        visibleWindowIDs.remove(id)
        if let windowID, windowsByID[windowID] === window {
            windowsByID.removeValue(forKey: windowID)
        }
        guard visibleWindowIDs.isEmpty else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func bringToFront(_ windowID: String) {
        guard let window = windowsByID[windowID] else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct RegularWindowTracker: NSViewRepresentable {
    let windowID: String?

    init(windowID: String? = nil) {
        self.windowID = windowID
    }

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(windowID: windowID)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    @MainActor
    final class TrackingView: NSView {
        private let trackingID = UUID()
        private let windowID: String?
        private weak var trackedWindow: NSWindow?

        init(windowID: String?) {
            self.windowID = windowID
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

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
            RegularWindowController.shared.windowDidOpen(
                id: trackingID,
                windowID: windowID,
                window: window
            )
        }

        @objc private func windowWillClose(_ notification: Notification) {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: trackedWindow
            )
            let closingWindow = trackedWindow
            trackedWindow = nil
            RegularWindowController.shared.windowDidClose(
                id: trackingID,
                windowID: windowID,
                window: closingWindow
            )
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
