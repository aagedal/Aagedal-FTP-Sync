import SwiftUI

@main
struct AagedalFTPSyncApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle")
                .accessibilityLabel("Aagedal FTP Sync")
        }
        .menuBarExtraStyle(.window)

        Window("Aagedal FTP Sync", id: "jobs") {
            JobsWindowView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 580)
        }
        .defaultSize(width: 920, height: 650)

        Window("About Aagedal FTP Sync", id: "about") {
            AboutView()
                .frame(width: 430, height: 330)
        }
        .windowResizability(.contentSize)
    }
}
