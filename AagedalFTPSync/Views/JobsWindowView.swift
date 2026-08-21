import SwiftUI

struct JobsWindowView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
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
            if let selectedID, let job = store.jobs.first(where: { $0.id == selectedID }) {
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
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: store.jobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if selectedID == nil || !store.jobs.contains(where: { $0.id == selectedID }) {
            selectedID = store.jobs.last?.id
        }
    }

    private func addJob() {
        selectedID = store.addJob().id
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
