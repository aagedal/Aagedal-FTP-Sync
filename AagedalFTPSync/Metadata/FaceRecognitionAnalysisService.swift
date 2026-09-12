import Foundation

/// One bounded result from an admitted detector/alignment/embedding pipeline.
/// The service treats names as opaque metadata values and never parses template
/// syntax from them.
struct FaceRecognitionAnalysisObservation: Equatable, Sendable {
    /// Zero-based face index assigned by the analyzer before any matching.
    let ordinal: Int
    let embedding: FaceRecognitionEmbedding
    let captureQuality: Double?

    init(ordinal: Int, embedding: FaceRecognitionEmbedding, captureQuality: Double?) {
        self.ordinal = ordinal
        self.embedding = embedding
        self.captureQuality = captureQuality
    }
}

enum FaceRecognitionAnalysisUnavailableReason: Equatable, Sendable {
    /// The checked-in model contract and the candidate model do not yet agree
    /// on preprocessing, so production analysis must remain unreachable.
    case unverifiedPreprocessingContract
    case componentUnavailable
    case peopleLibraryUnavailable
    case acceptancePolicyUnavailable
}

enum FaceRecognitionAnalysisError: Error, Equatable, Sendable {
    case invalidMaximumFaces
    case faceLimitExceeded(maximum: Int, actual: Int)
    case invalidFaceOrdinals
    case invalidCaptureQuality(ordinal: Int)
    /// Deliberately does not retain provider error text, which may contain a
    /// local path or implementation detail unsuitable for persisted evidence.
    case operationFailed
    case matchingFailed
}

enum FaceRecognitionAnalysisReadiness: Equatable, Sendable {
    case unavailable(FaceRecognitionAnalysisUnavailableReason)
    case ready
}

enum FaceRecognitionAnalysisResult: Equatable, Sendable {
    case completed(outcomes: [FaceRecognitionMatchOutcome], faceNames: ResolvedFaceNameChanges?)
    case unavailable(FaceRecognitionAnalysisUnavailableReason)
    case rejected(FaceRecognitionAnalysisError)
    case failed(FaceRecognitionAnalysisError)
    case cancelled
}

/// Pure orchestration around an injected analyzer and the calibrated matcher.
/// The default initializer is intentionally inert. A production caller must
/// admit the component, preprocessing contract, people library, and acceptance
/// policy before constructing a ready instance with an analyzer operation.
struct FaceRecognitionAnalysisService: Sendable {
    struct Limits: Equatable, Sendable {
        static let largestMaximumFaces = 256
        static let standard = Limits(validatedMaximumFaces: 64)

        let maximumFaces: Int

        init(maximumFaces: Int) throws {
            guard (1...Self.largestMaximumFaces).contains(maximumFaces) else {
                throw FaceRecognitionAnalysisError.invalidMaximumFaces
            }
            self.maximumFaces = maximumFaces
        }

        private init(validatedMaximumFaces: Int) {
            maximumFaces = validatedMaximumFaces
        }
    }

    typealias Operation = @Sendable (
        _ imageURL: URL,
        _ maximumFaces: Int
    ) async throws -> [FaceRecognitionAnalysisObservation]

    /// Async injection boundary lets the orchestrator enforce cancellation
    /// around a matcher implementation without coupling it to that runtime.
    typealias Resolver = @Sendable (
        _ observation: FaceRecognitionAnalysisObservation,
        _ gallery: FaceRecognitionGallery,
        _ policy: FaceRecognitionAcceptancePolicy
    ) async throws -> FaceRecognitionMatchOutcome

    private struct ReadyBackend: Sendable {
        let operation: Operation
        let resolver: Resolver
    }

    private enum Backend: Sendable {
        case unavailable(FaceRecognitionAnalysisUnavailableReason)
        case ready(ReadyBackend)
    }

    let limits: Limits
    private let backend: Backend

