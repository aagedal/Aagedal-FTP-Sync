import Foundation
import SwiftUI

struct PhotographerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPhotographerID: UUID?
    @State private var draft: PhotographerProfile?
    @State private var photographerPendingDeletion: PhotographerProfile?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Known Photographers")
                        .font(.headline)
                    Spacer()
                    Button(action: addPhotographer) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add Photographer")
                    Button(action: requestDeletion) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProfile == nil)
                    .help("Delete Photographer")
                }
                .padding(12)

                Divider()

                List(selection: $selectedPhotographerID) {
                    ForEach(store.photographerLibrary) { photographer in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(photographer.photographerName)
                                .fontWeight(.medium)
                            Text(profileSummary(photographer))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(photographer.id)
                    }
                }
            }
            .frame(minWidth: 235, idealWidth: 260, maxWidth: 310)

            Group {
                if let draftBinding {
                    VStack(alignment: .leading, spacing: 16) {
                        PhotographerEditor(photographer: draftBinding)
                        Divider()
                        PhotographerWorkHoursControl(photographer: draftBinding)

                        if let draft {
                            let usageCount = store.photographerUsageCount(draft.id)
                            Label(usageDescription(usageCount), systemImage: "externaldrive.connected.to.line.below")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack {
                            Spacer()
                            Button("Revert", action: loadSelectedProfile)
                                .disabled(!hasUnsavedChanges)
                            Button("Save", action: saveDraft)
                                .buttonStyle(.borderedProminent)
                                .disabled(!hasUnsavedChanges)
                        }
                    }
                    .padding(20)
                } else {
                    ContentUnavailableView(
                        "No photographer selected",
                        systemImage: "person.crop.circle",
                        description: Text("Select a photographer or add a new shared profile.")
                    )
                }
            }
            .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 450)
        .onAppear {
            if selectedPhotographerID == nil {
                selectedPhotographerID = store.photographerLibrary.first?.id
            }
            loadSelectedProfile()
        }
        .onChange(of: selectedPhotographerID) { _, _ in
            loadSelectedProfile()
        }
        .confirmationDialog(
            "Delete shared photographer?",
            isPresented: Binding(
                get: { photographerPendingDeletion != nil },
                set: { if !$0 { photographerPendingDeletion = nil } }
            ),
            presenting: photographerPendingDeletion
        ) { photographer in
            Button("Delete \(photographer.photographerName)", role: .destructive) {
                deletePhotographer(photographer)
            }
        } message: { photographer in
            let usageCount = store.photographerUsageCount(photographer.id)
            if usageCount == 0 {
                Text("This removes the profile from the shared photographer library.")
            } else {
                Text(usageDescription(usageCount) + " Remove it from those jobs before deleting the shared profile.")
            }
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

    private var selectedProfile: PhotographerProfile? {
        guard let selectedPhotographerID else { return nil }
        return store.photographerLibrary.first { $0.id == selectedPhotographerID }
    }

    private var draftBinding: Binding<PhotographerProfile>? {
        guard draft != nil else { return nil }
        return Binding(
            get: { draft ?? PhotographerProfile(name: "", filenamePrefix: "", creator: "", copyrightNotice: "") },
            set: { draft = $0 }
        )
    }

    private var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        return draft != store.photographerLibrary.first(where: { $0.id == draft.id })
    }

    private func loadSelectedProfile() {
        draft = selectedProfile
    }

    private func addPhotographer() {
        let name = uniqueName()
        let photographer = PhotographerProfile(
            name: name,
            filenamePrefix: uniquePrefix(),
            creator: name,
            copyrightNotice: ""
        )
        guard store.savePhotographerProfile(photographer) else { return }
        selectedPhotographerID = photographer.id
        draft = photographer
    }

    private func saveDraft() {
        guard let draft, store.savePhotographerProfile(draft) else { return }
        self.draft = store.photographerLibrary.first { $0.id == draft.id }
    }

    private func requestDeletion() {
        photographerPendingDeletion = selectedProfile
    }

    private func deletePhotographer(_ photographer: PhotographerProfile) {
        guard store.removePhotographerProfile(photographer.id) else {
            photographerPendingDeletion = nil
            return
        }
        selectedPhotographerID = store.photographerLibrary.first?.id
        draft = selectedProfile
        photographerPendingDeletion = nil
    }

    private func uniqueName() -> String {
        let usedNames = Set(store.photographerLibrary.map { $0.name.lowercased() })
        var number = 1
        while usedNames.contains("photographer \(number)") { number += 1 }
        return "Photographer \(number)"
    }

    private func uniquePrefix() -> String {
        let usedPrefixes = Set(store.photographerLibrary.map(\.normalizedPrefix))
        var number = store.photographerLibrary.count + 1
        while usedPrefixes.contains("P\(number)") { number += 1 }
        return "P\(number)"
    }

    private func profileSummary(_ photographer: PhotographerProfile) -> String {
        let prefix = photographer.normalizedPrefix.isEmpty ? "No prefix" : photographer.normalizedPrefix
        let defaultHours: String
        if let hours = photographer.workHours {
            defaultHours = "default \(formatted(minutes: hours.startMinutes))–\(formatted(minutes: hours.endMinutes))"
        } else {
            defaultHours = "no default hours"
        }
        let overrideCount = photographer.workHourOverrides?.count ?? 0
        guard overrideCount > 0 else { return "\(prefix) · \(defaultHours)" }
        let overrides = overrideCount == 1 ? "1 date override" : "\(overrideCount) date overrides"
        return "\(prefix) · \(defaultHours) · \(overrides)"
    }

    private func formatted(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func usageDescription(_ count: Int) -> String {
        switch count {
        case 0: "Not assigned to any sync jobs."
        case 1: "Used by 1 sync job."
        default: "Used by \(count) sync jobs."
        }
    }
}
