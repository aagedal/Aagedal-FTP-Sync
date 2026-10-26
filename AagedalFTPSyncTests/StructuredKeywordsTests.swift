import MetadataTemplates
import XCTest
@testable import AagedalFTPSync

/// Cases mirror Aagedal Photo Agent's parser and library tests so both apps read
/// the same Lists folder identically.
final class StructuredKeywordsTests: XCTestCase {
    func testTabIndentSynonymsRelatedKeywordsAndContainers() {
        let roots = StructuredKeywordParser.parseString("""
        animals
        \t{animal}
        \tlivestock
        \t\tcattle
        \t\t\t{cows}
        \tpets
        reptile
        \t[ALLIGATOR & CROCODILES]
        \t\t{Crocodilia}
        \t\talligators
        \t\t\t#swamp
        """)
        XCTAssertEqual(roots.map(\.name), ["animals", "reptile"])
        XCTAssertEqual(roots[0].synonyms, ["animal"])
        XCTAssertEqual(roots[0].children.map(\.name), ["livestock", "pets"])
        XCTAssertEqual(roots[0].children[0].children[0].synonyms, ["cows"])
        let container = roots[1].children[0]
        XCTAssertTrue(container.isContainer)
        XCTAssertEqual(container.name, "ALLIGATOR & CROCODILES")
        XCTAssertEqual(container.synonyms, ["Crocodilia"])
        XCTAssertEqual(container.children[0].relatedKeywords, ["swamp"])
    }

    func testLineEndingsInvisibleCharactersOrphansAndSpaceIndent() {
        XCTAssertEqual(StructuredKeywordParser.parseString("animals\r\n\tlivestock\r\n").first?.children.map(\.name), ["livestock"])
        let cleaned = StructuredKeywordParser.parseString("\u{FEFF}animals\n\tlive\u{00A0}stock\n")
        XCTAssertEqual(cleaned.first?.name, "animals")
        XCTAssertEqual(cleaned.first?.children.first?.name, "live stock")
        let orphans = StructuredKeywordParser.parseString("{orphan}\n#orphan\nanimals\n")
        XCTAssertEqual(orphans.map(\.name), ["animals"])
        XCTAssertTrue(orphans[0].synonyms.isEmpty && orphans[0].relatedKeywords.isEmpty)
        let spaced = StructuredKeywordParser.parseString("animals\n    livestock\n        cattle\n")
        XCTAssertEqual(spaced[0].children[0].children.map(\.name), ["cattle"])
        XCTAssertTrue(StructuredKeywordParser.parseString("").isEmpty)
    }

    func testActivationAddsKeywordAncestorsNodeAndSynonymsButNoContainers() {
        let roots = StructuredKeywordParser.parseString("""
        animals
        \tlivestock
        \t\tcattle
        \t\t\tcow
        \t\t\t\t{cows}
        \t\t\t\t{kine}
        reptile
        \t[ALLIGATOR & CROCODILES]
        \t\talligators
        """)
        let catalog = StructuredKeywordCatalog(roots: roots)
        XCTAssertEqual(catalog.activation(forName: "KINE"), ["animals", "livestock", "cattle", "cow", "cows", "kine"])
        XCTAssertEqual(catalog.activation(forName: "alligators"), ["reptile", "alligators"])
        XCTAssertNil(catalog.activation(forName: "ALLIGATOR & CROCODILES"))
        XCTAssertEqual(catalog.search("all").map(\.node.name), ["alligators"])
    }

    func testActiveListsAreWrappedSoListNamesNeverBecomeKeywords() throws {
        let listID = UUID().uuidString
        let document = try StructuredKeywordLibraryDocument.decode(Data("""
        {"activeIDs":["legacy-keywords","\(listID)"],"lists":[{"id":"\(listID)","name":"Sport","text":"football\\n\\t{soccer}\\n"},
         {"id":"\(UUID().uuidString)","name":"Inactive","text":"hidden\\n"}],"mode":"multiple","schemaVersion":1}
        """.utf8))
        let catalog = StructuredKeywordCatalog(document: document,
            myKeywords: StructuredKeywordParser.parseString("politikk\n\tvalg\n"), vocabulary: nil)
        XCTAssertEqual(catalog.roots.map(\.name), ["My Keywords", "Sport"])
        XCTAssertTrue(catalog.roots.allSatisfy(\.isContainer))
        XCTAssertEqual(catalog.activation(forName: "soccer"), ["football", "soccer"])
        XCTAssertEqual(catalog.activation(forName: "valg"), ["politikk", "valg"])
        XCTAssertNil(catalog.activation(forName: "hidden"))
        XCTAssertFalse(catalog.searchableNames.contains("Sport"))
    }

