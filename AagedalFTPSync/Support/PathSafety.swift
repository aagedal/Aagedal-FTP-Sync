import Foundation

enum PathSafety {
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
}