    /// Safe production foundation while model preprocessing remains unverified.
    init() {
        limits = .standard
        backend = .unavailable(.unverifiedPreprocessingContract)
    }

    init(
        unavailable reason: FaceRecognitionAnalysisUnavailableReason,
        limits: Limits = .standard
    ) {
        self.limits = limits
        backend = .unavailable(reason)
    }

    #if DEBUG
    /// Test-only injection boundary. Release builds expose no initializer that
    /// can construct a ready backend until runtime, library and calibrated-policy
    /// identities have a verified admission token.
    init(
        limits: Limits = .standard,
        resolver: @escaping Resolver = { observation, gallery, policy in
            try FaceRecognitionMatcher.matchCancellable(
                embedding: observation.embedding,
                quality: observation.captureQuality,
                gallery: gallery,
                policy: policy
            )
        },
        operation: @escaping Operation
    ) {
        self.limits = limits
        backend = .ready(ReadyBackend(operation: operation, resolver: resolver))
    }
    #endif

    var readiness: FaceRecognitionAnalysisReadiness {
        switch backend {
        case .unavailable(let reason): .unavailable(reason)
        case .ready: .ready
        }
    }

    func analyze(
        imageURL: URL,
        gallery: FaceRecognitionGallery,
        policy: FaceRecognitionAcceptancePolicy,
        appendAcceptedNamesToKeywords: Bool = false
    ) async -> FaceRecognitionAnalysisResult {
        guard !Task.isCancelled else { return .cancelled }
        guard case .ready(let ready) = backend else {
            guard case .unavailable(let reason) = backend else {
                return .failed(.operationFailed)
            }
            return .unavailable(reason)
        }

        let observations: [FaceRecognitionAnalysisObservation]
        do {
            observations = try await ready.operation(imageURL, limits.maximumFaces)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.operationFailed)
        }
        // An analyzer may ignore cancellation or its requested bound. Check both
        // invariants again before matching or publishing any accepted identity.
        guard !Task.isCancelled else { return .cancelled }
        guard observations.count <= limits.maximumFaces else {
            return .rejected(.faceLimitExceeded(
                maximum: limits.maximumFaces,
                actual: observations.count
            ))
        }
        let canonicalOrdinals = Array(0..<observations.count)
        guard observations.map(\.ordinal).sorted() == canonicalOrdinals else {
            return .rejected(.invalidFaceOrdinals)
        }
        let ordered = observations.sorted { $0.ordinal < $1.ordinal }
        guard let invalidQuality = ordered.first(where: {
            guard let quality = $0.captureQuality else { return false }
            return !quality.isFinite || !(0...1).contains(quality)
        }) else {
            var outcomes: [FaceRecognitionMatchOutcome] = []
            outcomes.reserveCapacity(ordered.count)
            var acceptedPersonIDs: Set<UUID> = []
            var acceptedNames: [String] = []
            acceptedNames.reserveCapacity(ordered.count)

            for observation in ordered {
                guard !Task.isCancelled else { return .cancelled }
                let outcome: FaceRecognitionMatchOutcome
                do {
                    outcome = try await ready.resolver(observation, gallery, policy)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(.matchingFailed)
                }
                guard !Task.isCancelled else { return .cancelled }
                outcomes.append(outcome)
                guard case .accepted(let best, _) = outcome,
                      acceptedPersonIDs.insert(best.personID).inserted else { continue }
                acceptedNames.append(best.name)
            }

            let normalizedNames = ResolvedFaceNameChanges(
                names: acceptedNames,
                appendToKeywords: appendAcceptedNamesToKeywords
            )
            guard !Task.isCancelled else { return .cancelled }
            return .completed(
                outcomes: outcomes,
                faceNames: normalizedNames.names.isEmpty ? nil : normalizedNames
            )
        }
        return .rejected(.invalidCaptureQuality(ordinal: invalidQuality.ordinal))
    }
}
