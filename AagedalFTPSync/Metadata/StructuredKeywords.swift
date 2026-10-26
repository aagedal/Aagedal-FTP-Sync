import Foundation

// Read-only port of Aagedal Photo Agent's structured keyword library. File
// syntax, `library.json` validation and activation order match Photo Agent so
// both apps read the same Lists folder identically. Photo Agent owns editing.

/// A node in a PhotoMechanic-style structured keywords tree. `container`
/// nodes (`[Bracketed]`) group children and are never applied as keywords.
struct StructuredKeyword: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case keyword, container }

    let id: UUID
    let name: String
    let kind: Kind
    let synonyms: [String]
    let relatedKeywords: [String]
    let children: [StructuredKeyword]

    init(id: UUID = UUID(), name: String, kind: Kind, synonyms: [String] = [],
         relatedKeywords: [String] = [], children: [StructuredKeyword] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.synonyms = synonyms
        self.relatedKeywords = relatedKeywords
        self.children = children
    }

    var isContainer: Bool { kind == .container }
    var isKeyword: Bool { kind == .keyword }
}

/// Tab-indented tree text: `[Name]` is a container, `{synonym}` and `#related`
/// one level deeper attach to the node above, four spaces count as one tab.
enum StructuredKeywordParser {
    static let maximumFileBytes = 50 * 1024 * 1024

    static func parse(data: Data) throws -> [StructuredKeyword] {
        guard data.count <= maximumFileBytes else { throw StructuredKeywordLibraryError.fileTooLarge }
        guard let text = decode(data) else { throw StructuredKeywordLibraryError.unreadableText }
        return parseString(text)
    }

    static func parseString(_ raw: String) -> [StructuredKeyword] {
        let cleaned = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        // stack[i] is the most recent node at file depth i - 1; stack[0] is the root.
        let root = Builder(name: "", kind: .container)
        var stack: [Builder] = [root]

        cleaned.enumerateLines { rawLine, _ in
            let (depth, payload) = splitIndent(rawLine)
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let synonym = enclosed(trimmed, "{", "}") {
                if depth >= 1, depth < stack.count { stack[depth].synonyms.append(synonym) }
                return
            }
            if trimmed.hasPrefix("#"), trimmed.count >= 2 {
                let related = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !related.isEmpty, depth >= 1, depth < stack.count { stack[depth].relatedKeywords.append(related) }
                return
            }
            while stack.count > depth + 1 { stack.removeLast() }
            // Malformed files may skip indent levels; attach to the deepest known parent.
            let parent = stack.last ?? root
            let builder: Builder
            if let container = enclosed(trimmed, "[", "]") {
                builder = Builder(name: container, kind: .container)
            } else {
                builder = Builder(name: trimmed, kind: .keyword)
            }
            parent.children.append(builder)
            stack.append(builder)
        }
        return root.children.map { $0.freeze() }
    }

    private static func splitIndent(_ line: String) -> (Int, Substring) {
        var depth = 0
        var pendingSpaces = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\t" {
                depth += 1
                pendingSpaces = 0
            } else if character == " " {
                pendingSpaces += 1
                if pendingSpaces == 4 { depth += 1; pendingSpaces = 0 }
            } else {
                break
            }
            index = line.index(after: index)
        }
        return (depth, line[index...])
    }

    private static func enclosed(_ text: String, _ open: String, _ close: String) -> String? {
        guard text.hasPrefix(open), text.hasSuffix(close), text.count >= 2 else { return nil }
        let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func decode(_ data: Data) -> String? {
        for encoding: String.Encoding in [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    private final class Builder {
        let name: String
        let kind: StructuredKeyword.Kind
        var synonyms: [String] = []
        var relatedKeywords: [String] = []
        var children: [Builder] = []

        init(name: String, kind: StructuredKeyword.Kind) {
            self.name = name
            self.kind = kind
        }

        func freeze() -> StructuredKeyword {
            StructuredKeyword(name: name, kind: kind, synonyms: synonyms,
                              relatedKeywords: relatedKeywords, children: children.map { $0.freeze() })
        }
    }
}

enum StructuredKeywordLibraryError: LocalizedError, Equatable {
    case fileTooLarge
    case unreadableText
    case invalidLibrary
    case missingVocabulary

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "A structured keyword list is larger than 50 MB."
        case .unreadableText: "A structured keyword list could not be read as text."
        case .invalidLibrary: "The structured keyword library has an unsupported format or invalid list data."
        case .missingVocabulary: "The bundled IPTC Media Topics list is unavailable."
        }
    }
}

