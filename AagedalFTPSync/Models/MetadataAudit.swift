import CryptoKit
import Foundation
import MetadataTemplates

enum MetadataAuditStatus: String, Codable, CaseIterable, Sendable {
    case applied
    case skipped
    case failed
}

enum MetadataAuditOperation: String, Codable, Sendable {
    case transfer
    case reprocess

    var title: String {
        switch self {
        case .transfer: "Transfer"
        case .reprocess: "Reprocess"
        }
    }
}

/// Resolution evidence only: this is not proof of writing or publication. Retains
/// dependency identifiers and assumptions, never template source or resolved values.
struct MetadataProcessingAuditEvidence: Codable, Equatable, Sendable {
    /// Deliberately excludes numeric coordinates and conflicting coordinate pairs.
    struct CoordinateDecision: Codable, Equatable, Sendable {
        enum Source: String, Codable, Sendable { case embeddedEXIF, xmp, scheduled }
        enum ScheduledDisposition: String, Codable, Sendable {
            case absent, invalid, preservedExisting, filledEmpty, overwroteExisting
        }
        let selectedSource: Source?
        let existingConflict: Bool
        let invalidSources: [Source]
        let scheduledDisposition: ScheduledDisposition

        init(_ resolution: EffectiveMetadataCoordinates.Resolution) {
            func source(_ value: EffectiveMetadataCoordinates.Source) -> Source {
                switch value {
                case .embeddedEXIF: return .embeddedEXIF
                case .xmp: return .xmp
                case .scheduled: return .scheduled
                }
            }
            selectedSource = resolution.selected.map { source($0.source) }
            existingConflict = resolution.existingConflict != nil
            invalidSources = resolution.invalidSources.map(source).sorted { $0.rawValue < $1.rawValue }
            switch resolution.scheduledDisposition {
            case .absent: scheduledDisposition = .absent
            case .invalid: scheduledDisposition = .invalid
            case .preservedExisting: scheduledDisposition = .preservedExisting
            case .filledEmpty: scheduledDisposition = .filledEmpty
            case .overwroteExisting: scheduledDisposition = .overwroteExisting
            }
        }
    }

