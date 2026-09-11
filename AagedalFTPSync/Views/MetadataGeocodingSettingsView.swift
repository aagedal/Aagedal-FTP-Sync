import Foundation
import SwiftUI

/// Draft controls only. Preview/reprocess explicitly use the saved job and never
/// persist the displayed default locale merely because this section was opened.
struct MetadataGeocodingSettingsView: View {
    @Binding var settings: MetadataGeocodingSettings?
    @ObservedObject var store: AppStore
    let savedJob: SyncJob?
    let hasUnsavedChanges: Bool
    @State private var errorMessage: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRequestID: UUID?
    @State private var preview: PreviewPresentation?
    @State private var confirmsReprocess = false

    private struct PreviewPresentation: Identifiable, Sendable {
        let id = UUID()
        let folderName: String
        let timestampPolicy: MetadataTimestampPolicy
        let result: MetadataPreviewResult
    }

    private static let languages = ["en", "nb", "nn", "sv", "da", "fi", "de", "fr", "es", "it", "pt", "nl", "pl", "uk", "ja", "ko", "zh", "ar"]
        .filter { MetadataGeocodingService.Query(latitude: 0, longitude: 0, locale: $0) != nil }

    private var locales: [String] {
        var values = Set(Self.languages)
        if let selected = settings?.localeIdentifier { values.insert(selected) }
        return values.sorted { localeName($0).localizedStandardCompare(localeName($1)) == .orderedAscending }
    }

