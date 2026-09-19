import Foundation
import SwiftUI

/// A confirmation is tied to the exact draft shown to the user. Changing the
/// draft while a dialog is open invalidates that confirmation instead of replacing
/// newer choices with an old snapshot. This helper never persists or does a lookup.
struct MetadataGeocodingAppleConsent {
    enum ConsentError: LocalizedError {
        case draftChanged
        var errorDescription: String? { "Geocoding choices changed while confirmation was open. Select Apple again to review the current choices." }
    }
    let original: MetadataGeocodingSettings?

    func confirmed(current: MetadataGeocodingSettings?) throws -> MetadataGeocodingSettings {
        guard current == original else { throw ConsentError.draftChanged }
        var updated = try current ?? MetadataGeocodingSettings(localeIdentifier: "en")
        try updated.selectProvider(.apple, allowSendingCoordinatesToApple: true)
        return updated
    }
}

/// Draft controls never persist the displayed default locale merely because this section opens.
struct MetadataGeocodingSettingsView: View {
    @Binding var settings: MetadataGeocodingSettings?
    let savedJob: SyncJob?
    @State private var errorMessage: String?
    @State private var confirmsApple = false
    @State private var appleConsent: MetadataGeocodingAppleConsent?
    @State private var showsGeofenceEditor = false

    private static let languages = ["en", "nb", "nn", "sv", "da", "fi", "de", "fr", "es", "it", "pt", "nl", "pl", "uk", "ja", "ko", "zh", "ar"]
        .filter { MetadataGeocodingService.Query(latitude: 0, longitude: 0, locale: $0) != nil }

