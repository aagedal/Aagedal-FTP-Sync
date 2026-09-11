import Foundation
import MetadataTemplates
import SwiftUI

/// The complete ordered list and its activation remain one draft value. No comma
/// parsing, trimming, deduplication, or parent mutation occurs while editing.
struct MetadataTemplateKeywordsDraft: Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        var source: String
        init(source: String) { id = UUID(); self.source = source }
    }
    var entries: [Entry]
    var resolvesVariables: Bool

    init(_ value: MetadataTemplateKeywords) {
        entries = value.source.map { Entry(source: $0) }
        resolvesVariables = value.templateVersion != nil
    }

    func validatedValue() throws -> MetadataTemplateKeywords {
        try MetadataTemplateKeywords(source: entries.map(\.source),
            templateVersion: resolvesVariables ? MetadataTemplate.languageVersion : nil)
    }

    struct PreviewKey: Equatable, Sendable { let sources: [String]; let active: Bool }
    var previewKey: PreviewKey { PreviewKey(sources: entries.map(\.source), active: resolvesVariables) }

    var validationMessage: String? {
        do { _ = try validatedValue(); return nil }
        catch let error as MetadataTemplateParseError {
            switch error {
            case .unknownToken(let token, _): return "Unknown variable {\(token)}. Choose a supported variable from Insert Variable."
            case .unsupportedDateFormat: return "Use YYYY-MM-DD for capture and processing dates."
            case .sourceLimitExceeded(let maximum): return "A keyword exceeds the \(maximum)-byte source limit."
            case .unmatchedOpeningBrace, .unmatchedClosingBrace, .nestedOpeningBrace:
                return "Check keyword braces. Use {{ and }} for literal braces in an activated list."
            }
        } catch { return "The keyword list is too large or contains unsupported variable settings." }
    }
}

struct MetadataTemplateKeywordsEditor: View {
    @Binding var value: MetadataTemplateKeywords
    var samplePhotographer = "Sample Photographer"
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Keywords")
                Spacer()
                Text(value.templateVersion == nil ? "Literal text" : "Variables enabled")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Edit Keywords…") { showingEditor = true }
            }
            Text(value.source.isEmpty ? "No keywords" : value.source.joined(separator: " • "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .sheet(isPresented: $showingEditor) {
            MetadataTemplateKeywordsSheet(value: value, samplePhotographer: samplePhotographer) { value = $0 }
        }
    }
}

private struct MetadataTemplateKeywordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MetadataTemplateKeywordsDraft
    @State private var checkedKey: MetadataTemplateKeywordsDraft.PreviewKey?
    @State private var validatedPair: MetadataTemplateKeywords?
    @State private var validationMessage: String?
    @State private var preview = "Preparing sample…"
    @State private var sampleContext: MetadataTemplateContext
    let samplePhotographer: String
    let onApply: (MetadataTemplateKeywords) -> Void

    init(value: MetadataTemplateKeywords, samplePhotographer: String,
         onApply: @escaping (MetadataTemplateKeywords) -> Void) {
        _draft = State(initialValue: MetadataTemplateKeywordsDraft(value))
        let sampleDate = Date(timeIntervalSince1970: 1_704_153_600)
        _sampleContext = State(initialValue: MetadataTemplateContext(processingDate: sampleDate, processingTimeZone: .gmt,
            captureDate: MetadataCaptureDate(date: sampleDate, zoneSource: .explicitOffset(secondsFromGMT: 0)),
            photographer: samplePhotographer))
        self.samplePhotographer = samplePhotographer
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keywords").font(.title2)
            Text("Each row is one keyword, including any commas. Entry order and source text are kept exactly.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Resolve variables for the entire keyword list", isOn: $draft.resolvesVariables)
            if draft.resolvesVariables {
                Text("Missing capture dates, location names, or people leave the entire keyword list unchanged. {{ and }} produce literal braces.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Convert Entire List to Literal Text") { draft.resolvesVariables = false }
            } else {
                Text("Braces stay literal until you enable variable resolution. Inserting a variable does not enable it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($draft.entries) { $entry in
                        HStack {
                            TextField("Keyword", text: $entry.source)
                                .textFieldStyle(.roundedBorder)
                            Menu("Insert Variable") {
                                Button("Capture date · YYYY-MM-DD") { entry.source += "{dateCaptured:YYYY-MM-DD}" }
                                Button("Processing date · YYYY-MM-DD") { entry.source += "{date:YYYY-MM-DD}" }
                                Button("Photographer") { entry.source += "{photographer}" }
                                Button("City") { entry.source += "{gps:city}" }
                                Button("Country") { entry.source += "{gps:country}" }
                                Button("People shown") { entry.source += "{persons}" }
                            }
                            .help("Append a variable to the end of this keyword. Enable resolution to activate the entire list.")
                            Button { draft.entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove keyword")
                        }
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            Button("Add Keyword") { draft.entries.append(.init(source: "")) }
                .disabled(draft.entries.count >= MetadataTemplate.maximumKeywordEntries)
            Text("Example uses 2024-01-02 in UTC and the selected photographer. Location and people are unavailable in this sample.")
                .font(.caption).foregroundStyle(.secondary)
            if checkedKey != draft.previewKey {
                Text("Checking keywords…").font(.caption).foregroundStyle(.secondary)
            } else if let message = validationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            } else {
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard checkedKey == draft.previewKey, let validatedPair else { return }
                    onApply(validatedPair)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checkedKey != draft.previewKey || validatedPair == nil)
            }
        }
        .padding(20)
        .frame(width: 650, height: 520)
        .accessibilityIdentifier("metadata-keywords-editor")
        .task(id: draft.previewKey) {
            let captured = draft
            let context = sampleContext
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> (MetadataTemplateKeywords?, String?, String) in
                // Check cancellation between rows before constructing the atomic value.
                if captured.resolvesVariables {
                    for entry in captured.entries {
                        guard !Task.isCancelled else { return (nil, nil, "") }
                        if (try? MetadataTemplateText.activated(entry.source)) == nil {
                            return (nil, captured.validationMessage, "")
                        }
                    }
                }
                guard !Task.isCancelled else { return (nil, nil, "") }
                guard let value = try? captured.validatedValue() else { return (nil, captured.validationMessage, "") }
                let sample: String
                switch value.resolve(using: context) {
                case .resolved(let values): sample = "Example preview: " + values.joined(separator: " • ")
                case .preserveExisting(.missingValues(let variables)):
                    let names = variables.map { variable in
                        switch variable {
                        case .captureDate: return "capture date"
                        case .processingDate: return "processing date"
                        case .photographer: return "photographer"
                        case .city: return "city"
                        case .country: return "country"
                        case .persons: return "people shown"
                        }
                    }.sorted().joined(separator: ", ")
                    sample = "Existing keyword list would be preserved. Missing sample values: " + names
                case .preserveExisting: sample = "Existing keyword list would be preserved because the result exceeds a limit or contains an invalid date."
                }
                return (value, nil, sample)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, captured.previewKey == draft.previewKey else { return }
            checkedKey = captured.previewKey
            validatedPair = result.0
            validationMessage = result.1
            preview = result.2
        }
    }
}
