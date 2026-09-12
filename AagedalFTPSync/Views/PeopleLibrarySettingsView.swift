import SwiftUI
import UniformTypeIdentifiers

struct PeopleLibrarySettingsView: View {
    @ObservedObject var controller: PeopleLibraryController
    @State private var importing = false
    @State private var choosingExportFolder = false
    @State private var confirmingRemoval = false
    @State private var filename = "People Library.aagedalpeople"
    @State private var panelError: String?
    @State private var operation: Task<Void, Never>?

    private var validFilename: Bool {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == filename && name.hasSuffix(".aagedalpeople") && name != ".aagedalpeople"
            && name.utf8.count <= 200 && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !name.hasPrefix(".")
    }
    private var hasSelection: Bool {
        if case .selected = controller.state { return true }; return false
    }
    var body: some View {
        Form {
            Section("People Library") {
                VStack(alignment: .leading, spacing: 8) {
                    switch controller.state {
                    case .unavailable: Text("The people library has not been loaded.")
                    case .unselected: Text("No people library selected")
                    case .failure: Text("The people library is unavailable.")
                    case .selected(let summary):
                        Text("\(summary.peopleCount) people · \(summary.embeddingCount) examples")
                        Text("Library: \(summary.libraryID.uuidString.lowercased())")
                        Text("Exported: \(summary.exportedAt)")
                        Text("Revision: \(summary.revision)").font(.caption).textSelection(.enabled)
                        if summary.includesEditorMetadata { Text("Photo Agent editor metadata included") }
                    }
                }.accessibilityIdentifier("peopleLibrary.summary")
                Text("Import a .aagedalpeople package or .aagedalpeople.zip archive from Photo Agent. Importing selects a local copy; it does not enable recognition or automatic sync.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Import People Library…") { panelError = nil; importing = true }
                    .accessibilityIdentifier("peopleLibrary.import")
                TextField("Export filename", text: $filename)
                    .help("Choose a new filename ending in .aagedalpeople.")
                if !validFilename { Text("Enter a filename ending in .aagedalpeople, without folder separators.").font(.caption) }
                Button("Export People Library…") { panelError = nil; choosingExportFolder = true }
                    .disabled(!hasSelection || !validFilename)
                    .accessibilityIdentifier("peopleLibrary.export")
                Button("Remove Current Library…", role: .destructive) { confirmingRemoval = true }
                    .disabled(!hasSelection).accessibilityIdentifier("peopleLibrary.remove")
            }.disabled(controller.busy || controller.suspended)
            if controller.busy {
                ProgressView("Working with people library…").accessibilityIdentifier("peopleLibrary.progress")
                Button("Cancel") { operation?.cancel(); controller.cancel() }
            }
            if let error = panelError ?? controller.message {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("peopleLibrary.error")
            }
        }
        .formStyle(.grouped).frame(minWidth: 600, minHeight: 420)
        .task { await controller.refresh() }
        .onDisappear { operation?.cancel(); controller.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.aagedalPeopleLibrary, .zip], allowsMultipleSelection: false) { result in
            select(result, importing: true)
        }
        .fileImporter(isPresented: $choosingExportFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            select(result, importing: false)
        }
        .confirmationDialog("Remove current people library?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Current Library", role: .destructive) {
                operation = Task { await controller.removeCurrentLibrary() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current selection. Retained snapshots and exported packages remain available.")
        }
    }
    private func select(_ result: Result<[URL], Error>, importing: Bool) {
        do {
            guard let url = try result.get().first else { return }
            guard importing || validFilename else { return }
            let name = filename
            operation = Task { @MainActor in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if importing { await controller.importPackage(at: url) }
                else { await controller.exportPackage(to: url.appendingPathComponent(name, isDirectory: true)) }
            }
        } catch { panelError = "The selected location could not be opened." }
    }
}