/// Photo Agent's `structured/library.json`, schema version 1.
struct StructuredKeywordLibraryDocument: Codable, Equatable, Sendable {
    static let iptcID = "iptc-media-topics"
    static let legacyID = "legacy-keywords"

    enum SelectionMode: String, Codable, Sendable { case single, multiple }

    struct List: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var text: String
    }

    /// nil follows the primary system language.
    var languageOverride: String?
    var schemaVersion = 1
    var mode: SelectionMode = .multiple
    var activeIDs: [String] = [iptcID, legacyID]
    var lists: [List] = []

    static func decode(_ data: Data) throws -> Self {
        guard let result = try? JSONDecoder().decode(Self.self, from: data) else {
            throw StructuredKeywordLibraryError.invalidLibrary
        }
        let ids = result.lists.map(\.id)
        let knownIDs = Set(ids + [iptcID, legacyID])
        guard result.schemaVersion == 1,
              result.languageOverride.map({ IPTCMediaTopicsLanguage(rawValue: $0) != nil }) ?? true,
              Set(ids).count == ids.count,
              !ids.contains(iptcID), !ids.contains(legacyID),
              result.lists.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(result.activeIDs).count == result.activeIDs.count,
              result.activeIDs.allSatisfy({ knownIDs.contains($0) }),
              result.mode != .single || result.activeIDs.count <= 1 else {
            throw StructuredKeywordLibraryError.invalidLibrary
        }
        return result
    }
}

enum IPTCMediaTopicsLanguage: String, CaseIterable, Codable, Sendable {
    case arabic = "ar", chinese = "zh-Hans", danish = "dk", englishUK = "en-GB", englishUS = "en-US"
    case french = "fr", german = "de", norwegianBokmal = "no-NB", norwegianNynorsk = "no-NN"
    case portuguese = "pt-PT", portugueseBrazil = "pt-BR", spanish = "es", swedish = "se"

    /// Matches Photo Agent: the primary system language decides, falling back to US English.
    static func resolve(override: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        if let override, let selected = Self(rawValue: override) { return selected }
        guard let preferred = preferredLanguages.first else { return .englishUS }
        let parts = preferred.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        switch parts.first {
        case "ar": return .arabic
        case "zh": return .chinese
        case "da", "dk": return .danish
        case "en": return parts.contains("gb") ? .englishUK : .englishUS
        case "fr": return .french
        case "de": return .german
        case "nb": return .norwegianBokmal
        case "nn": return .norwegianNynorsk
        case "no": return parts.contains("nn") ? .norwegianNynorsk : .norwegianBokmal
        case "pt": return parts.contains("br") ? .portugueseBrazil : .portuguese
        case "es": return .spanish
        case "sv": return .swedish
        default: return .englishUS
        }
    }
}

struct IPTCMediaTopics: Codable, Sendable {
    struct Concept: Codable, Sendable {
        let labels: [String: String]
        let children: [String]
    }

