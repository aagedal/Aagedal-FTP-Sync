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
        originalPathByComparisonKey.reserveCapacity(paths.count)
        var collision: (first: String, second: String)?
        // Track the byte-smallest spelling per key and the best collision pair.
        // Selecting the smallest second spelling reproduces the first collision
        // in a byte-sorted scan without sorting every path in a large folder.
        for path in paths {
            let comparisonKey = localComparisonKey(path)
            guard let originalPath = originalPathByComparisonKey[comparisonKey] else {
                originalPathByComparisonKey[comparisonKey] = path
                continue
            }
            guard !hasIdenticalRepresentation(originalPath, path) else { continue }
            let pair = path.utf8.lexicographicallyPrecedes(originalPath.utf8)
                ? (first: path, second: originalPath)
                : (first: originalPath, second: path)
            originalPathByComparisonKey[comparisonKey] = pair.first
            if let current = collision {
                if pair.second.utf8.lexicographicallyPrecedes(current.second.utf8)
                    || (hasIdenticalRepresentation(pair.second, current.second)
                        && pair.first.utf8.lexicographicallyPrecedes(current.first.utf8)) {
                    collision = pair
                }
            } else {
                collision = pair
            }
        }
        return collision.map { [$0.first, $0.second] }
    }

    static func localComparisonKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func hasIdenticalRepresentation(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }
}
