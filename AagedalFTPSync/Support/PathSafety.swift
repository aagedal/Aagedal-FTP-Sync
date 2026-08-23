import Foundation

enum PathSafety {
    private static let internalStagingPrefix = ".aagedal-sync-"

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\r"), !path.contains("\n") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isSafeServerName(_ name: String) -> Bool {
        isSafeRelativePath(name) && !name.contains("/")
    }

    static func isInternalStagingPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(internalStagingPrefix) }
    }

    static func localPathCollision(in paths: [String]) -> [String]? {
        var originalPathByComparisonKey: [String: String] = [:]
        for path in paths.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let comparisonKey = path
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let originalPath = originalPathByComparisonKey[comparisonKey],
               !hasIdenticalRepresentation(originalPath, path) {
                return [originalPath, path]
            }
            originalPathByComparisonKey[comparisonKey] = path
        }
        return nil
    }

    static func hasIdenticalRepresentation(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }
}
