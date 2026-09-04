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
    @State private var promotedPhotographerID: UUID?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var saveConfirmation = false

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
                            if commitPendingDraft(showValidationError: true) {
                                showPhotographerImporter = true
                            }
                        }

                        Button("Export Photographers…", systemImage: "square.and.arrow.up") {
                            if commitPendingDraft(showValidationError: true) {
                                prepareExport()
                            }
                        }
                        .disabled(store.photographerLibrary.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Photographer Library Actions")
                    .accessibilityHint("Sorts, imports, or exports photographer profiles")
                    .help("Sort, import, or export photographers")
                    Button(action: addPhotographer) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add Photographer")
                    .accessibilityHint("Creates a new photographer profile")
                    .help("Add Photographer")
                    Button(action: requestDeletion) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProfile == nil)
                    .accessibilityLabel("Delete Photographer")
                    .accessibilityHint("Deletes the selected photographer profile")
                    .help("Delete Photographer")
                }
                .padding(12)

                TextField("Search photographers", text: $photographerSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)

                Divider()

                ScrollViewReader { proxy in
                    List(selection: photographerSelection) {
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
                            .id(photographer.id)
                        }
                    }
                    .overlay {
                        if visiblePhotographers.isEmpty, !photographerSearch.isEmpty {
                            ContentUnavailableView.search(text: photographerSearch)
                        }
                    }
                    .onChange(of: selectedPhotographerID) { _, _ in
                        scrollToSelectedPhotographer(using: proxy)
                    }
                    .onChange(of: visiblePhotographerIDs) { _, _ in
                        scrollToSelectedPhotographer(using: proxy)
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

                        if let draftValidationMessage {
                            Label(draftValidationMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                        } else if hasUnsavedChanges {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Saving…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if saveConfirmation {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .labelStyle(AccessibleStatusLabelStyle(symbolColor: .green))
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
        .onChange(of: draft) { _, _ in
            scheduleAutosave()
        }
        .onChange(of: store.photographerLibrary) { _, library in
            if let selectedPhotographerID,
               !library.contains(where: { $0.id == selectedPhotographerID }) {
                self.selectedPhotographerID = library.first?.id
            }
            if !hasUnsavedChanges {
                loadSelectedProfile()
            }
        }
        .onDisappear {
            _ = commitPendingDraft(showValidationError: false)
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
        let sorted = filtered.sorted { lhs, rhs in
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
        guard let promotedPhotographerID,
              let promotedIndex = sorted.firstIndex(where: { $0.id == promotedPhotographerID }) else {
            return sorted
        }
        var ordered = sorted
        let promoted = ordered.remove(at: promotedIndex)
        ordered.insert(promoted, at: 0)
        return ordered
    }

    private var visiblePhotographerIDs: [UUID] {
        visiblePhotographers.map(\.id)
    }

    private var photographerSelection: Binding<UUID?> {
        Binding(
            get: { selectedPhotographerID },
            set: { newSelection in
                guard newSelection != selectedPhotographerID,
                      commitPendingDraft(showValidationError: true) else { return }
                if newSelection != promotedPhotographerID {
                    promotedPhotographerID = nil
                }
                selectedPhotographerID = newSelection
            }
        )
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

    private var draftValidationMessage: String? {
        guard let draft else { return nil }
        let name = draft.photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Give the photographer a name."
        }
        if draft.normalizedPrefixes.isEmpty {
            return "Give \(name) filename initials."
        }
        let otherPrefixes = Set(store.photographerLibrary
            .filter { $0.id != draft.id }
            .flatMap(\.normalizedPrefixes))
        if let duplicate = draft.normalizedPrefixes.first(where: otherPrefixes.contains) {
            return "The filename initials \(duplicate) are already used by another photographer."
        }
        return nil
    }

    private func loadSelectedProfile() {
        draft = selectedProfile
    }

    private func addPhotographer() {
        guard commitPendingDraft(showValidationError: true) else { return }
        let name = uniqueName()
        let photographer = PhotographerProfile(
            name: name,
            filenamePrefix: uniquePrefix(),
            creator: name,
            copyrightNotice: ""
        )
        guard store.savePhotographerProfile(photographer) else { return }
        photographerSearch = ""
        promotedPhotographerID = photographer.id
        selectedPhotographerID = photographer.id
        draft = photographer
        saveConfirmation = false
    }

    @discardableResult
    private func saveDraft() -> Bool {
        guard let draft, store.savePhotographerProfile(draft) else { return false }
        self.draft = store.photographerLibrary.first { $0.id == draft.id }
        saveConfirmation = true
        return true
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard hasUnsavedChanges else { return }
        saveConfirmation = false
        guard draftValidationMessage == nil else { return }

        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            _ = saveDraft()
            autosaveTask = nil
        }
    }

    @discardableResult
    private func commitPendingDraft(showValidationError: Bool) -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard hasUnsavedChanges else { return true }
        if let draftValidationMessage {
            if showValidationError {
                store.alertMessage = draftValidationMessage
            }
            return false
        }
        return saveDraft()
    }

    private func scrollToSelectedPhotographer(using proxy: ScrollViewProxy) {
        guard let selectedPhotographerID,
              visiblePhotographerIDs.contains(selectedPhotographerID) else { return }
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(selectedPhotographerID)
            }
        }
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
