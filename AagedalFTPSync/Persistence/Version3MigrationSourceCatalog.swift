import Darwin
import Foundation

/// Read-only source choices for an explicit migration UI. This inventories paths,
/// sizes and file kinds, not document/domain contents; it never chooses a backup,
/// creates a store, repairs a source, or performs migration. Files may change after
/// this preview: the migration driver rechecks current inventory under continuous
/// writer exclusion before acquiring/converting any selected bytes.
struct Version3MigrationSourceCatalog: Sendable {
    typealias Driver = Version3MigrationDriver
    struct Limits: Sendable {
        var maximumFiles = 8_192
        var maximumBytes = 256 * 1_048_576
        var timeout: TimeInterval = 5
    }
    struct PrimaryChoices: Sendable {
        let filename: String
        /// Existing primary first, then existing backup. Absent only when both
        /// are absent. A sole backup still requires an explicit user selection.
        let choices: [Driver.Source]
    }
    enum Failure: Error, Equatable {
        case migrationAlreadyExists, noSignatureSource, invalidSelection
    }
    let primaries: [PrimaryChoices]
    let signatureChoices: [Driver.Signatures]
    /// Includes every fixed primary/backup/companion, even when absent, and all
    /// actual maps admitted by the same scanner the driver uses at migration.
    let legacyFiles: [String]
    private let limits: Limits
    private static let mainSignatures = "original-source-signatures-v2.sqlite3"

    private init(primaries: [PrimaryChoices], signatureChoices: [Driver.Signatures], legacyFiles: [String], limits: Limits) {
        self.primaries = primaries
        self.signatureChoices = signatureChoices
        self.legacyFiles = legacyFiles
        self.limits = limits
    }

    static func inspect(root: URL, limits: Limits = Limits()) throws -> Self {
        try Driver.validateRoot(root)
        for name in [".v3-storage-boundary.json", "v3"] {
            var info = stat()
            if lstat(root.appendingPathComponent(name).path, &info) == 0 { throw Failure.migrationAlreadyExists }
            guard errno == ENOENT else { throw Driver.Failure.unsafePath }
        }
        let present = try Driver.inspectLegacyInventory(root: root, maximumFiles: limits.maximumFiles,
            maximumBytes: limits.maximumBytes, timeout: limits.timeout)
        let primaries = Version3JSONStoreConversion.primaryFilenames.sorted().map { name in
            var choices: [Driver.Source] = []
            if present.contains(name) { choices.append(.file(name)) }
            if present.contains(name + ".backup") { choices.append(.file(name + ".backup")) }
            if choices.isEmpty { choices = [.absent] }
            return PrimaryChoices(filename: name, choices: choices)
        }
        let signaturePaths = present.filter { $0.hasPrefix("original-source-signatures-") }
        var signatures: [Driver.Signatures] = []
        if present.contains(mainSignatures) {
            // Filename admission preserves a damaged SQLite primary as a visible
            // choice: never infer JSON merely because binary/header bytes failed.
            // Older versions also stored v1 JSON at this eventual SQLite path;
            // that alternative format must be selected explicitly, not guessed.
            signatures.append(.sqlite(mainSignatures))
            signatures.append(.json(mainSignatures))
        }
        for path in signaturePaths.sorted() where path != mainSignatures
            && !path.hasSuffix("-wal") && !path.hasSuffix("-shm") && !path.hasSuffix("-journal") {
            signatures.append(.json(path))
        }
        if signaturePaths.isEmpty { signatures = [.absent] }
        // Companion-only residue is evidence, never an empty signature store.
        guard !signatures.isEmpty else { throw Failure.noSignatureSource }
        let all = Driver.fixedLegacyPaths.union(present).sorted()
        guard all.count <= limits.maximumFiles else { throw Driver.Failure.limitExceeded }
        return Self(primaries: primaries, signatureChoices: signatures, legacyFiles: all, limits: limits)
    }

    /// Validates a complete explicit choice set, preserving the caller's frozen
    /// calendar and timestamp. This is not an admission receipt; the real driver
    /// validates content, inventory, companions and source selection again.
    func makePlan(primarySources: [String: Driver.Source], signatures: Driver.Signatures,
                  calendar: Calendar, migrationDate: Date) throws -> Driver.Plan {
        guard Set(primarySources.keys) == Set(primaries.map(\.filename)),
              primaries.allSatisfy({ item in primarySources[item.filename].map(item.choices.contains) == true }),
              signatureChoices.contains(signatures), migrationDate.timeIntervalSince1970.isFinite else { throw Failure.invalidSelection }
        var plan = Driver.Plan(legacyFiles: legacyFiles, primarySources: primarySources, signatures: signatures,
                               calendar: calendar, migrationDate: migrationDate)
        plan.maximumFiles = limits.maximumFiles
        plan.maximumBytes = limits.maximumBytes
        return plan
    }
}
