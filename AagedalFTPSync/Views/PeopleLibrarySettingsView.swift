import SwiftUI
import UniformTypeIdentifiers

struct PeopleLibrarySettingsView: View {
    @ObservedObject var controller: PeopleLibraryController
    var componentController: AuraFaceComponentController?
    var recognitionWasAdmitted = false
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
            Section("Recognition Model") {
                if let componentController {
                    AuraFaceModelSettingsSectionContent(
                        controller: componentController,
                        recognitionWasAdmitted: recognitionWasAdmitted
                    )
                } else {
                    Label(
                        "Model downloads are not configured in this build.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("faceModel.status")
                    Text("File transfer and people-library management remain available. Face recognition stays off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
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
        .onDisappear {
            operation?.cancel()
            controller.cancel()
        }
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

private struct AuraFaceModelSettingsSectionContent: View {
    @ObservedObject var controller: AuraFaceComponentController
    let recognitionWasAdmitted: Bool
    @State private var confirmingRemoval = false

    var body: some View {
        Group {
            switch controller.state {
        case .checking:
            ProgressView("Checking the installed model…")
                .accessibilityIdentifier("faceModel.progress")
        case .notInstalled:
            Label("Recognition model is not installed.", systemImage: "square.and.arrow.down")
                .accessibilityIdentifier("faceModel.status")
            installExplanation
            installButton()
        case .downloading(let progress):
            if let progress {
                ProgressView("Downloading recognition model…", value: progress, total: 1)
            } else {
                ProgressView("Downloading recognition model…")
            }
            Text("Keep this window open while the signed model is downloaded and verified.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Cancel Download") { controller.cancel() }
                .accessibilityIdentifier("faceModel.cancel")
        case .installing:
            ProgressView("Verifying and installing recognition model…")
                .accessibilityIdentifier("faceModel.progress")
            Text("The previous verified model remains available if installation fails.")
                .font(.callout).foregroundStyle(.secondary)
        case .installed(let version):
            Label("Recognition model installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("faceModel.status")
            Text("Version: \(version)").font(.caption).textSelection(.enabled)
            if recognitionWasAdmitted {
                Text("This model was admitted at startup and is ready for configured jobs.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Quit and reopen Aagedal FTP Sync to admit the installed model for recognition.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Remove Recognition Model…", role: .destructive) {
                confirmingRemoval = true
            }
            .accessibilityIdentifier("faceModel.remove")
        case .offline:
            Label("The recognition model could not be downloaded while offline.", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("faceModel.status")
            Text("Check the connection and retry. Existing transfers continue without recognition.")
                .font(.callout).foregroundStyle(.secondary)
            installButton(title: "Retry Download")
        case .verificationFailed(let message):
            Label("The recognition model could not be verified or installed.", systemImage: "xmark.shield.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("faceModel.status")
            Text(message).font(.caption).textSelection(.enabled)
            Text("No unverified model was activated. The previous verified model, if any, was retained.")
                .font(.callout).foregroundStyle(.secondary)
            installButton(title: "Download Again")
        case .cancelled:
            Label("Recognition model download was cancelled.", systemImage: "xmark.circle")
                .accessibilityIdentifier("faceModel.status")
            installButton(title: "Download Again")
            }
        }
        .task { controller.refresh() }
        .onDisappear { if controller.isBusy { controller.cancel() } }
        .confirmationDialog(
            "Remove the installed recognition model?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Recognition Model", role: .destructive) {
                controller.removeInstalled()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if recognitionWasAdmitted {
                Text("This running app keeps its already admitted model until it quits. Relaunch to finish disabling face recognition.")
            } else {
                Text("Face recognition will remain unavailable until the model is installed again and the app is relaunched.")
            }
        }
    }

    private var installExplanation: some View {
        Text("AuraFace runs locally after a one-time signed model download. Installing the model does not upload photos or people-library data.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func installButton(title: LocalizedStringKey = "Download and Install Model") -> some View {
        Button(title) { controller.downloadAndInstall() }
            .accessibilityIdentifier("faceModel.install")
    }
}
