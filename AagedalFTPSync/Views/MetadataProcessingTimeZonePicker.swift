import Foundation
import SwiftUI

/// A search only produces choices. A concrete identifier reaches the draft only
/// through the explicit selection action, and the job's Save button persists it.
enum MetadataProcessingTimeZoneChoices {
    static func identifiers(matching search: String, including selected: String? = nil) -> [String] {
        var identifiers = Set(TimeZone.knownTimeZoneIdentifiers)
        identifiers.insert("Etc/UTC")
        if let selected, TimeZone(identifier: selected) != nil { identifiers.insert(selected) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifiers.filter { identifier in
            query.isEmpty || identifier.replacingOccurrences(of: "_", with: " ")
                .localizedCaseInsensitiveContains(query)
                || identifier.localizedCaseInsensitiveContains(query)
        }.sorted()
    }
}

struct MetadataProcessingTimeZonePicker: View {
    let selectedIdentifier: String?
    let savedIdentifier: String?
    let hasActivatedTemplates: Bool
    let onSelect: (String?) throws -> Void
    @State private var showsSearch = false
    @State private var selectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Processing time zone") {
                HStack {
                    Text(selectedIdentifier ?? "Not set")
                        .textSelection(.enabled)
                        .accessibilityIdentifier("metadata-processing-zone-value")
                    Button("Choose…") { showsSearch = true }
                        .accessibilityIdentifier("choose-metadata-processing-zone")
                }
            }
            HStack {
                Button("Use This Mac’s Zone") { select(TimeZone.current.identifier) }
                    .help("Choose this Mac’s current zone as a fixed setting. Future system-zone changes will not change the saved setting.")
                    .accessibilityIdentifier("use-current-metadata-processing-zone")
                Button("Clear Choice") { select(nil) }
                    .disabled(selectedIdentifier == nil || hasActivatedTemplates)
                    .help(hasActivatedTemplates ? "Jobs using metadata variables require a saved processing zone." : "Leave this literal job without a processing zone.")
                    .accessibilityIdentifier("clear-metadata-processing-zone")
                Spacer()
            }
            Text("Saved zone: \(savedIdentifier ?? "Not set")." + (selectedIdentifier != savedIdentifier ? " Save the job to apply this choice." : ""))
                .font(.caption).foregroundStyle(.secondary)
            Text("Date variables use this zone. It also interprets original camera capture times that have no recorded UTC offset; an explicit capture offset takes priority. Saving a zone changes future processing and previews. It does not reprocess existing images or change the schedule’s timestamp policy.")
                .font(.caption).foregroundStyle(.secondary)
            if selectedIdentifier == nil {
                Text("Literal metadata can leave this unset. Activating variables will save this Mac’s current zone unless you choose one first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let selectedIdentifier, TimeZone(identifier: selectedIdentifier) == nil {
                Label("The selected zone is invalid. Choose a valid time zone before saving.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if let selectionError {
                Text(selectionError).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showsSearch) {
            MetadataProcessingTimeZoneSearch(selectedIdentifier: selectedIdentifier) { identifier in
                select(identifier)
            }
        }
        .onChange(of: selectedIdentifier) { _, _ in selectionError = nil }
    }

    private func select(_ identifier: String?) {
        do {
            try onSelect(identifier)
            selectionError = nil
            showsSearch = false
        } catch {
            selectionError = "That time zone could not be selected. Choose a valid time-zone identifier."
        }
    }
}

private struct MetadataProcessingTimeZoneSearch: View {
    @Environment(\.dismiss) private var dismiss
    let selectedIdentifier: String?
    let onSelect: (String) -> Void
    @State private var search = ""
    @State private var choice: String?

    private var identifiers: [String] {
        MetadataProcessingTimeZoneChoices.identifiers(matching: search, including: selectedIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Processing Time Zone").font(.title2.weight(.semibold))
            TextField("Search region or city", text: $search, prompt: Text("Europe/Oslo, New York, UTC"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("metadata-processing-zone-search")
            if identifiers.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(identifiers, id: \.self, selection: $choice) { identifier in
                    Text(identifier).tag(identifier)
                }
                .accessibilityIdentifier("metadata-processing-zone-results")
            }
            Text("Choose a named zone to retain its daylight-saving rules. Nothing is saved until you save the job.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Selected Zone") {
                    if let choice { onSelect(choice) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || !identifiers.contains(choice ?? ""))
                .accessibilityIdentifier("confirm-metadata-processing-zone")
            }
        }
        .padding(20)
        .frame(width: 480, height: 450)
        .onAppear { choice = selectedIdentifier }
    }
}
