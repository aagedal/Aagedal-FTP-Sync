import AppKit
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


extension MetadataTemplateKeywordsDraft {
    /// Typed or pasted text splits on commas and semicolons, as in Photo Agent.
    static func parts(of input: String) -> [String] {
        input.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Appends values not already in the list (exact, case-sensitive match), keeping order.
    static func appending(_ values: [String], to existing: [String]) -> [String] {
        var result = existing
        for value in values where !result.contains(value) { result.append(value) }
        return result
    }
}

/// Photo Agent-style keyword chips with typeahead and the structured keyword
/// picker. Every edit is validated as a whole list before it reaches `value`.
struct MetadataTemplateKeywordsEditor: View {
    @Binding var value: MetadataTemplateKeywords
    var samplePhotographer = "Sample Photographer"
    @ObservedObject private var library = StructuredKeywordLibraryStore.shared
    @State private var inputText = ""
    @State private var inputIsFocused = false
    @State private var suggestions: [KeywordSuggestion] = []
    @State private var highlightedIndex: Int?
    @State private var message: String?
    @State private var messageTask: Task<Void, Never>?
    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Keywords")
                Spacer()
                Toggle("Resolve variables", isOn: Binding(
                    get: { value.templateVersion != nil },
                    set: { apply(value.source, resolvesVariables: $0) }))
                    .toggleStyle(.checkbox)
                    .help("Resolve variables in every keyword. Missing values leave the existing keyword list unchanged.")
                    .accessibilityIdentifier("metadata-keywords-resolve-variables")
                Menu("Insert Variable") {
                    Button("Capture date · YYYY-MM-DD") { insert("{dateCaptured:YYYY-MM-DD}") }
                    Button("Processing date · YYYY-MM-DD") { insert("{date:YYYY-MM-DD}") }
                    Button("Photographer") { insert("{photographer}") }
                    Button("City") { insert("{gps:city}") }
                    Button("Country") { insert("{gps:country}") }
                    Button("People shown") { insert("{persons}") }
                }
                .fixedSize()
                .help("Adds a variable to the keyword being typed and turns on variable resolution.")
                Button { showingPicker = true } label: { Image(systemName: "list.bullet.indent") }
                    .buttonStyle(.borderless)
                    .help("Choose from structured keywords")
                    .accessibilityLabel("Structured Keywords")
                    .accessibilityIdentifier("metadata-keywords-structured")
            }

