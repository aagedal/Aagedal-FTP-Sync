import Foundation

enum MetadataPreviewStatus: String, Codable, Sendable {
    case willApply
    case resolutionIncomplete
    case previewFailed
    case noChanges
    case alreadyApplied
    case existingMetadataPreserved
    case noMatchingPhotographer
    case noScheduledClip
    case captureTimeUnavailable

    var title: String {
        switch self {
        case .willApply: "Will apply"
        case .resolutionIncomplete: "Resolution incomplete"
        case .previewFailed: "Preview failed"
        case .noChanges: "No changes proposed"
        case .alreadyApplied: "Already applied"
        case .existingMetadataPreserved: "Existing metadata preserved"
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
    var processing: MetadataProcessingResult? = nil
    var detail: String? = nil
}

struct MetadataPreviewResult: Equatable, Sendable {
    let items: [MetadataPreviewItem]

    var scanned: Int { items.count }
    var willApply: Int { items.count { $0.status == .willApply } }
    var alreadyApplied: Int { items.count { $0.status == .alreadyApplied } }
    var needsAttention: Int { items.count { $0.status == .previewFailed || $0.status == .resolutionIncomplete } }
    var skipped: Int { scanned - willApply - alreadyApplied - needsAttention }
}

/// Builds the same photographer and schedule assignments used during sync without
/// writing metadata or otherwise modifying the selected folder.
enum MetadataPreviewService {
    static func localFolderURL(
        selectedRoot: URL,
        usesManagedFolderStructure: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard usesManagedFolderStructure else { return selectedRoot }
        return try ManagedOutputFolder.syncedFiles.url(
            inside: selectedRoot,
            createIfNeeded: false,
            fileManager: fileManager
        )
    }

    static func previewLocalFolder(
        at folderURL: URL,
        automation: MetadataAutomation,
        filter: FileFilter = FileFilter(),
        arrivalDate: Date = Date(),
        processingTimeZone: TimeZone? = nil,
        fileManager: FileManager = .default
    ) throws -> MetadataPreviewResult {
        if automation.hasActivatedTemplates && processingTimeZone == nil {
            throw AppError.invalidConfiguration("Save a processing time zone before previewing activated templates.")
        }
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
            try Task.checkCancellation()
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
                var processing: MetadataProcessingResult?
                var detail: String?
                let status: MetadataPreviewStatus
                do {
                    let resolved = try MetadataProcessingCoordinator.preparePerImage(
                        assignment: assignment, fileURL: canonicalURL, relativePath: relativePath,
                        processingDate: arrivalDate, processingTimeZone: processingTimeZone ?? TimeZone(secondsFromGMT: 0)!)
                    processing = resolved
                    if !resolved.resolutionComplete {
                        status = .resolutionIncomplete
                        detail = "Some fields could not be resolved. Review the omissions before reprocessing."
                    } else if resolved.context != nil && !resolved.fields.values.contains(.proposed) {
                        status = .noChanges
                    } else {
                        let assessment = try? MetadataWriter.assess(resolved.changes, at: canonicalURL, relativePath: relativePath)
                        switch assessment {
                        case .alreadyApplied: status = .alreadyApplied
                        case .existingMetadataPreserved: status = .existingMetadataPreserved
                        case .willApply: status = .willApply
                        case nil:
                            // Keep legacy preview behavior; active resolution must not
                            // claim an assessed write when assessment failed.
                            status = resolved.context == nil ? .willApply : .previewFailed
                            if resolved.context != nil { detail = "The proposed metadata could not be assessed for this file." }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    status = .previewFailed
                    detail = "Could not prepare metadata for this file: \(error.localizedDescription)"
                }
                items.append(MetadataPreviewItem(
                    relativePath: relativePath,
                    sourceModifiedAt: sourceModifiedAt,
                    scheduledAt: scheduledAt,
                    status: status,
                    photographerID: assignment.photographer.id,
                    photographerName: assignment.photographer.photographerName,
                    clipID: assignment.clip.id,
                    clipName: assignment.clip.name,
                    processing: processing,
                    detail: detail
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
