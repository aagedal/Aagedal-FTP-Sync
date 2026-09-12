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

/// Ownership token for an immutable staged source and any staged companion.
/// The worker releases the stage exactly once after all hidden work using its
/// URL has exited. Deinitialization is a fallback for a lease never submitted.
final class FaceRecognitionStagedInputLease: @unchecked Sendable {
    let imageURL: URL
    let exactByteCount: Int

    private final class ReleaseState: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        private var callback: (@Sendable () -> Void)?

        init(callback: @escaping @Sendable () -> Void) {
            self.callback = callback
        }

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed, callback != nil else { return false }
            claimed = true
            return true
        }

        func release() {
            lock.lock()
            let callback = callback
            self.callback = nil
            lock.unlock()
            callback?()
        }
    }

    fileprivate func claim() -> Bool {
        releaseState.claim()
    }

    private let releaseState: ReleaseState

    init(
        imageURL: URL,
        exactByteCount: Int,
        onRelease: @escaping @Sendable () -> Void = {}
    ) {
        self.imageURL = imageURL
        self.exactByteCount = exactByteCount
        releaseState = ReleaseState(callback: onRelease)
    }

    fileprivate func release() {
        releaseState.release()
    }

    deinit {
        releaseState.release()
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
    case invalidLimits
    case invalidStagedInputByteCount
    case stagedInputLeaseAlreadySubmitted
    case queueLimitExceeded(maximumQueuedAnalyses: Int)
    case pendingByteLimitExceeded(maximum: Int, pending: Int, requested: Int)
    case galleryPeopleLimitExceeded(maximum: Int, actual: Int)
    case galleryEmbeddingLimitExceeded(maximum: Int, actual: Int)
    case galleryComparisonLimitExceeded(maximum: Int, actual: Int)
    case faceLimitExceeded(maximum: Int, actual: Int)
    case invalidFaceOrdinals
    case invalidCaptureQuality(ordinal: Int)
    /// Deliberately does not retain provider error text, which may contain a
    /// local path or implementation detail unsuitable for persisted evidence.
    case operationFailed
    case matchingFailed
    case deadlineExceeded
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
        static let largestMaximumQueuedAnalyses = 1_024
        static let largestMaximumPendingBytes = 2_000_000_000
        static let largestDeadline: TimeInterval = 3_600
        static let largestMaximumGalleryPeople = 10_000
        static let largestMaximumGalleryEmbeddings = 100_000
        static let largestMaximumGalleryComparisons = 25_600_000
        static let standard = Limits(
            validatedMaximumFaces: 64,
            maximumQueuedAnalyses: 8,
            maximumPendingBytes: 500_000_000,
            deadline: 120,
            maximumGalleryPeople: 10_000,
            maximumGalleryEmbeddings: 100_000,
            maximumGalleryComparisons: 250_000
        )

        let maximumFaces: Int
        /// Waiting work only. One additional analysis may be active.
        let maximumQueuedAnalyses: Int
        /// Total immutable staged input bytes retained by active and waiting work.
        let maximumPendingBytes: Int
        /// Elapsed time from admission through matching, including queue wait.
        let deadline: TimeInterval
        let maximumGalleryPeople: Int
        let maximumGalleryEmbeddings: Int
        /// Upper bound for face observations multiplied by gallery embeddings.
        let maximumGalleryComparisons: Int

        init(
            maximumFaces: Int,
            maximumQueuedAnalyses: Int = Limits.standard.maximumQueuedAnalyses,
            maximumPendingBytes: Int = Limits.standard.maximumPendingBytes,
            deadline: TimeInterval = Limits.standard.deadline,
            maximumGalleryPeople: Int = Limits.standard.maximumGalleryPeople,
            maximumGalleryEmbeddings: Int = Limits.standard.maximumGalleryEmbeddings,
            maximumGalleryComparisons: Int = Limits.standard.maximumGalleryComparisons
        ) throws {
            guard (1...Self.largestMaximumFaces).contains(maximumFaces) else {
                throw FaceRecognitionAnalysisError.invalidMaximumFaces
            }
            guard (0...Self.largestMaximumQueuedAnalyses).contains(maximumQueuedAnalyses),
                  (1...Self.largestMaximumPendingBytes).contains(maximumPendingBytes),
                  deadline.isFinite, deadline > 0, deadline <= Self.largestDeadline,
                  (1...Self.largestMaximumGalleryPeople).contains(maximumGalleryPeople),
                  (1...Self.largestMaximumGalleryEmbeddings).contains(maximumGalleryEmbeddings),
                  (1...Self.largestMaximumGalleryComparisons).contains(maximumGalleryComparisons)
            else { throw FaceRecognitionAnalysisError.invalidLimits }
            self.maximumFaces = maximumFaces
            self.maximumQueuedAnalyses = maximumQueuedAnalyses
            self.maximumPendingBytes = maximumPendingBytes
            self.deadline = deadline
            self.maximumGalleryPeople = maximumGalleryPeople
            self.maximumGalleryEmbeddings = maximumGalleryEmbeddings
            self.maximumGalleryComparisons = maximumGalleryComparisons
        }

        private init(
            validatedMaximumFaces: Int,
            maximumQueuedAnalyses: Int,
            maximumPendingBytes: Int,
            deadline: TimeInterval,
            maximumGalleryPeople: Int,
            maximumGalleryEmbeddings: Int,
            maximumGalleryComparisons: Int
        ) {
            maximumFaces = validatedMaximumFaces
            self.maximumQueuedAnalyses = maximumQueuedAnalyses
            self.maximumPendingBytes = maximumPendingBytes
            self.deadline = deadline
            self.maximumGalleryPeople = maximumGalleryPeople
            self.maximumGalleryEmbeddings = maximumGalleryEmbeddings
            self.maximumGalleryComparisons = maximumGalleryComparisons
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

    typealias Sleep = @Sendable (_ seconds: TimeInterval) async -> Void

    /// A deadline may return before Core ML cooperates with cancellation. The
    /// worker deliberately retains that analysis's slot and byte charge until
    /// its task actually exits, preventing late work from creating overlap.
    private actor Worker {
        typealias Work = @Sendable () async -> FaceRecognitionAnalysisResult

        private struct Item {
            let id: UUID
            let stagedInput: FaceRecognitionStagedInputLease
            let work: Work
            var continuation: CheckedContinuation<FaceRecognitionAnalysisResult, Never>?
            let timer: Task<Void, Never>
            var task: Task<Void, Never>?
        }

        private let limits: Limits
        private let sleep: Sleep
        private var active: Item?
        private var queue: [Item] = []
        private var pendingBytes = 0

        init(limits: Limits, sleep: @escaping Sleep) {
            self.limits = limits
            self.sleep = sleep
        }

        func perform(
            stagedInput: FaceRecognitionStagedInputLease,
            work: @escaping Work
        ) async -> FaceRecognitionAnalysisResult {
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        stagedInput.release()
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    admit(id: id, stagedInput: stagedInput, work: work, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
        }

        private func admit(
            id: UUID,
            stagedInput: FaceRecognitionStagedInputLease,
            work: @escaping Work,
            continuation: CheckedContinuation<FaceRecognitionAnalysisResult, Never>
        ) {
            let stagedBytes = stagedInput.exactByteCount
            guard stagedBytes <= limits.maximumPendingBytes - pendingBytes else {
                stagedInput.release()
                continuation.resume(returning: .rejected(.pendingByteLimitExceeded(
                    maximum: limits.maximumPendingBytes,
                    pending: pendingBytes,
                    requested: stagedBytes
                )))
                return
            }
            guard active == nil || queue.count < limits.maximumQueuedAnalyses else {
                stagedInput.release()
                continuation.resume(returning: .rejected(.queueLimitExceeded(
                    maximumQueuedAnalyses: limits.maximumQueuedAnalyses
                )))
                return
            }

            let delay = limits.deadline
            let sleeper = sleep
            let timer = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await sleeper(delay)
                guard !Task.isCancelled else { return }
                await self?.expire(id: id)
            }
            queue.append(Item(
                id: id,
                stagedInput: stagedInput,
                work: work,
                continuation: continuation,
                timer: timer,
                task: nil
            ))
            pendingBytes += stagedBytes
            pump()
        }

        private func pump() {
            guard active == nil, !queue.isEmpty else { return }
            var item = queue.removeFirst()
            let id = item.id
            let work = item.work
            item.task = Task.detached { [self] in
                let result = await work()
                await finish(id: id, result: result)
            }
            active = item
        }

        private func expire(id: UUID) {
            if active?.id == id {
                guard let continuation = active?.continuation else { return }
                active?.continuation = nil
                active?.task?.cancel()
                continuation.resume(returning: .failed(.deadlineExceeded))
                return
            }
            guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
            let item = queue.remove(at: index)
            pendingBytes -= item.stagedInput.exactByteCount
            item.timer.cancel()
            item.stagedInput.release()
            item.continuation?.resume(returning: .failed(.deadlineExceeded))
        }

        private func cancel(id: UUID) {
            if active?.id == id {
                guard let continuation = active?.continuation else { return }
                active?.continuation = nil
                active?.timer.cancel()
                active?.task?.cancel()
                continuation.resume(returning: .cancelled)
                return
            }
            guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
            let item = queue.remove(at: index)
            pendingBytes -= item.stagedInput.exactByteCount
            item.timer.cancel()
            item.stagedInput.release()
            item.continuation?.resume(returning: .cancelled)
        }

        private func finish(id: UUID, result: FaceRecognitionAnalysisResult) {
            guard let item = active, item.id == id else { return }
            active = nil
            pendingBytes -= item.stagedInput.exactByteCount
            item.timer.cancel()
            item.stagedInput.release()
            item.continuation?.resume(returning: result)
            pump()
        }
    }

    private struct ReadyBackend: Sendable {
        let operation: Operation
        let resolver: Resolver
        let worker: Worker
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
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) },
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
        backend = .ready(ReadyBackend(
            operation: operation,
            resolver: resolver,
            worker: Worker(limits: limits, sleep: sleep)
        ))
    }
    #endif

    var readiness: FaceRecognitionAnalysisReadiness {
        switch backend {
        case .unavailable(let reason): .unavailable(reason)
        case .ready: .ready
        }
    }

    func analyze(
        stagedInput: FaceRecognitionStagedInputLease,
        gallery: FaceRecognitionGallery,
        policy: FaceRecognitionAcceptancePolicy,
        appendAcceptedNamesToKeywords: Bool = false
    ) async -> FaceRecognitionAnalysisResult {
        guard stagedInput.claim() else {
            return .rejected(.stagedInputLeaseAlreadySubmitted)
        }
        guard !Task.isCancelled else {
            stagedInput.release()
            return .cancelled
        }
        guard case .ready(let ready) = backend else {
            stagedInput.release()
            guard case .unavailable(let reason) = backend else {
                return .failed(.operationFailed)
            }
            return .unavailable(reason)
        }

        guard stagedInput.exactByteCount > 0 else {
            stagedInput.release()
            return .rejected(.invalidStagedInputByteCount)
        }
        if let galleryError = galleryLimitError(gallery) {
            stagedInput.release()
            return .rejected(galleryError)
        }

        let operation = ready.operation
        let resolver = ready.resolver
        let limits = limits
        let imageURL = stagedInput.imageURL
        return await ready.worker.perform(stagedInput: stagedInput) {
            await Self.run(
                imageURL: imageURL,
                gallery: gallery,
                policy: policy,
                appendAcceptedNamesToKeywords: appendAcceptedNamesToKeywords,
                limits: limits,
                operation: operation,
                resolver: resolver
            )
        }
    }

    private func galleryLimitError(_ gallery: FaceRecognitionGallery) -> FaceRecognitionAnalysisError? {
        guard gallery.people.count <= limits.maximumGalleryPeople else {
            return .galleryPeopleLimitExceeded(maximum: limits.maximumGalleryPeople, actual: gallery.people.count)
        }
        var embeddingCount = 0
        for person in gallery.people {
            let (total, overflow) = embeddingCount.addingReportingOverflow(person.examples.count)
            guard !overflow, total <= limits.maximumGalleryEmbeddings else {
                return .galleryEmbeddingLimitExceeded(
                    maximum: limits.maximumGalleryEmbeddings,
                    actual: overflow ? Int.max : total
                )
            }
            embeddingCount = total
        }
        return nil
    }

    private static func run(
        imageURL: URL,
        gallery: FaceRecognitionGallery,
        policy: FaceRecognitionAcceptancePolicy,
        appendAcceptedNamesToKeywords: Bool,
        limits: Limits,
        operation: @escaping Operation,
        resolver: @escaping Resolver
    ) async -> FaceRecognitionAnalysisResult {

        let observations: [FaceRecognitionAnalysisObservation]
        do {
            observations = try await operation(imageURL, limits.maximumFaces)
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
        let embeddingCount = gallery.people.reduce(into: 0) { $0 += $1.examples.count }
        let (comparisonCount, overflow) = observations.count.multipliedReportingOverflow(by: embeddingCount)
        guard !overflow, comparisonCount <= limits.maximumGalleryComparisons else {
            return .rejected(.galleryComparisonLimitExceeded(
                maximum: limits.maximumGalleryComparisons,
                actual: overflow ? Int.max : comparisonCount
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
                    outcome = try await resolver(observation, gallery, policy)
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
