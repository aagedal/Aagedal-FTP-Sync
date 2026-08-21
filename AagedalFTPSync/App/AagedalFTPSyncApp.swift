import AppKit
import SwiftUI

@main
struct AagedalFTPSyncApp: App {
    @StateObject private var store = AppStore()

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
        HStack(spacing: 3) {
            Image(systemName: store.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle")
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
        .accessibilityLabel(accessibilityLabel(for: count))
    }

    private func accessibilityLabel(for count: Int) -> String {
        guard count > 0 else { return "Aagedal FTP Sync" }
        let files = count == 1 ? "1 file" : "\(count) files"
        return "Aagedal FTP Sync, \(files) synced since the jobs started"
    }
}
