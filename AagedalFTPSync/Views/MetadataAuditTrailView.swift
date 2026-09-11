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
            case .invalidXMLCharacter: return "Omitted; unsupported XML character"
            case nil: return "Omitted; no reason was recorded"
            }
        }
    }
}
