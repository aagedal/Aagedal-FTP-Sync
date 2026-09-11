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
    var existingFields: MetadataWriter.ExistingFieldsSnapshot? = nil
    var existingFieldsUnavailable = false
    var existingPlaces: MetadataWriter.ExistingPlaceFieldsSnapshot? = nil
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
                // A failed read remains explicit and does not abort the folder or
                // substitute empty values for unknown existing metadata.
                let existing = try? MetadataWriter.existingFields(at: canonicalURL, relativePath: relativePath)
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
                    detail: detail,
                    existingFields: existing,
                    existingFieldsUnavailable: existing?.readable != true
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

    /// Optional scheduling and independent geocoding share the production resolver.
    /// Unlike the original draft-only API, this overload respects isEnabled.
    static func previewLocalFolder(
        at folderURL: URL, automation: MetadataAutomation?, geocoding: MetadataGeocodingSettings?,
        service: MetadataGeocodingService? = nil,
        services: MetadataProcessingServices = .shared,
        filter: FileFilter = FileFilter(), arrivalDate: Date = Date(), processingTimeZone: TimeZone? = nil
    ) async throws -> MetadataPreviewResult {
        try Task.checkCancellation()
        guard geocoding?.isEnabled == true else {
            guard let automation, automation.isEnabled else { return .init(items: []) }
            return try previewLocalFolder(at: folderURL, automation: automation, filter: filter,
                arrivalDate: arrivalDate, processingTimeZone: processingTimeZone)
        }
        try geocoding?.validate()
        guard let processingTimeZone else {
            throw AppError.invalidConfiguration("Save a processing time zone before previewing metadata enrichment.")
        }
        let enabled = automation?.isEnabled == true ? automation : nil
        if let message = enabled?.validationMessage { throw AppError.invalidConfiguration(message) }
        let access = folderURL.startAccessingSecurityScopedResource()
        defer { if access { folderURL.stopAccessingSecurityScopedResource() } }
        let root = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AppError.invalidConfiguration("Choose a local folder to preview.")
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw AppError.folderPermissionLost("Could not read the preview folder.")
        }
        var items: [MetadataPreviewItem] = []
        while let file = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(root.path + "/") else { continue }
            let path = String(canonical.path.dropFirst(root.path.count + 1))
            guard PathSafety.isSafeRelativePath(path), !PathSafety.isInternalStagingPath(path) else { continue }
            let attributes: URLResourceValues
            do { attributes = try file.resourceValues(forKeys: keys) }
            catch {
                items.append(.init(relativePath: path, sourceModifiedAt: .distantPast, scheduledAt: nil,
                    status: .previewFailed, photographerID: nil, photographerName: nil, clipID: nil, clipName: nil,
                    detail: "Could not read this file's attributes."))
                continue
            }
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            let modified = attributes.contentModificationDate ?? .distantPast
            guard filter.includes(path: path, modifiedAt: modified, now: arrivalDate) else { continue }
            let perFileGeocoding = MetadataProcessingServices.geocodingApplies(to: path, settings: geocoding) ? geocoding : nil
            let photographer = enabled.flatMap { matchingPhotographer(for: path, in: $0.photographers) }
            let scheduled = enabled.flatMap { MetadataWriter.schedulingDate(for: $0.timestampPolicy,
                sourceModifiedAt: modified, localArrivalAt: arrivalDate, fileURL: canonical) }
            let assignment = scheduled.flatMap { enabled?.assignment(for: path, scheduledAt: $0) }
            var item = MetadataPreviewItem(relativePath: path, sourceModifiedAt: modified, scheduledAt: scheduled,
                status: .noChanges, photographerID: photographer?.id, photographerName: photographer?.photographerName,
                clipID: assignment?.clip.id, clipName: assignment?.clip.name)
            if assignment == nil && perFileGeocoding == nil {
                let status: MetadataPreviewStatus = enabled == nil ? .noChanges :
                    (photographer == nil ? .noMatchingPhotographer : (scheduled == nil ? .captureTimeUnavailable : .noScheduledClip))
                items.append(.init(relativePath: path, sourceModifiedAt: modified, scheduledAt: scheduled,
                    status: status, photographerID: photographer?.id, photographerName: photographer?.photographerName,
                    clipID: nil, clipName: nil))
                continue
            }
            item.existingFields = try? MetadataWriter.existingFields(at: canonical, relativePath: path)
            item.existingFieldsUnavailable = item.existingFields?.readable != true
            item.existingPlaces = try? MetadataWriter.existingPlaceFields(at: canonical, relativePath: path)
            var processing: MetadataProcessingResult?
            let status: MetadataPreviewStatus
            var detail: String?
            do {
                let resolved = try await MetadataProcessingCoordinator.prepare(assignment: assignment,
                    geocoding: perFileGeocoding, service: service, services: services, fileURL: canonical, relativePath: path,
                    processingDate: arrivalDate, processingTimeZone: processingTimeZone)
                processing = resolved
                if !resolved.resolutionComplete { status = .resolutionIncomplete }
                else if !resolved.hasProposedChanges { status = .noChanges }
                else {
                    switch try MetadataWriter.assess(resolved.changes, at: canonical, relativePath: path) {
                    case .willApply: status = .willApply
                    case .alreadyApplied: status = .alreadyApplied
                    case .existingMetadataPreserved: status = .existingMetadataPreserved
                    }
                }
                if enabled != nil, scheduled == nil {
                    detail = "Capture time was unavailable for scheduling. Independent location fields were still considered."
                }
            } catch is CancellationError { throw CancellationError() }
            catch { status = .previewFailed; detail = "Could not prepare this file: \(error.localizedDescription)" }
            items.append(.init(relativePath: path, sourceModifiedAt: modified, scheduledAt: scheduled,
                status: status, photographerID: item.photographerID, photographerName: item.photographerName,
                clipID: item.clipID, clipName: item.clipName, processing: processing, detail: detail,
                existingFields: item.existingFields, existingFieldsUnavailable: item.existingFieldsUnavailable,
                existingPlaces: item.existingPlaces))
        }
        try Task.checkCancellation()
        if let enumerationError { throw AppError.folderPermissionLost("Could not finish reading the preview folder: \(enumerationError.localizedDescription)") }
        return .init(items: items.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending })
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