    let release: String
    let roots: [String]
    let concepts: [String: Concept]

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "IPTCMediaTopics", withExtension: "json") else {
            throw StructuredKeywordLibraryError.missingVocabulary
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func tree(language: IPTCMediaTopicsLanguage) -> [StructuredKeyword] {
        func node(_ id: String, ancestors: Set<String>) -> StructuredKeyword? {
            guard !ancestors.contains(id), let concept = concepts[id],
                  let name = concept.labels[language.rawValue] ?? concept.labels["en-US"] ?? concept.labels["en-GB"] else { return nil }
            let children = concept.children.compactMap { node($0, ancestors: ancestors.union([id])) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return StructuredKeyword(id: UUID(uuidString: "10000000-0000-0000-0000-0000\(id)") ?? UUID(),
                                     name: name, kind: .keyword, children: children)
        }
        return roots.compactMap { node($0, ancestors: []) }
    }
}

struct StructuredKeywordPath: Hashable, Sendable {
    /// Root to parent of `node`, containers included.
    let ancestors: [StructuredKeyword]
    let node: StructuredKeyword
}

struct KeywordSuggestion: Hashable, Identifiable, Sendable {
    enum MatchKind: Hashable, Sendable { case prefix, substring }
    let value: String
    let matchKind: MatchKind
    var id: String { value }
}

/// The active lists, each wrapped in a container named after it so list names
/// are never written as keywords.
struct StructuredKeywordCatalog: Sendable {
    let roots: [StructuredKeyword]
    let searchableNames: [String]

    static let empty = StructuredKeywordCatalog(roots: [])

    init(roots: [StructuredKeyword]) {
        self.roots = roots
        var seen = Set<String>()
        var names: [String] = []
        Self.walk(roots) { node, _ in
            guard node.isKeyword else { return true }
            for value in [node.name] + node.synonyms {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted { names.append(trimmed) }
            }
            return true
        }
        searchableNames = names
    }

    init(document: StructuredKeywordLibraryDocument, myKeywords: [StructuredKeyword], vocabulary: IPTCMediaTopics?,
         preferredLanguages: [String] = Locale.preferredLanguages) {
        let active = Set(document.activeIDs)
        var groups: [StructuredKeyword] = []
        func append(_ id: String, _ groupID: UUID, _ name: String, _ roots: [StructuredKeyword]) {
            guard active.contains(id), !roots.isEmpty else { return }
            groups.append(StructuredKeyword(id: groupID, name: name, kind: .container, children: roots))
        }
        let language = IPTCMediaTopicsLanguage.resolve(override: document.languageOverride,
                                                       preferredLanguages: preferredLanguages)
        append(StructuredKeywordLibraryDocument.iptcID, UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
               "IPTC Media Topics", vocabulary?.tree(language: language) ?? [])
        append(StructuredKeywordLibraryDocument.legacyID, UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
               "My Keywords", myKeywords)
        for list in document.lists {
            append(list.id, UUID(uuidString: list.id) ?? UUID(), list.name, StructuredKeywordParser.parseString(list.text))
        }
        self.init(roots: groups)
    }

    /// Keyword ancestors, then the node, then its synonyms; containers are skipped.
    static func activation(_ path: StructuredKeywordPath) -> [String] {
        guard path.node.isKeyword else { return [] }
        return path.ancestors.filter(\.isKeyword).map(\.name) + [path.node.name] + path.node.synonyms
    }

    /// The first node in tree order whose name or synonym matches, case-insensitively.
    func activation(forName name: String) -> [String]? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        var result: [String]?
        Self.walk(roots) { node, ancestors in
            guard node.isKeyword,
                  node.name.lowercased() == needle || node.synonyms.contains(where: { $0.lowercased() == needle }) else { return true }
            result = Self.activation(StructuredKeywordPath(ancestors: ancestors, node: node))
            return false
        }
        return result
    }

    func search(_ query: String, limit: Int = 200) -> [StructuredKeywordPath] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var results: [StructuredKeywordPath] = []
        Self.walk(roots) { node, ancestors in
            guard results.count < limit else { return false }
            if node.isKeyword, node.name.lowercased().contains(needle)
                || node.synonyms.contains(where: { $0.lowercased().contains(needle) }) {
                results.append(StructuredKeywordPath(ancestors: ancestors, node: node))
            }
            return true
        }
        return results
    }

    /// Prefix matches first, then substring matches, each alphabetical; case- and
    /// diacritic-insensitive, as in Photo Agent's keyword typeahead.
    func suggestions(for text: String, limit: Int = 12) -> [KeywordSuggestion] {
        let prefix = Self.normalize(text)
        guard !prefix.isEmpty else { return [] }
        var prefixMatches: [String] = []
        var substringMatches: [String] = []
        for entry in searchableNames {
            let normalized = Self.normalize(entry)
            if normalized.hasPrefix(prefix) { prefixMatches.append(entry) }
            else if normalized.contains(prefix) { substringMatches.append(entry) }
            if prefixMatches.count + substringMatches.count >= limit * 4 { break }
        }
        let order: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let leading = prefixMatches.sorted(by: order).prefix(limit).map { KeywordSuggestion(value: $0, matchKind: .prefix) }
        let trailing = substringMatches.sorted(by: order).prefix(max(0, limit - leading.count))
            .map { KeywordSuggestion(value: $0, matchKind: .substring) }
        return leading + trailing
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Depth-first in tree order; the visitor returns false to stop.
    static func walk(_ roots: [StructuredKeyword],
                     _ visit: (StructuredKeyword, [StructuredKeyword]) -> Bool) {
        func descend(_ node: StructuredKeyword, _ ancestors: [StructuredKeyword]) -> Bool {
            guard visit(node, ancestors) else { return false }
            for child in node.children where !descend(child, ancestors + [node]) { return false }
            return true
        }
        for root in roots where !descend(root, []) { return }
    }
}
