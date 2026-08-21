import SwiftUI

struct JobsWindowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

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
        .alert("Aagedal FTP Sync", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
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
