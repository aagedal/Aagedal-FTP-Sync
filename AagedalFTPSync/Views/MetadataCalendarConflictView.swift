import SwiftUI

struct MetadataCalendarConflictView: View {
    @EnvironmentObject private var sync: MetadataCalendarCoordinator
    @Environment(\.dismiss) private var dismiss
    @State var review: MetadataCalendarConflictReview
    @State private var choices: [String: MetadataConflictChoice] = [:]
    @State private var reviewError: String?
    @State private var applying = false
    @State private var operationError: String?

    private var plan: Result<MetadataCalendarMergePlan, Error> {
        Result { try review.plan(choices: choices) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resolve conflicts in “\(review.remote.name)”").font(.title2)
            Text("Choose once for each conflicting clip. Independent changes from both Macs are kept, including fields that do not conflict within a clip.")
                .foregroundStyle(.secondary)
            if review.remote.role == "reader" {
                Text("This calendar is read-only. Accept the server’s changes to resume sync.")
            }
            switch plan {
            case .success(let plan):
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(plan.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(conflict.title).font(.headline)
                                HStack(alignment: .top, spacing: 16) {
                                    option(conflict, choice: .local, title: "This Mac", text: conflict.local)
                                    option(conflict, choice: .server, title: "Server", text: conflict.server)
                                }
                            }
                            Divider()
                        }
                        if plan.conflicts.isEmpty {
                            Label("These changes can be merged automatically.", systemImage: "checkmark.circle")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = plan.validationMessage {
                    Text(message).foregroundStyle(.red)
                    Text("Adjust your choices. If the issue remains, edit the affected programming in the Metadata window, then refresh this review.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                feedback
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Refresh Review", action: refreshReview)
                    Spacer()
                    if plan.unresolvedCount > 0 { Text("\(plan.unresolvedCount) remaining").foregroundStyle(.secondary) }
                    Button("Apply Resolutions") {
                        applying = true
                        reviewError = nil
                        operationError = nil
                        sync.resolve(review, choices: choices)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.unresolvedCount > 0 || plan.validationMessage != nil)
                }
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(.red)
                Spacer()
                feedback
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Refresh Review", action: refreshReview)
                }
            }
        }
        .padding(24)
        .frame(width: 820, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(sync.busy)
        .onChange(of: sync.busy) { _, busy in
            guard applying, !busy else { return }
            applying = false
            if sync.state.bindings.first(where: { $0.id == review.id && $0.accountID == review.binding.accountID })?.conflict == nil {
                dismiss()
            } else {
                operationError = sync.message.isEmpty
                    ? "The calendar changed during sync. Refresh this review to resolve the remaining conflicts."
                    : sync.message
            }
        }
    }

    private var feedback: some View {
        Group {
            if let reviewError { Text(reviewError).foregroundStyle(.red).textSelection(.enabled) }
            if let operationError { Text(operationError).foregroundStyle(.secondary).textSelection(.enabled) }
            if sync.busy { ProgressView("Applying resolutions…").controlSize(.small) }
        }
    }

    private func option(_ conflict: MetadataCalendarConflict, choice: MetadataConflictChoice, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                choices[conflict.id] = choice
            } label: {
                Label(title, systemImage: choices[conflict.id] == choice ? "checkmark.circle.fill" : "circle")
            }.disabled(choice == .local && review.remote.role == "reader")
            Text(text.isEmpty ? "Empty" : text).font(.callout).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refreshReview() {
        do {
            guard let binding = sync.state.bindings.first(where: { $0.id == review.id && $0.accountID == review.binding.accountID }) else {
                dismiss(); return
            }
            review = try sync.conflictReview(binding)
            choices = [:]
            reviewError = nil
            operationError = nil
        } catch { reviewError = error.localizedDescription }
    }
}
