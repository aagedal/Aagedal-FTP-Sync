import SwiftUI

struct VoiceMemoSettingsView: View {
    @AppStorage(VoiceMemoSettings.modelKey) private var selectedModel = WhisperModel.defaultID
    @AppStorage(VoiceMemoSettings.languageKey) private var language = "no"
    @State private var installed: Set<String> = []
    @State private var downloading: String?
    @State private var progress = 0.0
    @State private var downloadTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        Form {
            Section("Voice memo transcription") {
                Text("Insert {voiceMemoTranscript} in a metadata template to transcribe a WAV with the same filename stem as the image. Audio stays on this Mac. Only the first 30 seconds are processed.")
                Picker("Spoken language", selection: $language) {
                    ForEach(VoiceMemoSettings.languages, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                if selectedModel.hasPrefix("nb_"), !["no", "en", "auto"].contains(language) {
                    Text("Choose a multilingual model for this language. NB-Whisper supports Norwegian and English here.")
                        .foregroundStyle(.orange)
                }
                Text("Keep other caption text in the template, or use {existingDescription} to include the image’s existing caption. The complete description must fit within 2,000 UTF-8 bytes. Missing audio or an oversized result preserves the existing description.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Whisper models") {
                Text("Norwegian Small is selected initially. Download a model to enable transcription. Larger models need more memory and processing time; the estimates below are approximate.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(WhisperModel.catalogue) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name)
                            Text("\(model.sizeLabel) download · \(model.memoryLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if downloading == model.id {
                            ProgressView(value: progress).frame(width: 80)
                            Button("Cancel") { downloadTask?.cancel() }
                        } else {
                            if installed.contains(model.id) {
                                Button(selectedModel == model.id ? "Selected" : "Use") { selectedModel = model.id }
                                    .disabled(selectedModel == model.id)
                                Button("Delete", role: .destructive) {
                                    Task {
                                        do { try await WhisperModelStore.shared.delete(model); await refresh() }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }
                            } else {
                                Button("Download") { download(model) }.disabled(downloading != nil)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(model.name)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Link("NB-Whisper by Nasjonalbiblioteket", destination: URL(string: "https://huggingface.co/NbAiLab/nb-whisper-small")!)
                Link("Multilingual Whisper models", destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp")!)
                Text("Downloads come from Hugging Face and are verified before installation. No model downloads occur automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 650, minHeight: 580)
        .task { await refresh() }
        .onDisappear { downloadTask?.cancel() }
    }

    private func refresh() async { installed = await WhisperModelStore.shared.installedIDs() }

    private func download(_ model: WhisperModel) {
        downloading = model.id
        progress = 0
        error = nil
        downloadTask = Task {
            defer { downloading = nil; downloadTask = nil }
            do {
                try await WhisperModelStore.shared.download(model) { value in
                    Task { @MainActor in
                        if downloading == model.id { progress = value }
                    }
                }
                selectedModel = model.id
            } catch is CancellationError {
                // Cancelling never makes a partial download available for inference.
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            await refresh()
        }
    }
}