    func testLibraryDocumentRejectsUnsupportedOrInconsistentFiles() {
        let id = UUID().uuidString
        let invalid = [
            #"{"activeIDs":[],"lists":[],"mode":"multiple","schemaVersion":2}"#,
            #"{"activeIDs":["unknown"],"lists":[],"mode":"multiple","schemaVersion":1}"#,
            #"{"activeIDs":["iptc-media-topics","legacy-keywords"],"lists":[],"mode":"single","schemaVersion":1}"#,
            #"{"activeIDs":[],"lists":[{"id":"not-a-uuid","name":"A","text":""}],"mode":"multiple","schemaVersion":1}"#,
            #"{"activeIDs":[],"lists":[{"id":"\#(id)","name":" ","text":""}],"mode":"multiple","schemaVersion":1}"#,
            #"{"activeIDs":[],"languageOverride":"xx","lists":[],"mode":"multiple","schemaVersion":1}"#,
            "not json",
        ]
        for text in invalid {
            XCTAssertThrowsError(try StructuredKeywordLibraryDocument.decode(Data(text.utf8)), text)
        }
        XCTAssertEqual(try StructuredKeywordLibraryDocument.decode(Data(#"{"activeIDs":["iptc-media-topics"],"languageOverride":"no-NB","lists":[],"mode":"single","schemaVersion":1}"#.utf8)).languageOverride, "no-NB")
    }

    func testBundledIPTCMediaTopicsFollowLanguageAndDefaultsToActive() throws {
        let vocabulary = try IPTCMediaTopics.bundled()
        XCTAssertEqual(vocabulary.roots.count, 17)
        let catalog = StructuredKeywordCatalog(document: .init(), myKeywords: [], vocabulary: vocabulary,
                                               preferredLanguages: ["nb-NO"])
        XCTAssertEqual(catalog.roots.map(\.name), ["IPTC Media Topics"])
        XCTAssertEqual(catalog.roots[0].children.count, 17)
        XCTAssertEqual(IPTCMediaTopicsLanguage.resolve(override: nil, preferredLanguages: ["sv-SE"]), .swedish)
        XCTAssertEqual(IPTCMediaTopicsLanguage.resolve(override: "de", preferredLanguages: ["nb-NO"]), .german)
    }

    func testSuggestionsRankPrefixBeforeSubstringIgnoringCaseAndDiacritics() {
        let catalog = StructuredKeywordCatalog(roots: StructuredKeywordParser.parseString("Malmö\nSalmon\nmalt\n\t{Malting}\n"))
        let suggestions = catalog.suggestions(for: "MALM")
        XCTAssertEqual(suggestions.map(\.value), ["Malmö"])
        XCTAssertEqual(catalog.suggestions(for: "alm").map(\.value), ["Malmö", "Salmon"])
        XCTAssertEqual(catalog.suggestions(for: "malt").map(\.value), ["malt", "Malting"])
        XCTAssertEqual(catalog.suggestions(for: "malt").map(\.matchKind), [.prefix, .prefix])
        XCTAssertTrue(catalog.suggestions(for: "  ").isEmpty)
    }

    func testTypedKeywordsSplitOnCommasAndSemicolonsAndSkipDuplicates() {
        XCTAssertEqual(MetadataTemplateKeywordsDraft.parts(of: " Oslo, Bergen; ;{photographer} "), ["Oslo", "Bergen", "{photographer}"])
        XCTAssertEqual(MetadataTemplateKeywordsDraft.appending(["Oslo", "oslo", "Bergen", "Oslo"], to: ["Oslo"]),
                       ["Oslo", "oslo", "Bergen"])
    }
}
