import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PhotographerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPhotographerID: UUID?
    @State private var draft: PhotographerProfile?
    @State private var photographerPendingDeletion: PhotographerProfile?
    @State private var showPhotographerImporter = false
    @State private var showPhotographerExporter = false
    @State private var exportDocument = PhotographerLibraryFile(data: Data())
    @State private var importSummary: String?
    @State private var photographerSearch = ""
    @State private var photographerSortOrder = PhotographerSortOrder.ascending

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Known Photographers")
                        .font(.headline)
                    Spacer()
                    Menu {
                        Picker("Sort Order", selection: $photographerSortOrder) {
                            Text("Name, A–Z").tag(PhotographerSortOrder.ascending)
                            Text("Name, Z–A").tag(PhotographerSortOrder.descending)
                        }

                        Divider()

                        Button("Import Photographers…", systemImage: "square.and.arrow.down") {
                            showPhotographerImporter = true
                        }
                        .disabled(hasUnsavedChanges)

                        Button("Export Photographers…", systemImage: "square.and.arrow.up") {
                            prepareExport()
                        }
                        .disabled(store.photographerLibrary.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(hasUnsavedChanges ? "Sort, export, or save changes before importing" : "Sort, import, or export photographers")
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

                TextField("Search photographers", text: $photographerSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)

                Divider()

                List(selection: $selectedPhotographerID) {
                    ForEach(visiblePhotographers) { photographer in
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
                .overlay {
                    if visiblePhotographers.isEmpty, !photographerSearch.isEmpty {
                        ContentUnavailableView.search(text: photographerSearch)
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
        .frame(
            minWidth: 700,
            maxWidth: .infinity,
            minHeight: 450,
            maxHeight: .infinity
        )
        .onAppear {
            if selectedPhotographerID == nil {
                selectedPhotographerID = store.photographerLibrary.first?.id
            }
            loadSelectedProfile()
        }
        .onChange(of: selectedPhotographerID) { _, _ in
            loadSelectedProfile()
        }
        .onChange(of: store.photographerLibrary) { _, library in
            if let selectedPhotographerID,
               !library.contains(where: { $0.id == selectedPhotographerID }) {
                self.selectedPhotographerID = library.first?.id
            }
            loadSelectedProfile()
        }
        .fileImporter(
            isPresented: $showPhotographerImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importPhotographers
        )
        .fileExporter(
            isPresented: $showPhotographerExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Known Photographers"
        ) { result in
            if case .failure(let error) = result {
                store.alertMessage = "The photographer list could not be exported: \(error.localizedDescription)"
            }
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
        .alert("Photographers Imported", isPresented: Binding(
            get: { importSummary != nil },
            set: { if !$0 { importSummary = nil } }
        )) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(importSummary ?? "")
        }
    }

    private var selectedProfile: PhotographerProfile? {
        guard let selectedPhotographerID else { return nil }
        return store.photographerLibrary.first { $0.id == selectedPhotographerID }
    }

    private var visiblePhotographers: [PhotographerProfile] {
        let query = photographerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? store.photographerLibrary : store.photographerLibrary.filter { photographer in
            photographer.photographerName.localizedCaseInsensitiveContains(query)
                || photographer.formattedFilenamePrefixes.localizedCaseInsensitiveContains(query)
                || photographer.copyrightNotice.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { lhs, rhs in
            let comparison = lhs.photographerName.localizedCaseInsensitiveCompare(rhs.photographerName)
            if comparison == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            switch photographerSortOrder {
            case .ascending:
                return comparison == .orderedAscending
            case .descending:
                return comparison == .orderedDescending
            }
        }
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

    private func prepareExport() {
        guard let data = store.photographerLibraryExportData() else { return }
        exportDocument = PhotographerLibraryFile(data: data)
        showPhotographerExporter = true
    }

    private func importPhotographers(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScopedResource {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            guard let result = store.importPhotographerLibrary(from: data) else { return }
            if selectedPhotographerID == nil {
                selectedPhotographerID = store.photographerLibrary.first?.id
            }
            importSummary = importDescription(result)
        } catch {
            store.alertMessage = "The photographers could not be imported: \(error.localizedDescription)"
        }
    }

    private func importDescription(_ result: PhotographerLibraryImportResult) -> String {
        let totalCount = result.addedCount + result.updatedCount + result.unchangedCount
        guard totalCount > 0 else {
            return "The file did not contain any photographers. No changes were made."
        }

        var changes: [String] = []
        if result.addedCount > 0 {
            changes.append("\(result.addedCount) added")
        }
        if result.updatedCount > 0 {
            changes.append("\(result.updatedCount) updated")
        }
        if result.unchangedCount > 0 {
            changes.append("\(result.unchangedCount) unchanged")
        }
        let photographers = totalCount == 1 ? "photographer" : "photographers"
        return "Imported \(totalCount) \(photographers): \(changes.joined(separator: ", "))."
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
        let usedPrefixes = Set(store.photographerLibrary.flatMap(\.normalizedPrefixes))
        var number = store.photographerLibrary.count + 1
        while usedPrefixes.contains("P\(number)") { number += 1 }
        return "P\(number)"
    }

    private func profileSummary(_ photographer: PhotographerProfile) -> String {
        let prefix = photographer.normalizedPrefixes.isEmpty
            ? "No initials"
            : photographer.formattedFilenamePrefixes
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

private struct PhotographerLibraryFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum PhotographerSortOrder: Hashable {
    case ascending
    case descending
}