    /// Provider decisions and immutable identity only; never names or coordinates.
    struct GeocodingDecision: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case missingCoordinates, found, noResult, tooDistant, invalidProviderResult
            case providerFailure, backoff, overloaded, deadlineExceeded, cancelled
        }
        let status: Status
        let localeIdentifier: String?
        let provider: String?
        let version: String?
        let dataset: String?
        let distanceMeters: Double?

        init?(result: MetadataProcessingResult) {
            localeIdentifier = result.geocodingLocaleIdentifier
            var identity = result.geocodingProviderIdentity
            var distance: Double?
            switch result.geocoding {
            case .notRequested: return nil
            case .missingCoordinates: status = .missingCoordinates
            case .lookup(let outcome):
                switch outcome {
                case .found(let place, let source): status = .found; identity = source; distance = place.distanceMeters
                case .noResult: status = .noResult
                case .tooDistant: status = .tooDistant
                case .invalidProviderResult: status = .invalidProviderResult
                case .providerFailure: status = .providerFailure
                case .backoff: status = .backoff
                case .overloaded: status = .overloaded
                case .deadlineExceeded: status = .deadlineExceeded
                case .cancelled: status = .cancelled
                }
            }
            provider = identity?.provider
            version = identity?.version
            dataset = identity?.dataset
            distanceMeters = distance
        }
    }

    struct CaptureAssumption: Codable, Equatable, Sendable {
        enum Source: String, Codable, Sendable { case explicitOffset, persistedFallback }
        let source: Source
        let timeZoneIdentifier: String
        let secondsFromGMT: Int?
    }

    struct FieldOutcome: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case proposed, notRequested, preservedByPolicy, omitted }
        enum Reason: String, Codable, Sendable {
            case missingValues, invalidDate, outputByteLimit, keywordEntryLimit, writerByteLimit, invalidXMLCharacter, invalidGPSPosition
        }
        let status: Status
        let reason: Reason?
        let variables: [String]
        let limit: Int?

        fileprivate init(_ outcome: MetadataProcessingFieldOutcome) {
            var reason: Reason?
            var variables: [String] = []
            var limit: Int?
            switch outcome {
            case .proposed: status = .proposed
            case .notRequested: status = .notRequested
            case .preservedByPolicy: status = .preservedByPolicy
            case .omitted(let omission):
                status = .omitted
                switch omission {
                case .invalidGPSPosition: reason = .invalidGPSPosition
                case .invalidXMLCharacter: reason = .invalidXMLCharacter
                case .writerByteLimit(let maximum): reason = .writerByteLimit; limit = maximum
                case .template(let failure):
                    switch failure {
                    case .missingValues(let missing):
                        reason = .missingValues; variables = missing.map(\.rawValue).sorted()
                    case .invalidDate(let variable): reason = .invalidDate; variables = [variable.rawValue]
                    case .outputLimitExceeded(let maximum): reason = .outputByteLimit; limit = maximum
                    case .keywordEntryLimitExceeded(let maximum): reason = .keywordEntryLimit; limit = maximum
                    }
                }
            }
            self.reason = reason
            self.variables = variables
            self.limit = limit
        }
    }

    let processingDate: Date
    let processingTimeZoneIdentifier: String
    let captureAssumption: CaptureAssumption?
    let fields: [String: FieldOutcome]
    let resolutionComplete: Bool
    let coordinateDecision: CoordinateDecision?
    let geocodingDecision: GeocodingDecision?
    let placeFields: [String: FieldOutcome]?

    /// Literal processing has no frozen template context and keeps its old audit shape.
    init?(result: MetadataProcessingResult) {
        guard let context = result.context else { return nil }
        processingDate = context.processingDate
        processingTimeZoneIdentifier = context.processingTimeZone.identifier
        if let capture = context.captureDate {
            switch capture.zoneSource {
            case .explicitOffset(let seconds):
                captureAssumption = CaptureAssumption(source: .explicitOffset,
                    timeZoneIdentifier: capture.timeZone.identifier, secondsFromGMT: seconds)
            case .persistedFallback(let identifier):
                captureAssumption = CaptureAssumption(source: .persistedFallback,
                    timeZoneIdentifier: identifier, secondsFromGMT: nil)
            }
        } else { captureAssumption = nil }
        fields = Dictionary(uniqueKeysWithValues: result.fields.map { ($0.key.rawValue, FieldOutcome($0.value)) })
        resolutionComplete = result.resolutionComplete
        coordinateDecision = result.coordinateResolution.map(CoordinateDecision.init)
        geocodingDecision = GeocodingDecision(result: result)
        placeFields = result.places.isEmpty ? nil : Dictionary(uniqueKeysWithValues: result.places.map { field, outcome in
            let mapped: MetadataProcessingFieldOutcome
            switch outcome {
            case .notRequested: mapped = .notRequested
            case .preservedByPolicy: mapped = .preservedByPolicy
            case .proposed: mapped = .proposed
            case .unavailable: mapped = .omitted(.template(.missingValues([field == .city ? .city : .country])))
            case .invalidValue(let reason): mapped = .omitted(reason)
            }
            return (field.rawValue, FieldOutcome(mapped))
        })
    }
}

/// Strictly redacted durable evidence for one local recognition decision.
///
/// This projection deliberately retains no names, person/library identifiers,
/// embeddings, scores, face geometry, file paths, or provider error text. The
/// compatibility and policy revisions are sufficient to distinguish immutable
/// processing inputs without identifying the selected people-library snapshot.
struct FaceRecognitionAuditEvidence: Codable, Equatable, Sendable {
    struct Provenance: Codable, Equatable, Sendable {
        enum ValidationError: Error, Equatable { case invalidRuntimeRevision }