            if value.source.isEmpty {
                Text("No keywords").font(.caption).foregroundStyle(.secondary)
            } else {
                KeywordFlowLayout(spacing: 4) {
                    ForEach(Array(value.source.enumerated()), id: \.offset) { index, keyword in
                        KeywordChip(keyword: keyword) { remove(at: index) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("metadata-keywords-chips")
            }

            KeywordTypeaheadField(
                text: $inputText,
                placeholder: "Add keyword",
                identifier: "metadata-keywords-input",
                isFocused: $inputIsFocused,
                onSubmit: { addTypedKeywords(useHighlightedSuggestion: true) },
                onArrowDown: { moveHighlight(by: 1) },
                onArrowUp: { moveHighlight(by: -1) },
                onEscape: { dismissSuggestions() })
                .frame(height: 22)
                .popover(isPresented: Binding(get: { inputIsFocused && !suggestions.isEmpty }, set: { _ in }),
                         attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    KeywordSuggestionsList(suggestions: suggestions, highlightedIndex: $highlightedIndex,
                                           onSelect: commit)
                }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        // Contain, so the identifier does not replace those of the controls inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metadata-keywords-editor")
        .onChange(of: inputText) { _, text in
            // Commas and semicolons commit at once, bypassing suggestions, so a
            // pasted "Oslo, Bergen" becomes two plain keywords.
            if text.contains(",") || text.contains(";") {
                addTypedKeywords(useHighlightedSuggestion: false)
            } else {
                updateSuggestions(for: text)
            }
        }
        .onAppear { library.reload() }
        .sheet(isPresented: $showingPicker) {
            StructuredKeywordsPickerSheet(library: library, currentKeywords: value.source) { add($0) }
        }
    }

    private var footnote: String {
        guard value.templateVersion != nil else {
            return value.source.contains(where: { $0.contains("{") })
                ? "Braces stay literal until Resolve variables is on."
                : "Press Return, or type a comma or semicolon, to add a keyword."
        }
        let sampleDate = Date(timeIntervalSince1970: 1_704_153_600)
        let context = MetadataTemplateContext(processingDate: sampleDate, processingTimeZone: .gmt,
            captureDate: MetadataCaptureDate(date: sampleDate, zoneSource: .explicitOffset(secondsFromGMT: 0)),
            photographer: samplePhotographer)
        switch value.resolve(using: context) {
        case .resolved(let values):
            return "Example with 2024-01-02 UTC and \(samplePhotographer): " + values.joined(separator: " • ")
        case .preserveExisting(.missingValues):
            return "Images without every variable's value keep their existing keywords. Location and people are unavailable in this example."
        case .preserveExisting:
            return "Images keep their existing keywords when the result exceeds a limit or contains an invalid date."
        }
    }

    // MARK: Editing

    private func addTypedKeywords(useHighlightedSuggestion: Bool) {
        if useHighlightedSuggestion, let index = highlightedIndex, index < suggestions.count {
            commit(suggestions[index])
            return
        }
        let parts = MetadataTemplateKeywordsDraft.parts(of: inputText)
        guard !parts.isEmpty else { inputText = ""; return }
        // A rejected entry stays in the field so it can be corrected.
        if add(parts) { inputText = "" }
    }

    private func commit(_ suggestion: KeywordSuggestion) {
        let values = library.catalog.activation(forName: suggestion.value) ?? [suggestion.value]
        if add(values) { inputText = "" }
    }

    @discardableResult
    private func add(_ values: [String]) -> Bool {
        let combined = MetadataTemplateKeywordsDraft.appending(values, to: value.source)
        guard combined.count <= MetadataTemplate.maximumKeywordEntries else {
            show("A keyword list can hold at most \(MetadataTemplate.maximumKeywordEntries) keywords.")
            return false
        }
        return apply(combined, resolvesVariables: value.templateVersion != nil)
    }

    private func remove(at index: Int) {
        guard value.source.indices.contains(index) else { return }
        var source = value.source
        source.remove(at: index)
        apply(source, resolvesVariables: value.templateVersion != nil)
    }

    @discardableResult
    private func apply(_ source: [String], resolvesVariables: Bool) -> Bool {
        var draft = MetadataTemplateKeywordsDraft(value)
        draft.entries = source.map { .init(source: $0) }
        draft.resolvesVariables = resolvesVariables
        do {
            value = try draft.validatedValue()
            message = nil
            return true
        } catch {
            show(draft.validationMessage ?? "The keyword list could not be updated.")
            return false
        }
    }

    /// Choosing a variable turns on resolution, as in the other metadata fields.
    private func insert(_ token: String) {
        if value.templateVersion == nil, !apply(value.source, resolvesVariables: true) { return }
        inputText += token
        inputIsFocused = true
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    // MARK: Suggestions

    private func updateSuggestions(for text: String) {
        suggestions = library.catalog.suggestions(for: text)
        if suggestions.isEmpty { highlightedIndex = nil }
        else if let index = highlightedIndex, index >= suggestions.count { highlightedIndex = nil }
    }

    /// Down from no highlight selects the first row; Up from the first row clears it.
    private func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        switch highlightedIndex {
        case nil: highlightedIndex = delta > 0 ? 0 : suggestions.count - 1
        case let current?:
            let next = current + delta
            highlightedIndex = next < 0 ? nil : (next >= suggestions.count ? 0 : next)
        }
    }

    private func dismissSuggestions() {
        suggestions = []
        highlightedIndex = nil
    }
}

private struct KeywordChip: View {
    let keyword: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(keyword).font(.caption)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").font(.caption2) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(keyword)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.secondary.opacity(0.2), in: Capsule())
    }
}

/// Wraps chips onto new rows when the next one would overflow.
struct KeywordFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified)))
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }
        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}

/// An NSTextField so arrow keys, Return and Escape can drive the suggestions.
struct KeywordTypeaheadField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var identifier: String?
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onArrowDown: () -> Void
    let onArrowUp: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.bezelStyle = .roundedBezel
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Add keyword")
        // SwiftUI identifiers do not reach a represented AppKit control.
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        if isFocused, let window = field.window, field.currentEditor() == nil {
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeywordTypeaheadField

        init(_ parent: KeywordTypeaheadField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Deferred: these can fire during a SwiftUI update pass.
        func controlTextDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = true }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = false }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.moveDown(_:)): parent.onArrowDown()
            case #selector(NSResponder.moveUp(_:)): parent.onArrowUp()
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            default: return false
            }
            return true
        }
    }
}

private struct KeywordSuggestionsList: View {
    let suggestions: [KeywordSuggestion]
    @Binding var highlightedIndex: Int?
    let onSelect: (KeywordSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { onSelect(suggestion) } label: {
                    HStack(spacing: 6) {
                        Text(suggestion.value).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        if suggestion.matchKind == .substring {
                            Image(systemName: "text.magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlightedIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { if $0 { highlightedIndex = index } }
            }
        }
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
        .padding(.vertical, 2)
    }
}
