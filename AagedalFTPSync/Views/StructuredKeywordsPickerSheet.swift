import SwiftUI

/// Browses the active structured keyword lists, as in Photo Agent. Double-click,
/// Return or Add applies a keyword with its keyword ancestors and synonyms;
/// list and `[category]` headers only group keywords.
struct StructuredKeywordsPickerSheet: View {
    @ObservedObject var library: StructuredKeywordLibraryStore
    let currentKeywords: [String]
    /// Returns false when the receiving list rejected the values.
    let onAdd: ([String]) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var expandedIDs: Set<UUID> = []
    @State private var selection: UUID?
    @State private var feedback: String?
    @FocusState private var searchFocused: Bool

    private struct Row: Identifiable {
        let id: UUID
        let path: StructuredKeywordPath
        let depth: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search keywords or synonyms…", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(activateSelection)
                    .accessibilityIdentifier("structured-keywords-search")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content
            if let feedback {
                Divider()
                Text(feedback).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 460, idealHeight: 560)
        .accessibilityIdentifier("structured-keywords-picker")
        .onAppear {
            library.reload()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: searchText) { _, _ in selection = rows.first?.id }
    }

    @ViewBuilder
    private var content: some View {
        if library.catalog.roots.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Text(library.isLoading ? "Loading structured keywords…" : "No active structured keywords")
                    .font(.headline)
                if !library.isLoading {
                    Text("Link Aagedal Photo Agent’s Lists folder to use its keyword lists.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose Photo Agent Lists Folder…") { library.chooseFolder() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            List(rows, selection: $selection) { row in
                rowView(row).tag(row.id)
            }
            .listStyle(.inset)
            // Double-click and Return run the primary action on the selected row.
            .contextMenu(forSelectionType: UUID.self, menu: { _ in }) { ids in
                guard let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
                activate(row.path)
            }
            .onKeyPress(.space) { activateSelection(); return .handled }
            .onKeyPress(.rightArrow) { setSelectedExpanded(true) }
            .onKeyPress(.leftArrow) { setSelectedExpanded(false) }
        }
    }

    private func rowView(_ row: Row) -> some View {
        let node = row.path.node
        return HStack(spacing: 4) {
            if isSearching {
                VStack(alignment: .leading, spacing: 1) {
                    title(node)
                    if !row.path.ancestors.isEmpty {
                        Text(row.path.ancestors.map { $0.isContainer ? "[\($0.name)]" : $0.name }.joined(separator: " › "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
                if node.children.isEmpty {
                    Color.clear.frame(width: 14, height: 1)
                } else {
                    Button { toggle(node.id) } label: {
                        Image(systemName: expandedIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2).frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandedIDs.contains(node.id) ? "Collapse \(node.name)" : "Expand \(node.name)")
                }
                title(node)
            }
            Spacer()
            if node.isKeyword, currentKeywords.contains(node.name) {
                Text("added").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ node: StructuredKeyword) -> some View {
        HStack(spacing: 6) {
            Text(node.name).italic(node.isContainer).foregroundStyle(node.isContainer ? .secondary : .primary)
            if !node.synonyms.isEmpty {
                Text(node.synonyms.joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(sourceSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Add") { activateSelection() }
                .disabled(selectedRow?.path.node.isKeyword != true)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var sourceSummary: String {
        if let error = library.errorMessage { return error }
        let lists = library.activeListNames.joined(separator: ", ")
        return library.linkedFolderPath == nil ? "\(lists) · Photo Agent lists not linked" : lists
    }

    // MARK: Rows

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var rows: [Row] {
        if isSearching {
            return library.catalog.search(searchText).map { Row(id: $0.node.id, path: $0, depth: 0) }
        }
        var result: [Row] = []
        func append(_ node: StructuredKeyword, _ ancestors: [StructuredKeyword]) {
            result.append(Row(id: node.id, path: StructuredKeywordPath(ancestors: ancestors, node: node), depth: ancestors.count))
            guard expandedIDs.contains(node.id) else { return }
            for child in node.children { append(child, ancestors + [node]) }
        }
        for root in library.catalog.roots { append(root, []) }
        return result
    }

    private var selectedRow: Row? { rows.first { $0.id == selection } }

    private func toggle(_ id: UUID) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    private func setSelectedExpanded(_ expanded: Bool) -> KeyPress.Result {
        guard !isSearching, let row = selectedRow else { return .ignored }
        if expanded { expandedIDs.insert(row.id) } else { expandedIDs.remove(row.id) }
        return .handled
    }

    private func activateSelection() {
        guard let row = selectedRow ?? (isSearching ? rows.first : nil) else { return }
        if row.path.node.isContainer {
            toggle(row.id)
        } else {
            activate(row.path)
        }
    }

    private func activate(_ path: StructuredKeywordPath) {
        guard path.node.isKeyword else { toggle(path.node.id); return }
        let values = StructuredKeywordCatalog.activation(path)
        if onAdd(values) { feedback = "Added: " + values.joined(separator: ", ") }
    }
}
