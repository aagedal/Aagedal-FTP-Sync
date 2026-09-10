import Foundation

enum AppStorageFormat: Sendable {
    case legacy
    case version3
}

/// Names the related stores beneath one explicitly selected directory.
/// Constructing a layout neither creates files nor selects, validates or migrates
/// a storage version. A future migration coordinator must validate its chosen v3
/// root before injecting that same layout into every repository.
struct AppStorageLayout: Equatable, Sendable {
    let root: URL
    let storageFormat: AppStorageFormat

    init(root: URL, storageFormat: AppStorageFormat = .legacy) {
        self.root = root
        self.storageFormat = storageFormat
    }

    /// Preserve Foundation's sandbox-aware location used by the 2.x repositories.
    static var legacy: AppStorageLayout {
        AppStorageLayout(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AagedalFTPSync", isDirectory: true))
    }

    var jobs: URL { root.appendingPathComponent("jobs-v2.json") }
    var metadataPresets: URL { root.appendingPathComponent("metadata-presets-v1.json") }
    var photographers: URL { root.appendingPathComponent("photographers-v1.json") }
    var serverProfiles: URL { root.appendingPathComponent("server-profiles-v1.json") }
    var metadataCalendar: URL { root.appendingPathComponent("metadata-sync-v1.json") }
    var metadataSyncEvents: URL { root.appendingPathComponent("metadata-sync-events-v1.json") }
    var metadataAudit: URL { root.appendingPathComponent("metadata-audit-v1.json") }
    var syncFailures: URL { root.appendingPathComponent("sync-errors-v1.json") }
    var sourceSignatures: URL { root.appendingPathComponent("original-source-signatures-v2.sqlite3") }
    var legacySourceSignatures: URL { root.appendingPathComponent("original-source-signatures-v1.json") }
    var downloadManifest: URL { root.appendingPathComponent("download-manifest-v1.json") }
    var downloadNamesDirectory: URL { root.appendingPathComponent("download-names-v1", isDirectory: true) }
    var downloadNameRegistry: URL { root.appendingPathComponent("download-name-registry-v3.json") }
}
