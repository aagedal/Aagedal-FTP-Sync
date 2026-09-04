import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.tint)
                VStack(spacing: 4) {
                    Text("Aagedal FTP Sync").font(.title2).fontWeight(.semibold)
                    Text("Version \(appVersion)").foregroundStyle(.secondary)
                }
                Text("Fast, careful file delivery for photojournalists and newsrooms.")
                    .multilineTextAlignment(.center)
                Divider()
                Text("Copyright © 2026 Truls Aagedal")
                    .font(.caption)
                Text("Free software under GNU GPL v3.0 or later. This program comes with absolutely no warranty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Link("Source code and license", destination: URL(string: "https://github.com/aagedal/Aagedal-FTP-Sync")!)
                    .font(.caption)
            }
            .padding(28)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