    private var savedActionsAvailable: Bool {
        guard !hasUnsavedChanges, previewTask == nil, !store.isSuspendedForExternalWriter,
              let job = savedJob, settings == job.metadataGeocoding,
              job.metadataGeocoding?.isEnabled == true,
              job.direction != .bidirectional, job.destinationEndpoint?.kind == .local,
              !store.isJobBusy(job.id), store.jobs.first(where: { $0.id == job.id }) == job else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Resolve place variables", isOn: Binding(
                get: { settings?.resolveVariables ?? false },
                set: { value in update { $0.resolveVariables = value } }))
                .accessibilityIdentifier("geocoding-resolve-variables")
            Text("Allow {gps:city} and {gps:country} to use an offline lookup when a metadata template requests them. This does not write city or country fields by itself.")
                .font(.caption).foregroundStyle(.secondary)
            policyPicker("Write city", keyPath: \.cityPolicy, identifier: "geocoding-city-policy")
            policyPicker("Write country", keyPath: \.countryPolicy, identifier: "geocoding-country-policy")
            Picker("Place-name language", selection: Binding(
                get: { settings?.localeIdentifier ?? "en" },
                set: { value in update { $0.localeIdentifier = value } })) {
                ForEach(locales, id: \.self) { identifier in
                    Text(localeName(identifier)).tag(identifier)
                }
            }
            .accessibilityIdentifier("geocoding-language")
            Text("Offline GeoNames finds the nearest settlement within 50 km; it does not determine administrative borders. Country names use the selected language, while city names retain the dataset’s spelling. No network request or schedule is required to write place fields.")
                .font(.caption).foregroundStyle(.secondary)
            Text(settings == nil ? "Geocoding is off. English is shown as a default; no setting is created until you make a choice." : "Save the job to apply these choices. Use Preview Geocoding to inspect existing destination files before explicitly reprocessing them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Clear Geocoding Choices") { settings = nil; errorMessage = nil }
                    .disabled(settings == nil || previewTask != nil)
                    .accessibilityIdentifier("clear-geocoding-settings")
                Spacer()
                if previewTask != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel Preview", action: cancelPreview)
                        .accessibilityIdentifier("cancel-geocoding-preview")
                } else {
                    Button("Preview Geocoding…", action: startPreview)
                        .disabled(!savedActionsAvailable)
                        .accessibilityIdentifier("preview-geocoding")
                    Button("Reprocess Saved Files…") { confirmsReprocess = true }
                        .disabled(!savedActionsAvailable)
                        .accessibilityIdentifier("reprocess-geocoding")
                }
            }
            if hasUnsavedChanges || settings != savedJob?.metadataGeocoding {
                Text("Save the job before previewing or reprocessing its saved settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .sheet(item: $preview) { presentation in
            MetadataFolderPreviewView(folderName: presentation.folderName,
                timestampPolicy: presentation.timestampPolicy, result: presentation.result)
        }
        .confirmationDialog("Reprocess existing local files?", isPresented: $confirmsReprocess, titleVisibility: .visible) {
            Button("Reprocess Saved Files") {
                guard savedActionsAvailable, let job = savedJob else { return }
                store.reprocessExistingLocalFiles(job.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Matching files in \(savedJob?.localDestinationDisplayPath ?? "the saved local destination") will be processed using the saved geocoding choices and any enabled saved metadata schedule. Fill-empty choices preserve existing values; overwrite choices replace them. Source files are untouched and modification dates are retained. Preview first to inspect the proposed changes.")
        }
        .onChange(of: settings) { _, _ in cancelPreview() }
        .onChange(of: savedJob) { _, _ in cancelPreview(); preview = nil }
        .onChange(of: hasUnsavedChanges) { _, changed in if changed { cancelPreview() } }
        .onChange(of: store.isSuspendedForExternalWriter) { _, suspended in if suspended { cancelPreview() } }
        .onDisappear { cancelPreview() }
    }

    private func policyPicker(_ title: String, keyPath: WritableKeyPath<MetadataGeocodingSettings, MetadataPlaceFieldPolicy>, identifier: String) -> some View {
        Picker(title, selection: Binding(
            get: { settings?[keyPath: keyPath] ?? .disabled },
            set: { value in update { $0[keyPath: keyPath] = value } })) {
            Text("Disabled").tag(MetadataPlaceFieldPolicy.disabled)
            Text("Fill empty only").tag(MetadataPlaceFieldPolicy.fillEmpty)
            Text("Overwrite").tag(MetadataPlaceFieldPolicy.overwrite)
        }
        .accessibilityIdentifier(identifier)
    }

    private func localeName(_ identifier: String) -> String {
        "\(Locale.current.localizedString(forIdentifier: identifier) ?? identifier) (\(identifier))"
    }

    private func update(_ change: (inout MetadataGeocodingSettings) -> Void) {
        do {
            var updated = try settings ?? MetadataGeocodingSettings(localeIdentifier: "en")
            change(&updated)
            try updated.validate()
            settings = updated
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func cancelPreview() {
        previewRequestID = nil
        previewTask?.cancel()
        previewTask = nil
    }

    private func startPreview() {
        guard savedActionsAvailable, let job = savedJob, let endpoint = job.destinationEndpoint else { return }
        let requestID = UUID()
        previewRequestID = requestID
        errorMessage = nil
        previewTask = Task {
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let access = try BookmarkAccess(endpoint: endpoint)
                    defer { withExtendedLifetime(access) {} }
                    let folder = try MetadataPreviewService.localFolderURL(selectedRoot: access.url,
                        usesManagedFolderStructure: job.usesManagedFolderStructure)
                    let result = try await MetadataPreviewService.previewLocalFolder(
                        at: folder, automation: job.metadataAutomation, geocoding: job.metadataGeocoding,
                        service: MetadataProcessingServices.shared.offlineGeocoding, filter: job.filter,
                        processingTimeZone: try job.validatedMetadataProcessingTimeZone)
                    return PreviewPresentation(folderName: folder.lastPathComponent,
                        timestampPolicy: job.metadataAutomation?.timestampPolicy ?? .sourceModification, result: result)
                }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, previewRequestID == requestID else { return }
                preview = result
            } catch is CancellationError {
                // Cancellation is a user action, not a metadata error.
            } catch {
                if previewRequestID == requestID { errorMessage = error.localizedDescription }
            }
            if previewRequestID == requestID {
                previewRequestID = nil
                previewTask = nil
            }
        }
    }
}