        let librarySchemaVersion: Int
        let embeddingSpaceVersion: Int
        let componentID: String
        let modelID: String
        let preprocessingRevision: String
        let vectorEncoding: String
        let embeddingDimension: Int
        /// SHA-256 of the admitted runtime artifact, never a local model path.
        let runtimeRevision: String
        /// SHA-256 of the exact calibrated policy values, never raw thresholds.
        let acceptancePolicyRevision: String

        init(
            contract: PeopleLibraryManifest.EmbeddingContract,
            runtimeRevision: String,
            acceptancePolicy: FaceRecognitionAcceptancePolicy
        ) throws {
            guard runtimeRevision.utf8.count == 64,
                  runtimeRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw ValidationError.invalidRuntimeRevision }
            librarySchemaVersion = 2
            embeddingSpaceVersion = contract.embeddingSpaceVersion
            componentID = contract.componentID
            modelID = contract.modelID
            preprocessingRevision = contract.preprocessingRevision
            vectorEncoding = contract.vectorEncoding
            embeddingDimension = contract.dimension
            self.runtimeRevision = runtimeRevision
            acceptancePolicyRevision = Self.policyRevision(acceptancePolicy)
        }

        private static func policyRevision(_ policy: FaceRecognitionAcceptancePolicy) -> String {
            func hex(_ value: Double) -> String {
                let source = String(value.bitPattern, radix: 16)
                return String(repeating: "0", count: 16 - source.count) + source
            }
            let quality = policy.unavailableQualityPolicy == .reject ? "reject" : "allow"
            let canonical = [
                "face-acceptance-policy-v1",
                hex(policy.maximumCosineDistance),
                hex(policy.minimumRunnerUpGap),
                hex(policy.minimumCaptureQuality),
                quality
            ].joined(separator: "\n")
            return SHA256.hash(data: Data(canonical.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    struct OutcomeCounts: Codable, Equatable, Sendable {
        let detectedFaces: Int
        let accepted: Int
        let noMatch: Int
        let ambiguous: Int
        let insufficientQuality: Int
        let qualityUnavailable: Int
        let invalidQuality: Int

        fileprivate init(_ outcomes: [FaceRecognitionMatchOutcome]) {
            var accepted = 0, noMatch = 0, ambiguous = 0, insufficientQuality = 0
            var qualityUnavailable = 0, invalidQuality = 0
            for outcome in outcomes {
                switch outcome {
                case .accepted: accepted += 1
                case .noMatch: noMatch += 1
                case .ambiguous: ambiguous += 1
                case .insufficientQuality: insufficientQuality += 1
                case .qualityUnavailable: qualityUnavailable += 1
                case .invalidQuality: invalidQuality += 1
                }
            }
            detectedFaces = outcomes.count
            self.accepted = accepted
            self.noMatch = noMatch
            self.ambiguous = ambiguous
            self.insufficientQuality = insufficientQuality
            self.qualityUnavailable = qualityUnavailable
            self.invalidQuality = invalidQuality
        }
    }

    enum Status: String, Codable, Sendable { case completed, unavailable, rejected, failed, cancelled }
    enum UnavailableReason: String, Codable, Sendable {
        case unverifiedPreprocessingContract, componentUnavailable
        case peopleLibraryUnavailable, acceptancePolicyUnavailable
    }
    enum FailureReason: String, Codable, Sendable {
        case invalidMaximumFaces, invalidLimits, invalidStagedInputByteCount
        case stagedInputLeaseAlreadySubmitted, queueLimitExceeded, pendingByteLimitExceeded
        case galleryPeopleLimitExceeded, galleryEmbeddingLimitExceeded
        case galleryComparisonLimitExceeded, faceLimitExceeded, invalidFaceOrdinals
        case invalidCaptureQuality, operationFailed, matchingFailed, deadlineExceeded
    }

    let status: Status
    let outcomes: OutcomeCounts?
    let unavailableReason: UnavailableReason?
    let failureReason: FailureReason?
    /// Redacted resource-bound context. These values are aggregate counts only.
    let maximum: Int?
    let actual: Int?
    let pending: Int?
    let requested: Int?
    let provenance: Provenance

    init(result: FaceRecognitionAnalysisResult, provenance: Provenance) {
        self.provenance = provenance
        outcomes = {
            guard case .completed(let values, _) = result else { return nil }
            return OutcomeCounts(values)
        }()
        unavailableReason = {
            guard case .unavailable(let reason) = result else { return nil }
            switch reason {
            case .unverifiedPreprocessingContract: return .unverifiedPreprocessingContract
            case .componentUnavailable: return .componentUnavailable
            case .peopleLibraryUnavailable: return .peopleLibraryUnavailable
            case .acceptancePolicyUnavailable: return .acceptancePolicyUnavailable
            }
        }()

        var mappedFailure: FailureReason?
        var maximum: Int?, actual: Int?, pending: Int?, requested: Int?
        let error: FaceRecognitionAnalysisError?
        switch result {
        case .completed: status = .completed; error = nil
        case .unavailable: status = .unavailable; error = nil
        case .rejected(let value): status = .rejected; error = value
        case .failed(let value): status = .failed; error = value
        case .cancelled: status = .cancelled; error = nil
        }
        if let error {
            switch error {
            case .invalidMaximumFaces: mappedFailure = .invalidMaximumFaces
            case .invalidLimits: mappedFailure = .invalidLimits
            case .invalidStagedInputByteCount: mappedFailure = .invalidStagedInputByteCount
            case .stagedInputLeaseAlreadySubmitted: mappedFailure = .stagedInputLeaseAlreadySubmitted
            case .queueLimitExceeded(let value): mappedFailure = .queueLimitExceeded; maximum = value
            case .pendingByteLimitExceeded(let limit, let current, let request):
                mappedFailure = .pendingByteLimitExceeded; maximum = limit; pending = current; requested = request
            case .galleryPeopleLimitExceeded(let limit, let count):
                mappedFailure = .galleryPeopleLimitExceeded; maximum = limit; actual = count
            case .galleryEmbeddingLimitExceeded(let limit, let count):
                mappedFailure = .galleryEmbeddingLimitExceeded; maximum = limit; actual = count
            case .galleryComparisonLimitExceeded(let limit, let count):
                mappedFailure = .galleryComparisonLimitExceeded; maximum = limit; actual = count
            case .faceLimitExceeded(let limit, let count):
                mappedFailure = .faceLimitExceeded; maximum = limit; actual = count
            case .invalidFaceOrdinals: mappedFailure = .invalidFaceOrdinals
            case .invalidCaptureQuality:
                // The face ordinal is intentionally omitted. Persisted evidence
                // records only the typed validation failure, not per-face detail.
                mappedFailure = .invalidCaptureQuality
            case .operationFailed: mappedFailure = .operationFailed
            case .matchingFailed: mappedFailure = .matchingFailed
            case .deadlineExceeded: mappedFailure = .deadlineExceeded
            }
        }
        failureReason = mappedFailure
        self.maximum = maximum
        self.actual = actual
        self.pending = pending
        self.requested = requested
    }
}

/// A privacy-preserving receipt for one completely published metadata result.
///
/// Each revision is a SHA-256 digest of a length-delimited canonical payload. The
/// receipt deliberately stores neither template text, coordinates, people-library
/// identifiers, local paths nor resolved metadata values. Source evidence retains
/// the same size/date meaning as `SourceFileSignature`; it is not presented as a
/// content hash. Output evidence is content-hashed so a later user edit can be
/// distinguished from a result that is merely stale because policy changed.
struct MetadataProcessingFingerprint: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    enum Freshness: String, Codable, Equatable, Sendable {
        case current
        case sourceChanged
        case settingsChanged
        case dependenciesChanged
        case outputChanged
    }

    struct OutputArtifact: Sendable {
        let role: String
        let relativePath: String
        let fileURL: URL

        init(role: String, relativePath: String, fileURL: URL) {
            self.role = role
            self.relativePath = relativePath
            self.fileURL = fileURL
        }
    }

    let sourceRevision: String
    let settingsRevision: String
    let dependencyRevision: String
    let outputRevision: String

    init(
        sourceFile: SyncFile,
        sourceSidecar: SyncFile?,
        assignment: MetadataAssignment?,
        geocoding: MetadataGeocodingSettings?,
        faceRecognition: MetadataFaceRecognitionSettings?,
        timestampPolicy: MetadataTimestampPolicy,
        processingTimeZone: TimeZone,
        dependencyRevisions: [String: String] = [:],
        outputArtifacts: [OutputArtifact]
    ) throws {
        sourceRevision = Self.sourceRevision(primary: sourceFile, companion: sourceSidecar)
        settingsRevision = try Self.settingsRevision(
            assignment: assignment,
            geocoding: geocoding,
            faceRecognition: faceRecognition,
            timestampPolicy: timestampPolicy,
            processingTimeZone: processingTimeZone
        )
        dependencyRevision = Self.dependencyRevision(dependencyRevisions)
        outputRevision = try Self.outputRevision(outputArtifacts)
    }

    func freshness(
        sourceRevision currentSourceRevision: String,
        settingsRevision currentSettingsRevision: String,
        dependencyRevision currentDependencyRevision: String,
        outputRevision currentOutputRevision: String
    ) -> Freshness {
        if sourceRevision != currentSourceRevision { return .sourceChanged }
        if settingsRevision != currentSettingsRevision { return .settingsChanged }
        if dependencyRevision != currentDependencyRevision { return .dependenciesChanged }
        if outputRevision != currentOutputRevision { return .outputChanged }
        return .current
    }

    static func sourceRevision(primary: SyncFile, companion: SyncFile?) -> String {
        var canonical = CanonicalDigest(domain: "metadata-source-v1")
        canonical.appendFile(role: "primary", file: primary)
        canonical.appendOptional(companion) { digest, file in
            digest.appendFile(role: "companion", file: file)
        }
        return canonical.finalize()
    }

    static func settingsRevision(
        assignment: MetadataAssignment?,
        geocoding: MetadataGeocodingSettings?,
        faceRecognition: MetadataFaceRecognitionSettings?,
        timestampPolicy: MetadataTimestampPolicy,
        processingTimeZone: TimeZone
    ) throws -> String {
        var canonical = CanonicalDigest(domain: "metadata-settings-v1")
        canonical.append(timestampPolicy.rawValue)
        canonical.append(processingTimeZone.identifier)
        try canonical.appendOptional(assignment) { digest, assignment in
            let request = try MetadataProcessingRequest(assignment: assignment)
            digest.append(assignment.photographer.id.uuidString)
            digest.append(assignment.photographer.name)
            digest.append(request.creator)
            digest.append(request.photographer)
            digest.appendTemplate(request.copyright)
            digest.append(assignment.clip.id.uuidString)
            digest.append(assignment.clip.name)
            digest.append(assignment.clip.startsAt)
            digest.append(assignment.clip.endsAt)
            digest.appendTemplate(request.headline)
            digest.appendTemplate(request.description)
            digest.appendTemplate(request.keywords)
            digest.appendOptional(request.gpsPosition) { digest, position in
                digest.append(position.latitude)
                digest.append(position.longitude)
                digest.append(position.altitudeMeters)
                digest.append(position.label)
            }
            for field in request.existingFieldPolicy.overwriteFields.map(\.rawValue).sorted() {
                digest.append(field)
            }
        }
        canonical.appendOptional(geocoding?.isEnabled == true ? geocoding : nil) { digest, settings in
            digest.append(settings.provider == .offline ? "offline" : "apple")
            digest.append(settings.resolveVariables)
            digest.append(settings.cityPolicy.rawValue)
            digest.append(settings.countryPolicy.rawValue)
            digest.append(settings.localeIdentifier)
            digest.append(settings.allowSendingCoordinatesToApple)
        }
        canonical.appendOptional(faceRecognition) { digest, settings in
            digest.append(settings.appendToKeywords)
        }
        return canonical.finalize()
    }

    static func dependencyRevision(_ revisions: [String: String]) -> String {
        var canonical = CanonicalDigest(domain: "metadata-dependencies-v1")
        for key in revisions.keys.sorted() {
            canonical.append(key)
            canonical.append(revisions[key]!)
        }
        return canonical.finalize()
    }

    static func outputRevision(_ artifacts: [OutputArtifact]) throws -> String {
        var canonical = CanonicalDigest(domain: "metadata-output-v1")
        for artifact in artifacts.sorted(by: {
            if $0.role != $1.role { return $0.role < $1.role }
            return $0.relativePath < $1.relativePath
        }) {
            canonical.append(artifact.role)
            canonical.append(artifact.relativePath)
            canonical.append(try contentRevision(at: artifact.fileURL))
        }
        return canonical.finalize()
    }

    private static func contentRevision(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sourceRevision, settingsRevision, dependencyRevision, outputRevision
    }

    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Processing fingerprint fields are incomplete or unsupported."
            ))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported processing fingerprint version."
            )
        }
        sourceRevision = try values.decode(String.self, forKey: .sourceRevision)
        settingsRevision = try values.decode(String.self, forKey: .settingsRevision)
        dependencyRevision = try values.decode(String.self, forKey: .dependencyRevision)
        outputRevision = try values.decode(String.self, forKey: .outputRevision)
        guard [sourceRevision, settingsRevision, dependencyRevision, outputRevision].allSatisfy(Self.isSHA256) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Processing fingerprint revisions must be lowercase SHA-256 values."
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        guard [sourceRevision, settingsRevision, dependencyRevision, outputRevision].allSatisfy(Self.isSHA256) else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Processing fingerprint revisions must be lowercase SHA-256 values."
            ))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(sourceRevision, forKey: .sourceRevision)
        try values.encode(settingsRevision, forKey: .settingsRevision)
        try values.encode(dependencyRevision, forKey: .dependencyRevision)
        try values.encode(outputRevision, forKey: .outputRevision)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct CanonicalDigest {
        private var data = Data()

        init(domain: String) { append(domain) }

        mutating func append(_ value: String) {
            appendBytes(Data(value.utf8))
        }

        mutating func append(_ value: String?) {
            appendOptional(value) { digest, value in digest.append(value) }
        }

        mutating func append(_ value: Bool) { append(value ? "true" : "false") }
        mutating func append(_ value: Date) { append(value.timeIntervalSince1970.bitPattern.description) }
        mutating func append(_ value: Double) { append(value.bitPattern.description) }
        mutating func append(_ value: Double?) {
            appendOptional(value) { digest, value in digest.append(value) }
        }

        mutating func appendFile(role: String, file: SyncFile) {
            append(role)
            append(file.relativePath)
            append(String(file.size))
            append(file.modifiedAt)
        }

        mutating func appendTemplate(_ value: MetadataTemplateText) {
            append(value.source)
            append(value.templateVersion.map(String.init))
        }

        mutating func appendTemplate(_ value: MetadataTemplateKeywords) {
            append(value.templateVersion.map(String.init))
            append(String(value.source.count))
            for keyword in value.source { append(keyword) }
        }

        mutating func appendOptional<Value>(
            _ value: Value?,
            body: (inout CanonicalDigest, Value) throws -> Void
        ) rethrows {
            guard let value else { append("nil"); return }
            append("some")
            try body(&self, value)
        }

        mutating private func appendBytes(_ value: Data) {
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(value)
        }

        func finalize() -> String { SHA256.hash(data: data).hexString }
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// One durable record of the metadata decision made for a file.
///
/// Names are stored alongside identifiers so an audit remains readable after a
/// photographer or timeline clip is renamed or removed.
struct MetadataAuditEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let runID: UUID
    let jobID: UUID
    let occurredAt: Date
    let operation: MetadataAuditOperation
    let relativePath: String
    let status: MetadataAuditStatus
    let timestampPolicy: MetadataTimestampPolicy
    let scheduledAt: Date?
    let photographerID: UUID?
    let photographerName: String?
    let clipID: UUID?
    let clipName: String?
    let swiftExifWarnings: [String]
    let detail: String?
    let processingEvidence: MetadataProcessingAuditEvidence?
    let processingFingerprint: MetadataProcessingFingerprint?
    let recognitionEvidence: FaceRecognitionAuditEvidence?

    init(
        id: UUID = UUID(),
        runID: UUID,
        jobID: UUID,
        occurredAt: Date = Date(),
        operation: MetadataAuditOperation,
        relativePath: String,
        status: MetadataAuditStatus,
        timestampPolicy: MetadataTimestampPolicy,
        scheduledAt: Date?,
        assignment: MetadataAssignment? = nil,
        matchedPhotographer: PhotographerProfile? = nil,
        matchedClip: MetadataScheduleClip? = nil,
        swiftExifWarnings: [String] = [],
        detail: String? = nil,
        processingEvidence: MetadataProcessingAuditEvidence? = nil,
        processingFingerprint: MetadataProcessingFingerprint? = nil,
        recognitionEvidence: FaceRecognitionAuditEvidence? = nil
    ) {
        self.id = id
        self.runID = runID
        self.jobID = jobID
        self.occurredAt = occurredAt
        self.operation = operation
        self.relativePath = relativePath
        self.status = status
        self.timestampPolicy = timestampPolicy
        self.scheduledAt = scheduledAt
        let photographer = assignment?.photographer ?? matchedPhotographer
        let clip = assignment?.clip ?? matchedClip
        photographerID = photographer?.id
        photographerName = photographer?.name
        clipID = clip?.id
        clipName = clip?.name
        self.swiftExifWarnings = Self.uniqueWarnings(swiftExifWarnings)
        self.detail = detail
        self.processingEvidence = processingEvidence
        self.processingFingerprint = processingFingerprint
        self.recognitionEvidence = recognitionEvidence
    }

    private static func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            let normalized = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }
}

struct MetadataRunReport: Codable, Equatable, Sendable {
    var entries: [MetadataAuditEntry]

    init(entries: [MetadataAuditEntry] = []) {
        self.entries = entries
    }

    static let empty = MetadataRunReport()

    var applied: Int { count(.applied) }
    var skipped: Int { count(.skipped) }
    var failed: Int { count(.failed) }
    var hasActivity: Bool { !entries.isEmpty }

    mutating func append(_ entry: MetadataAuditEntry) {
        entries.append(entry)
    }

    mutating func append(contentsOf other: MetadataRunReport) {
        entries.append(contentsOf: other.entries)
    }

    private func count(_ status: MetadataAuditStatus) -> Int {
        entries.lazy.filter { $0.status == status }.count
    }
}

extension MetadataAutomation {
    /// Resolves the same preferred filename-prefix match used for assignment,
    /// even when no clip covers the scheduling timestamp. This lets skipped
    /// audit entries still identify the photographer whose prefix matched.
    func matchingPhotographer(for relativePath: String) -> PhotographerProfile? {
        guard isEnabled else { return nil }
        return photographers
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