    private var locales: [String] {
        var values = Set(Self.languages)
        if let selected = settings?.localeIdentifier { values.insert(selected) }
        return values.sorted { localeName($0).localizedStandardCompare(localeName($1)) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Location provider", selection: Binding(
                get: { settings?.provider ?? .offline },
                set: { value in selectProvider(value) })) {
                Text("Offline GeoNames").tag(MetadataGeocodingProviderSelection.offline)
                Text("Apple online").tag(MetadataGeocodingProviderSelection.apple)
            }
            .accessibilityIdentifier("geocoding-provider")
            .help("Apple online requires explicit permission to send image coordinates and a network connection.")
            Toggle("Resolve place variables", isOn: Binding(
                get: { settings?.resolveVariables ?? false },
                set: { value in update { $0.resolveVariables = value } }))
                .accessibilityIdentifier("geocoding-resolve-variables")
            Text("Allow {gps:city} and {gps:country} to use the selected provider when a metadata template requests them. This does not write city or country fields by itself.")
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
            HStack {
                Button("Edit Named Areas…") { showsGeofenceEditor = true }
                    .accessibilityIdentifier("edit-geofences")
                if let count = settings?.geofences.count, count > 0 {
                    Text("\(count) saved in this job draft")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("A named area replaces City and {gps:city} when the image GPS point is inside its polygon. Country still uses the selected provider when requested. Outside named areas, the selected provider supplies both names.")
                .font(.caption).foregroundStyle(.secondary)
            if settings?.provider == .apple {
                Text("Apple online sends coordinates from each applicable image to Apple and requires a network connection. It uses the selected place-name language and does not request this Mac’s device location. Only saved, enabled choices are used for processing.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Offline GeoNames finds the nearest settlement within 50 km; it does not determine administrative borders. Country names use the selected language, while city names retain the dataset’s spelling. No network request is made.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Writing City or Country does not require a metadata schedule. Choosing a provider alone does not enable either field or variable resolution.")
                .font(.caption).foregroundStyle(.secondary)
            Text(settings == nil ? "Geocoding is off. English is shown as a default; no setting is created until you make a choice." : "Save the job to apply these choices. Use Preview Saved Metadata to inspect existing destination files before explicitly reprocessing them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Clear Geocoding Choices") { settings = nil; errorMessage = nil }
                    .disabled(settings == nil)
                    .accessibilityIdentifier("clear-geocoding-settings")
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showsGeofenceEditor) {
            MetadataGeofenceEditorView(geofences: Binding(
                get: { settings?.geofences ?? [] },
                set: { areas in update { $0.geofences = areas } }))
        }
        .confirmationDialog("Allow image coordinates to be sent to Apple?", isPresented: $confirmsApple, titleVisibility: .visible) {
            Button("Use Apple and Allow Coordinates") {
                guard let consent = appleConsent else { return }
                do {
                    settings = try consent.confirmed(current: settings)
                    errorMessage = nil
                } catch { errorMessage = error.localizedDescription }
                appleConsent = nil
            }
            Button("Cancel", role: .cancel) { appleConsent = nil }
        } message: {
            Text("Apple online looks up place names using GPS coordinates supplied by your image files. Those coordinates are sent to Apple over the network when a lookup is needed. This does not request or track your Mac’s device location. Confirming changes only this job draft; save the job before processing with Apple.")
        }
        .onChange(of: savedJob) { _, _ in appleConsent = nil; confirmsApple = false }
        .onDisappear { appleConsent = nil; confirmsApple = false }
    }

    private func selectProvider(_ provider: MetadataGeocodingProviderSelection) {
        if provider == .apple {
            guard settings?.provider != .apple || settings?.allowSendingCoordinatesToApple != true else { return }
            appleConsent = MetadataGeocodingAppleConsent(original: settings)
            confirmsApple = true
        } else {
            do {
                var updated = try settings ?? MetadataGeocodingSettings(localeIdentifier: "en")
                try updated.selectProvider(.offline)
                settings = updated
                appleConsent = nil
                confirmsApple = false
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
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

}

/// Saved processing actions shared by scheduled, location-only and face-only jobs.
struct SavedMetadataProcessingActionsView: View {
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

    private var savedActionsAvailable: Bool {
        guard !hasUnsavedChanges, previewTask == nil, !store.isSuspendedForExternalWriter,
              let job = savedJob,
              job.metadataAutomation?.isEnabled == true || job.metadataGeocoding?.isEnabled == true || job.metadataFaceRecognition != nil,
              store.metadataFaceRecognitionRuntimeBlocker(for: job) == nil,
              job.direction != .bidirectional, job.destinationEndpoint?.kind == .local,
              !store.isJobBusy(job.id), store.jobs.first(where: { $0.id == job.id }) == job else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if previewTask != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel Preview", action: cancelPreview)
                        .accessibilityIdentifier("cancel-geocoding-preview")
                } else {
                    Button("Preview Saved Metadata…", action: startPreview)
                        .disabled(!savedActionsAvailable)
                        .accessibilityIdentifier("preview-geocoding")
                    Button("Reprocess Saved Files…") { confirmsReprocess = true }
                        .disabled(!savedActionsAvailable)
                        .accessibilityIdentifier("reprocess-geocoding")
                }
            }
            if hasUnsavedChanges {
                Text("Save the job before previewing or reprocessing its saved settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let job = savedJob, let blocker = store.metadataFaceRecognitionRuntimeBlocker(for: job) {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
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
            Text("Matching files in \(savedJob?.localDestinationDisplayPath ?? "the saved local destination") will be processed using the saved metadata schedule and enabled geocoding and face recognition. Fill-empty choices preserve existing values; overwrite choices replace them. Source files are untouched and modification dates are retained. Preview first to inspect the proposed changes.")
        }
        .onChange(of: savedJob) { _, _ in cancelPreview(); preview = nil; confirmsReprocess = false }
        .onChange(of: hasUnsavedChanges) { _, changed in
            if changed { cancelPreview(); preview = nil; confirmsReprocess = false }
        }
        .onChange(of: store.isSuspendedForExternalWriter) { _, suspended in
            if suspended { cancelPreview(); preview = nil; confirmsReprocess = false }
        }
        .onDisappear { cancelPreview() }
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
        let faceRecognitionContext = store.faceRecognitionContext
        previewTask = Task {
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let access = try BookmarkAccess(endpoint: endpoint)
                    defer { withExtendedLifetime(access) {} }
                    let folder = try MetadataPreviewService.localFolderURL(selectedRoot: access.url,
                        usesManagedFolderStructure: job.usesManagedFolderStructure)
                    let result = try await MetadataPreviewService.previewLocalFolder(
                        at: folder, savedJob: job, faceRecognitionContext: faceRecognitionContext)
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
