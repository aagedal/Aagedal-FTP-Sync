import Foundation

enum MetadataPreviewStatus: String, Codable, Sendable {
    case willApply
    case noMatchingPhotographer
    case noScheduledClip
    case captureTimeUnavailable

    var title: String {
        switch self {
        case .willApply: "Will apply"
        case .noMatchingPhotographer: "No matching photographer"
        case .noScheduledClip: "No scheduled clip"
        case .captureTimeUnavailable: "Capture time unavailable"
        }
    }
}

struct MetadataPreviewItem: Identifiable, Equatable, Sendable {
    var id: String { relativePath }

    let relativePath: String
    let sourceModifiedAt: Date
    let scheduledAt: Date?
    let status: MetadataPreviewStatus
    let photographerID: UUID?
    let photographerName: String?
    let clipID: UUID?
    let clipName: String?
}

struct MetadataPreviewResult: Equatable, Sendable {
    let items: [MetadataPreviewItem]

    var scanned: Int { items.count }
    var willApply: Int { items.count { $0.status == .willApply } }
    var skipped: Int { scanned - willApply }
}

/// Builds the same photographer and schedule assignments used during sync without
/// writing metadata or otherwise modifying the selected folder.
enum MetadataPreviewService {
    static func previewLocalFolder(
        at folderURL: URL,
        automation: MetadataAutomation,
        filter: FileFilter = FileFilter(),
        arrivalDate: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> MetadataPreviewResult {
        let hasSecurityScope = folderURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { folderURL.stopAccessingSecurityScopedResource() }
        }

        // Preview is deliberately available before the user enables automation.
        // Validate the draft as though it were enabled, then use that enabled copy
        // so assignment behavior stays identical to the sync path.
        var enabledAutomation = automation
        enabledAutomation.isEnabled = true
        if let message = enabledAutomation.validationMessage {
            throw AppError.invalidConfiguration(message)
        }

        let root = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw AppError.invalidConfiguration("Choose a local folder to preview.")
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw AppError.folderPermissionLost("Could not read \(root.path).")
        }

        var items: [MetadataPreviewItem] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }

            let canonicalURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalURL.path.hasPrefix(root.path + "/") else { continue }
            let relativePath = String(canonicalURL.path.dropFirst(root.path.count + 1))
            guard !relativePath.isEmpty,
                  !PathSafety.isInternalStagingPath(relativePath),
                  PathSafety.isSafeRelativePath(relativePath) else { continue }

            let sourceModifiedAt = values.contentModificationDate ?? .distantPast
            guard filter.includes(path: relativePath, modifiedAt: sourceModifiedAt, now: arrivalDate) else {
                continue
            }

            let photographer = matchingPhotographer(
                for: relativePath,
                in: enabledAutomation.photographers
            )
            guard let photographer else {
                items.append(MetadataPreviewItem(
                    relativePath: relativePath,
                    sourceModifiedAt: sourceModifiedAt,
                    scheduledAt: nil,
                    status: .noMatchingPhotographer,
                    photographerID: nil,
                    photographerName: nil,
                    clipID: nil,
                    clipName: nil
                ))
                continue
            }

            guard let scheduledAt = MetadataWriter.schedulingDate(
                for: enabledAutomation.timestampPolicy,
                sourceModifiedAt: sourceModifiedAt,
                localArrivalAt: arrivalDate,
                fileURL: canonicalURL
            ) else {
                items.append(MetadataPreviewItem(
                    relativePath: relativePath,
                    sourceModifiedAt: sourceModifiedAt,
                    scheduledAt: nil,
                    status: .captureTimeUnavailable,
                    photographerID: photographer.id,
                    photographerName: photographer.photographerName,
                    clipID: nil,
                    clipName: nil
                ))
                continue
            }

            if let assignment = enabledAutomation.assignment(
                for: relativePath,
                scheduledAt: scheduledAt
            ) {
                items.append(MetadataPreviewItem(
                    relativePath: relativePath,
                    sourceModifiedAt: sourceModifiedAt,
                    scheduledAt: scheduledAt,
                    status: .willApply,
                    photographerID: assignment.photographer.id,
                    photographerName: assignment.photographer.photographerName,
                    clipID: assignment.clip.id,
                    clipName: assignment.clip.name
                ))
            } else {
                items.append(MetadataPreviewItem(
                    relativePath: relativePath,
                    sourceModifiedAt: sourceModifiedAt,
                    scheduledAt: scheduledAt,
                    status: .noScheduledClip,
                    photographerID: photographer.id,
                    photographerName: photographer.photographerName,
                    clipID: nil,
                    clipName: nil
                ))
            }
        }

        if let enumerationError {
            throw AppError.folderPermissionLost(
                "Could not finish reading \(root.path): \(enumerationError.localizedDescription)"
            )
        }

        return MetadataPreviewResult(items: items.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        })
    }

    private static func matchingPhotographer(
        for relativePath: String,
        in photographers: [PhotographerProfile]
    ) -> PhotographerProfile? {
        photographers
            .filter { $0.matches(relativePath: relativePath) }
            .sorted {
                let lhsLength = $0.matchingPrefixLength(relativePath: relativePath) ?? 0
                let rhsLength = $1.matchingPrefixLength(relativePath: relativePath) ?? 0
                if lhsLength != rhsLength {
                    return lhsLength > rhsLength
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
    }
}
