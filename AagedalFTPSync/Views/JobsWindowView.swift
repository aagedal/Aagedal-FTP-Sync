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
                        Text("\(job.left.kind.rawValue.uppercased()) \(job.direction == .bidirectional ? "↔" : "→") \(job.right.kind.rawValue.uppercased())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(job.id)
                }
            }
            .navigationTitle("Sync Jobs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        selectedID = store.addJob().id
                    } label: {
                        Label("Add Job", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selectedID, let job = store.jobs.first(where: { $0.id == selectedID }) {
                JobDetailEditor(job: job)
                    .id(job.id)
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
}
