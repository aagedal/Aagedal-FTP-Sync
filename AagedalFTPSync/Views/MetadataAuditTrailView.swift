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
                auditCount("Applied", count: report.applied, color: .green)
                auditCount("Skipped", count: report.skipped, color: .secondary)
                auditCount("Failed", count: report.failed, color: .red)
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

    private func auditCount(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count.formatted()).font(.title3.monospacedDigit()).fontWeight(.semibold)
            Text(title).font(.caption).foregroundStyle(color)
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
                    Text(detail).font(.caption).foregroundStyle(statusColor)
                }

                ForEach(Array(entry.swiftExifWarnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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

