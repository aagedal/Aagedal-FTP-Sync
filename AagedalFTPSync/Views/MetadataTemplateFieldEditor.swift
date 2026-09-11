import SwiftUI
import MetadataTemplates

/// The binding always contains a validated atomic pair. Active source is edited
/// in an isolated sheet; cancelling never modifies the caller's value.
struct MetadataTemplateFieldEditor: View {
    let title: String
    @Binding var value: MetadataTemplateText
    var multiline = false
    var samplePhotographer = "Sample Photographer"
    @State private var showingVariables = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if value.templateVersion != nil {
                    Label("Variables enabled", systemImage: "curlybraces")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Variables…") { showingVariables = true }
                    .accessibilityLabel("Edit \(title) variables")
                    .help("Edit source, insert variables and preview sample output before applying.")
            }
            if value.templateVersion != nil {
                Text(value.source.isEmpty ? "Empty source" : value.source)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("\(title) variable source")
                    .help("Use Variables to edit this activated source safely.")
            } else if multiline {
                TextEditor(text: literalBinding)
                    .frame(minHeight: 65, maxHeight: 130)
                    .accessibilityLabel(title)
            } else {
                TextField(title, text: literalBinding)
                    .accessibilityLabel(title)
            }
        }
        .sheet(isPresented: $showingVariables) {
            MetadataTemplateTextDraft(title: title, initial: value, samplePhotographer: samplePhotographer) {
                value = $0
            }
        }
    }

    private var literalBinding: Binding<String> {
        Binding(get: { value.source }, set: { value = .literal($0) })
    }
}

private struct MetadataTemplateTextDraft: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let apply: (MetadataTemplateText) -> Void
    @State private var context: MetadataTemplateContext
    @State private var source: String
    @State private var resolvesVariables: Bool
    @State private var sample = "Preparing sample…"

    private struct PreviewKey: Hashable { let source: String; let enabled: Bool }
    private var previewKey: PreviewKey { PreviewKey(source: source, enabled: resolvesVariables) }

    init(title: String, initial: MetadataTemplateText, samplePhotographer: String,
         apply: @escaping (MetadataTemplateText) -> Void) {
        self.title = title
        self.apply = apply
        _source = State(initialValue: initial.source)
        _resolvesVariables = State(initialValue: initial.templateVersion != nil)
        let zone = TimeZone(identifier: TimeZone.current.identifier) ?? TimeZone(secondsFromGMT: 0)!
        _context = State(initialValue: MetadataTemplateContext(processingDate: Date(), processingTimeZone: zone,
            captureDate: MetadataCaptureDate(date: Date(timeIntervalSince1970: 1_709_208_000),
                                            zoneSource: .explicitOffset(secondsFromGMT: 0)),
            photographer: samplePhotographer))
    }

    private var validation: Result<MetadataTemplateText, Error> {
        Result { resolvesVariables ? try .activated(source) : .literal(source) }
    }
    private var validationError: String? {
        guard case .failure(let error) = validation else { return nil }
        return errorMessage(error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title) Variables").font(.title2.bold())
            Toggle("Resolve Variables", isOn: $resolvesVariables)
                .help("When off, all source text, including braces, remains literal.")
            HStack {
                Text("Source").font(.headline)
                Spacer()
                Menu("Insert Variable") {
                    insert("Capture date", token: "{dateCaptured:YYYY-MM-DD}")
                    Divider()
                    insert("Processing date", token: "{date:YYYY-MM-DD}")
                    insert("Photographer", token: "{photographer}")
                    insert("City", token: "{gps:city}")
                    insert("Country", token: "{gps:country}")
                    insert("Persons", token: "{persons}")
                }.help("Appends to the end of the source. Enable Resolve Variables to activate it.")
            }
            TextEditor(text: $source)
                .font(.body.monospaced()).frame(height: 120)
                .accessibilityLabel("\(title) source draft")
                .border(Color.secondary.opacity(0.3))
            Text("Insert Variable appends to the end. Use {{ and }} for literal braces when variables are enabled.")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).accessibilityLabel("Source error: \(validationError)")
            }
            Text("Sample output only").font(.headline)
            Text("Processing time is frozen when this editor opens. Assumed processing zone: \(context.processingTimeZone.identifier). Capture date is a fixed example in UTC. This does not read a photo or change saved job assumptions.")
                .font(.caption).foregroundStyle(.secondary)
            Text("City and Country require a usable geocoding result. Persons requires usable Person Shown names from image metadata or recognition. Missing dependencies preserve the existing field.")
                .font(.caption).foregroundStyle(.secondary)
            Text("City, Country and Persons are unavailable in this sample; no location or recognition lookup is performed.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(sample).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 65, maxHeight: 110)
                .accessibilityLabel("\(title) sample output")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard case .success(let replacement) = validation else { return }
                    apply(replacement)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(validationError != nil)
            }
        }
        .padding(20).frame(width: 620)
        .task(id: previewKey) {
            sample = "Preparing sample…"
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            switch validation {
            case .failure(let error): sample = "Fix the source to preview: " + errorMessage(error)
            case .success(let value):
                switch value.resolve(using: context) {
                case .resolved(let result): sample = result.isEmpty ? "No value proposed" : result
                case .preserveExisting(let reason): sample = preservationMessage(reason)
                }
            }
        }
    }

    private func insert(_ label: String, token: String) -> some View {
        Button(label) { source += token }
    }

    private func errorMessage(_ error: Error) -> String {
        guard let error = error as? MetadataTemplateParseError else { return "This source cannot be activated." }
        switch error {
        case .sourceLimitExceeded(let maximum): return "Source exceeds the \(maximum)-byte limit."
        case .unmatchedOpeningBrace(let offset): return "Unclosed opening brace at UTF-8 byte \(offset)."
        case .unmatchedClosingBrace(let offset): return "Unexpected closing brace at UTF-8 byte \(offset)."
        case .nestedOpeningBrace(let offset): return "Nested opening brace at UTF-8 byte \(offset)."
        case .unknownToken(_, let offset): return "Unknown variable at UTF-8 byte \(offset). Use Insert Variable."
        case .unsupportedDateFormat(_, let offset): return "Unsupported date format at UTF-8 byte \(offset). Use YYYY-MM-DD."
        }
    }

    private func preservationMessage(_ reason: MetadataTemplatePreservationReason) -> String {
        switch reason {
        case .missingValues(let variables):
            return "Existing value would be preserved. Missing sample values: " + variables.map(\.rawValue).sorted().joined(separator: ", ")
        case .invalidDate: return "Existing value would be preserved because a date is invalid."
        case .outputLimitExceeded(let maximum): return "Existing value would be preserved: output exceeds \(maximum) bytes."
        case .keywordEntryLimitExceeded(let maximum): return "Existing keywords would be preserved: more than \(maximum) entries."
        }
    }
}
