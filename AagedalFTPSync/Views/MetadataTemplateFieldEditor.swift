import SwiftUI
import MetadataTemplates

/// Reports fields whose typed source cannot be saved yet, so a parent can block
/// saving instead of silently keeping the last valid value.
struct MetadataTemplateSourceIssuesKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

/// Source text, variable resolution and the variable menu are edited inline.
/// The binding only ever receives a validated atomic value.
struct MetadataTemplateFieldEditor: View {
    let title: String
    @Binding var value: MetadataTemplateText
    var multiline = false
    var samplePhotographer = "Sample Photographer"
    @State private var source: String
    @State private var resolvesVariables: Bool
    @State private var pendingInsertion: String?
    @State private var sampleContext: MetadataTemplateContext

    init(title: String, value: Binding<MetadataTemplateText>, multiline: Bool = false,
         samplePhotographer: String = "Sample Photographer") {
        self.title = title
        _value = value
        self.multiline = multiline
        self.samplePhotographer = samplePhotographer
        _source = State(initialValue: value.wrappedValue.source)
        _resolvesVariables = State(initialValue: value.wrappedValue.templateVersion != nil)
        let zone = TimeZone(identifier: TimeZone.current.identifier) ?? TimeZone(secondsFromGMT: 0)!
        _sampleContext = State(initialValue: MetadataTemplateContext(processingDate: Date(), processingTimeZone: zone,
            captureDate: MetadataCaptureDate(date: Date(timeIntervalSince1970: 1_709_208_000),
                                            zoneSource: .explicitOffset(secondsFromGMT: 0)),
            photographer: samplePhotographer))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
                Toggle("Resolve variables", isOn: $resolvesVariables)
                    .toggleStyle(.checkbox)
                    .help("When off, all text, including braces, stays literal.")
                    .accessibilityLabel("Resolve \(title) variables")
                Menu("Insert Variable") {
                    insert("Capture date", token: "{dateCaptured:YYYY-MM-DD}")
                    Divider()
                    insert("Processing date", token: "{date:YYYY-MM-DD}")
                    insert("Photographer", token: "{photographer}")
                    insert("City", token: "{gps:city}")
                    insert("Country", token: "{gps:country}")
                    insert("Persons", token: "{persons}")
                    insert("Voice memo transcript", token: "{voiceMemoTranscript}")
                    insert("Existing description", token: "{existingDescription}")
                }
                .fixedSize()
                .accessibilityLabel("Insert \(title) variable")
                .help(variableHelp)
            }
            MetadataTemplateSourceInput(title: title, text: $source, multiline: multiline,
                                        monospaced: resolvesVariables, insertion: $pendingInsertion)
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                    .accessibilityIdentifier("\(title) source error")
            } else if resolvesVariables {
                // No label override or text selection here: on macOS 27 either can make
                // AppKit recurse while resolving this text's accessibility label.
                Text(sample).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityIdentifier("\(title) sample output")
            }
        }
        .preference(key: MetadataTemplateSourceIssuesKey.self, value: issue.map { ["\(title): \($0)"] } ?? [])
        .onChange(of: source) { _, _ in publish() }
        .onChange(of: resolvesVariables) { _, _ in publish() }
        .onChange(of: value) { _, newValue in
            // Adopt outside changes, such as loading a preset, but not our own writes.
            guard (try? validation.get()) != newValue else { return }
            source = newValue.source
            resolvesVariables = newValue.templateVersion != nil
        }
    }

    private var validation: Result<MetadataTemplateText, Error> {
        Result { resolvesVariables ? try .activated(source) : .literal(source) }
    }

    private var issue: String? {
        guard case .failure(let error) = validation else { return nil }
        return Self.errorMessage(error)
    }

    private func publish() {
        if case .success(let validated) = validation, validated != value { value = validated }
    }

    private func insert(_ label: String, token: String) -> some View {
        Button(label) {
            pendingInsertion = token
            // Choosing a variable means it should resolve.
            resolvesVariables = true
        }
    }

    private var variableHelp: String {
        "Inserts at the cursor and turns on variable resolution. Use {{ and }} for literal braces. City and Country need a geocoding result, Persons needs Person Shown names, and Voice memo transcript uses the first 30 seconds of a matching WAV. Missing values keep the existing field. A description must fit in 2,000 UTF-8 bytes."
    }

    private var sample: String {
        guard case .success(let value) = validation else { return "" }
        switch value.resolve(using: sampleContext) {
        case .resolved(let result):
            return result.isEmpty ? "Example: no value" : "Example: " + result
        case .preserveExisting(.missingValues(let variables)):
            return "Example keeps the existing value; unavailable in this example: "
                + variables.map(\.rawValue).sorted().joined(separator: ", ")
        case .preserveExisting(.invalidDate): return "Example keeps the existing value because a date is invalid."
        case .preserveExisting(.outputLimitExceeded(let maximum)): return "Example keeps the existing value: output exceeds \(maximum) bytes."
        case .preserveExisting(.keywordEntryLimitExceeded(let maximum)): return "Example keeps the existing value: more than \(maximum) entries."
        }
    }

    static func errorMessage(_ error: Error) -> String {
        guard let error = error as? MetadataTemplateParseError else { return "This text cannot use variables." }
        switch error {
        case .sourceLimitExceeded(let maximum): return "Text exceeds the \(maximum)-byte limit."
        case .unmatchedOpeningBrace(let offset): return "Unclosed opening brace at UTF-8 byte \(offset)."
        case .unmatchedClosingBrace(let offset): return "Unexpected closing brace at UTF-8 byte \(offset)."
        case .nestedOpeningBrace(let offset): return "Nested opening brace at UTF-8 byte \(offset)."
        case .unknownToken(_, let offset): return "Unknown variable at UTF-8 byte \(offset). Use Insert Variable."
        case .unsupportedDateFormat(_, let offset): return "Unsupported date format at UTF-8 byte \(offset). Use YYYY-MM-DD."
        }
    }
}

/// Inserts a requested variable at the cursor where macOS supports reading the
/// text selection (15 and later); otherwise appends it.
private struct MetadataTemplateSourceInput: View {
    let title: String
    @Binding var text: String
    let multiline: Bool
    let monospaced: Bool
    @Binding var insertion: String?

    var body: some View {
        if #available(macOS 15, *) {
            SelectionAwareTemplateInput(title: title, text: $text, multiline: multiline,
                                        monospaced: monospaced, insertion: $insertion)
        } else {
            Group {
                if multiline {
                    TextEditor(text: $text).frame(minHeight: 65, maxHeight: 130)
                } else {
                    TextField(title, text: $text)
                }
            }
            .font(monospaced ? .body.monospaced() : .body)
            .accessibilityLabel(title)
            .onChange(of: insertion) { _, token in
                guard let token else { return }
                insertion = nil
                text += token
            }
        }
    }
}

@available(macOS 15, *)
private struct SelectionAwareTemplateInput: View {
    let title: String
    @Binding var text: String
    let multiline: Bool
    let monospaced: Bool
    @Binding var insertion: String?
    @State private var selection: TextSelection?

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $text, selection: $selection).frame(minHeight: 65, maxHeight: 130)
            } else {
                TextField(title, text: $text, selection: $selection)
            }
        }
        .font(monospaced ? .body.monospaced() : .body)
        .accessibilityLabel(title)
        .onChange(of: insertion) { _, token in
            guard let token else { return }
            insertion = nil
            insert(token)
        }
    }

    private func insert(_ token: String) {
        guard case .selection(let range)? = selection?.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else {
            text += token
            return
        }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + token.count
        text.replaceSubrange(range, with: token)
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset))
    }
}
