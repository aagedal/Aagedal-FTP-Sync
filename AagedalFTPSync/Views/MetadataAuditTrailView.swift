import SwiftUI

struct MetadataAuditTrailView: View {
    let entries: [MetadataAuditEntry]

    private var newestFirst: [MetadataAuditEntry] {
        entries.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    private var report: MetadataRunReport {
        MetadataRunReport(entries: entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                auditCount("Applied", count: report.applied)
                auditCount("Skipped", count: report.skipped)
                auditCount("Failed", count: report.failed)
                Spacer()
            }

            if newestFirst.isEmpty {
                ContentUnavailableView(
                    "No Metadata Activity",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Per-file decisions appear here after a sync or reprocess run.")
                )
            } else {
                List(newestFirst) { entry in
                    MetadataAuditRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Metadata audit trail")
    }

    private func auditCount(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count.formatted()).font(.title3.monospacedDigit()).fontWeight(.semibold)
            Text(title).font(.caption).foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MetadataAuditRow: View {
    let entry: MetadataAuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.relativePath).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(entry.occurredAt, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(contextText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.primary)
                }

                if let evidence = entry.processingEvidence {
                    DisclosureGroup("Processing details") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MetadataAuditEvidencePresentation.processingTime(evidence))
                            Text(MetadataAuditEvidencePresentation.captureAssumption(evidence))
                            if let decision = evidence.coordinateDecision {
                                Text(MetadataAuditEvidencePresentation.coordinateDecision(decision))
                            }
                            if let decision = evidence.geocodingDecision {
                                Text(MetadataAuditEvidencePresentation.geocodingDecision(decision))
                            }
                            ForEach((evidence.placeFields ?? [:]).keys.sorted(), id: \.self) { key in
                                if let outcome = evidence.placeFields?[key] {
                                    Text("\(key.capitalized): \(MetadataAuditEvidencePresentation.fieldOutcome(outcome))")
                                }
                            }
                            Text(evidence.resolutionComplete
                                 ? "Field resolution completed. The file result above reports writing and delivery."
                                 : "Field resolution was incomplete; affected fields were preserved.")
                            ForEach(evidence.fields.keys.sorted(), id: \.self) { key in
                                if let outcome = evidence.fields[key] {
                                    Text("\(MetadataWritableField(rawValue: key)?.title ?? key): \(MetadataAuditEvidencePresentation.fieldOutcome(outcome))")
                                }
                            }
                        }
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .accessibilityLabel("Processing details for \(entry.relativePath)")
                }

                if let evidence = entry.recognitionEvidence {
                    DisclosureGroup("Recognition details") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MetadataAuditEvidencePresentation.recognitionDecision(evidence))
                            Text(MetadataAuditEvidencePresentation.recognitionProvenance(evidence.provenance))
                        }
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .accessibilityLabel("Recognition details for \(entry.relativePath)")
                }

                ForEach(Array(entry.swiftExifWarnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .labelStyle(AccessibleStatusLabelStyle(symbolColor: .orange))
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private var contextText: String {
        var parts = [entry.operation.title, entry.timestampPolicy.title]
        if let photographerName = entry.photographerName, !photographerName.isEmpty {
            parts.append(photographerName)
        }
        if let clipName = entry.clipName, !clipName.isEmpty {
            parts.append(clipName)
        }
        if let scheduledAt = entry.scheduledAt {
            parts.append(scheduledAt.formatted(date: .abbreviated, time: .standard))
        }
        return parts.joined(separator: " · ")
    }

    private var statusSymbol: String {
        switch entry.status {
        case .applied: "checkmark.circle.fill"
        case .skipped: "forward.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .applied: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }
}

enum MetadataAuditEvidencePresentation {
    static func recognitionDecision(_ evidence: FaceRecognitionAuditEvidence) -> String {
        switch evidence.status {
        case .completed:
            guard let counts = evidence.outcomes else { return "Recognition completed without outcome counts." }
            return "Recognition completed: \(counts.detectedFaces) faces; \(counts.accepted) accepted, \(counts.noMatch) unmatched, \(counts.ambiguous) ambiguous, \(counts.insufficientQuality) below quality, \(counts.qualityUnavailable) without quality, \(counts.invalidQuality) invalid."
        case .unavailable:
            let reason: String
            switch evidence.unavailableReason {
            case .unverifiedPreprocessingContract: reason = "the preprocessing contract is unverified"
            case .componentUnavailable: reason = "the model component is unavailable"
            case .peopleLibraryUnavailable: reason = "the people library is unavailable"
            case .acceptancePolicyUnavailable: reason = "the calibrated acceptance policy is unavailable"
            case nil: reason = "no reason was recorded"
            }
            return "Recognition was unavailable: \(reason)."
        case .rejected, .failed:
            let prefix = evidence.status == .rejected ? "Recognition was rejected" : "Recognition failed"
            let reason: String
            switch evidence.failureReason {
            case .invalidMaximumFaces: reason = "invalid face limit"
            case .invalidLimits: reason = "invalid resource limits"
            case .invalidStagedInputByteCount: reason = "invalid staged input size"
            case .stagedInputLeaseAlreadySubmitted: reason = "staged input was already submitted"
            case .queueLimitExceeded: reason = "analysis queue limit exceeded"
            case .pendingByteLimitExceeded: reason = "staged byte limit exceeded"
            case .galleryPeopleLimitExceeded: reason = "people count limit exceeded"
            case .galleryEmbeddingLimitExceeded: reason = "reference embedding limit exceeded"
            case .galleryComparisonLimitExceeded: reason = "comparison limit exceeded"
            case .faceLimitExceeded: reason = "detected face limit exceeded"
            case .invalidFaceOrdinals: reason = "invalid analyzer result ordering"
            case .invalidCaptureQuality: reason = "invalid analyzer quality value"
            case .operationFailed: reason = "local analysis failed"
            case .matchingFailed: reason = "local matching failed"
            case .deadlineExceeded: reason = "analysis deadline exceeded"
            case nil: reason = "no reason was recorded"
            }
            var bounds: [String] = []
            if let maximum = evidence.maximum { bounds.append("maximum \(maximum)") }
            if let actual = evidence.actual { bounds.append("actual \(actual)") }
            if let pending = evidence.pending { bounds.append("pending \(pending)") }
            if let requested = evidence.requested { bounds.append("requested \(requested)") }
            return prefix + ": " + reason + (bounds.isEmpty ? "." : " (" + bounds.joined(separator: ", ") + ").")
        case .cancelled:
            return "Recognition was cancelled."
        }
    }

    static func recognitionProvenance(_ provenance: FaceRecognitionAuditEvidence.Provenance) -> String {
        "Recognition provenance: model \(provenance.modelID), component \(provenance.componentID), preprocessing \(provenance.preprocessingRevision), embedding space \(provenance.embeddingSpaceVersion), \(provenance.vectorEncoding)/\(provenance.embeddingDimension), library schema \(provenance.librarySchemaVersion), runtime \(provenance.runtimeRevision), policy \(provenance.acceptancePolicyRevision)."
    }

    static func processingTime(_ evidence: MetadataProcessingAuditEvidence) -> String {
        let savedZone = TimeZone(identifier: evidence.processingTimeZoneIdentifier)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = savedZone ?? TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let zoneDescription = savedZone == nil
            ? "UTC; recorded zone is unavailable: \(evidence.processingTimeZoneIdentifier)"
            : evidence.processingTimeZoneIdentifier
        return "Processing time: \(formatter.string(from: evidence.processingDate)) (\(zoneDescription))"
    }

    static func captureAssumption(_ evidence: MetadataProcessingAuditEvidence) -> String {
        guard let capture = evidence.captureAssumption else {
            return "Original capture time was not required or was unavailable."
        }
        switch capture.source {
        case .explicitOffset:
            return "Original capture used its recorded offset: \(capture.timeZoneIdentifier)."
        case .persistedFallback:
            return "Original capture had no offset; assumed saved job zone: \(capture.timeZoneIdentifier)."
        }
    }

    static func geocodingDecision(_ decision: MetadataProcessingAuditEvidence.GeocodingDecision) -> String {
        let status: String
        switch decision.status {
        case .missingCoordinates: status = "Place lookup unavailable: no valid complete GPS pair."
        case .found: status = "Place lookup completed; field proposals are shown separately."
        case .noResult: status = "Place lookup found no result."
        case .tooDistant: status = "Nearest place exceeded the permitted distance."
        case .invalidProviderResult: status = "Place lookup returned invalid data."
        case .providerFailure: status = "Place lookup failed."
        case .backoff: status = "Place lookup paused after an earlier failure."
        case .overloaded: status = "Place lookup queue was full."
        case .deadlineExceeded: status = "Place lookup timed out."
        case .cancelled: status = "Place lookup was cancelled."
        }
        var details = [status]
        if let locale = decision.localeIdentifier { details.append("Language: " + locale + ".") }
        if let provider = decision.provider { details.append("Provider: " + provider + ".") }
        if let distance = decision.distanceMeters { details.append(String(format: "Nearest settlement: %.1f km away.", locale: Locale(identifier: "en_US_POSIX"), distance / 1_000)) }
        if let version = decision.version { details.append("Version: " + version + ".") }
        if let dataset = decision.dataset { details.append("Dataset: " + dataset + ".") }
        return details.joined(separator: " ")
    }

    static func coordinateDecision(_ decision: MetadataProcessingAuditEvidence.CoordinateDecision) -> String {
        func name(_ source: MetadataProcessingAuditEvidence.CoordinateDecision.Source) -> String {
            switch source {
            case .embeddedEXIF: return "embedded camera GPS"
            case .xmp: return "XMP GPS"
            case .scheduled: return "scheduled GPS"
            }
        }
        var parts = [decision.selectedSource.map { "Selected location: " + name($0) + "." } ?? "No valid location selected."]
        if decision.existingConflict { parts.append("Embedded camera GPS and XMP GPS disagree.") }
        if !decision.invalidSources.isEmpty {
            parts.append("Invalid location data: " + decision.invalidSources.map(name).joined(separator: ", ") + ".")
        }
        switch decision.scheduledDisposition {
        case .absent: parts.append("No scheduled location supplied.")
        case .invalid: parts.append("Invalid scheduled location was omitted.")
        case .preservedExisting: parts.append("Existing location preserved by field policy.")
        case .filledEmpty: parts.append("Scheduled location proposed for an empty or invalid location.")
        case .overwroteExisting: parts.append("Scheduled replacement proposed under overwrite policy.")
        }
        return parts.joined(separator: " ")
    }

    static func fieldOutcome(_ outcome: MetadataProcessingAuditEvidence.FieldOutcome) -> String {
        switch outcome.status {
        case .proposed: return "Resolved proposal (not proof of a successful write)"
        case .notRequested: return "No value requested"
        case .preservedByPolicy: return "Existing value preserved by field policy"
        case .omitted:
            let variables = outcome.variables.map { variable in
                switch variable {
                case "captureDate": return "capture date"
                case "processingDate": return "processing date"
                case "photographer": return "photographer"
                case "city": return "city"
                case "country": return "country"
                case "persons": return "people shown"
                default: return variable
                }
            }.joined(separator: ", ")
            switch outcome.reason {
            case .missingValues: return "Omitted; missing \(variables.isEmpty ? "required values" : variables)"
            case .invalidDate: return "Omitted; invalid date\(variables.isEmpty ? "" : ": " + variables)"
            case .outputByteLimit, .writerByteLimit:
                return "Omitted; exceeds \(outcome.limit.map(String.init) ?? "the allowed") bytes"
            case .keywordEntryLimit:
                return "Omitted; exceeds \(outcome.limit.map(String.init) ?? "the allowed") keyword entries"
            case .invalidGPSPosition: return "Omitted; invalid scheduled GPS position"
            case .invalidXMLCharacter: return "Omitted; unsupported XML character"
            case nil: return "Omitted; no reason was recorded"
            }
        }
    }
}
