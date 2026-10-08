import Foundation
import XCTest
@testable import AagedalFTPSync

final class FaceRecognitionAnalysisServiceTests: XCTestCase {
    private typealias Service = FaceRecognitionAnalysisService
    private typealias Observation = FaceRecognitionAnalysisObservation

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private final class ReleaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var waiter: CheckedContinuation<Void, Never>?

        func release() {
            lock.lock()
            count += 1
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }

        var value: Int {
            lock.withLock { count }
        }

        func waitForRelease() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard count == 0 else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                precondition(waiter == nil)
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private actor Latch {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            guard !open else { return }
            open = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor ManualSleeper {
        private var order: [UUID] = []
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        func sleep(_: TimeInterval) async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    order.append(id)
                    waiters[id] = continuation
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func waitForCount(_ count: Int) async {
            while waiters.count < count { await Task.yield() }
        }

        func fireFirst() {
            guard let id = order.first else { return }
            order.removeFirst()
            waiters.removeValue(forKey: id)?.resume()
        }

        private func cancel(_ id: UUID) {
            order.removeAll { $0 == id }
            waiters.removeValue(forKey: id)?.resume()
        }
    }

    private enum FixtureError: Error { case failed }

    private let imageURL = URL(fileURLWithPath: "/fixture/image.jpg")

    private func vector(_ index: Int) throws -> FaceRecognitionEmbedding {
        var values = [Float](repeating: 0, count: FaceRecognitionEmbedding.dimension)
        values[index] = 1
        return try FaceRecognitionEmbedding(validatingNormalized: values)
    }

    private func person(_ ordinal: Int, name: String, vectorIndex: Int) throws -> FaceRecognitionPerson {
        let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal)))
        return try FaceRecognitionPerson(id: id, name: name, examples: [vector(vectorIndex)])
    }

    private func policy(
        minimumQuality: Double = 0.2,
        unavailableQuality: FaceRecognitionAcceptancePolicy.UnavailableQualityPolicy = .reject
    ) throws -> FaceRecognitionAcceptancePolicy {
        try FaceRecognitionAcceptancePolicy(
            maximumCosineDistance: 0.25,
            minimumRunnerUpGap: 0.1,
            minimumCaptureQuality: minimumQuality,
            unavailableQualityPolicy: unavailableQuality
        )
    }

    private func service(_ observations: [Observation]) -> Service {
        Service { _, _ in observations }
    }

    private func stagedInput(bytes: Int = 1, releaseProbe: ReleaseProbe? = nil) -> FaceRecognitionStagedInputLease {
        FaceRecognitionStagedInputLease(imageURL: imageURL, exactByteCount: bytes) {
            releaseProbe?.release()
        }
    }

    private func analyze(
        _ service: Service,
        gallery: FaceRecognitionGallery,
        policy: FaceRecognitionAcceptancePolicy,
        stagedBytes: Int = 1,
        appendAcceptedNamesToKeywords: Bool = false
    ) async -> FaceRecognitionAnalysisResult {
        await service.analyze(
            stagedInput: stagedInput(bytes: stagedBytes),
            gallery: gallery,
            policy: policy,
            appendAcceptedNamesToKeywords: appendAcceptedNamesToKeywords
        )
    }

    func testDefaultServiceIsUnavailableAndDoesNotInvokeAnalysisOperation() async throws {
        let inert = Service()
        XCTAssertEqual(inert.readiness, .unavailable(.unverifiedPreprocessingContract))
        let result = await inert.analyze(
            stagedInput: stagedInput(),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(result, .unavailable(.unverifiedPreprocessingContract))

        let explicitlyUnavailable = Service(unavailable: .componentUnavailable)
        let resultWithoutOperation = await explicitlyUnavailable.analyze(
            stagedInput: stagedInput(),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(resultWithoutOperation, .unavailable(.componentUnavailable))
    }

    func testAcceptedNamesAreStableDeduplicatedAndRemainLiteral() async throws {
        let firstName = "  {persons}, Alice  "
        let duplicateName = "{PERSONS}, ALICE"
        let literalName = "Åse, {date:YYYY-MM-DD}"
        let gallery = try FaceRecognitionGallery(people: [
            person(1, name: firstName, vectorIndex: 0),
            person(2, name: duplicateName, vectorIndex: 1),
            person(3, name: literalName, vectorIndex: 2)
        ])
        let analyzer = service([
            Observation(ordinal: 2, embedding: try vector(2), captureQuality: 1),
            Observation(ordinal: 0, embedding: try vector(0), captureQuality: 1),
            Observation(ordinal: 3, embedding: try vector(0), captureQuality: 1),
            Observation(ordinal: 1, embedding: try vector(1), captureQuality: 1)
        ])
        XCTAssertEqual(analyzer.readiness, .ready)

        let result = await analyzer.analyze(
            stagedInput: stagedInput(),
            gallery: gallery,
            policy: try policy(),
            appendAcceptedNamesToKeywords: true
        )
        guard case let .completed(outcomes, faceNames) = result else {
            return XCTFail("Expected a completed bounded analysis")
        }
        XCTAssertEqual(outcomes.count, 4)
        XCTAssertTrue(outcomes.allSatisfy { if case .accepted = $0 { return true }; return false })
        XCTAssertEqual(faceNames?.names, ["{persons}, Alice", literalName])
        XCTAssertEqual(faceNames?.appendToKeywords, true)
    }

    func testNoFaceCompletesWithoutProposingFaceNames() async throws {
        let result = await service([]).analyze(
            stagedInput: stagedInput(),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(result, .completed(outcomes: [], faceNames: nil))
    }

    func testMatcherAbstentionsRemainTypedObservationOutcomes() async throws {
        let query = try vector(0)
        let observation = Observation(ordinal: 0, embedding: query, captureQuality: 1)

        let noMatch = await service([observation]).analyze(
            stagedInput: stagedInput(),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        guard case let .completed(noMatchOutcomes, nil) = noMatch,
              let noMatchOutcome = noMatchOutcomes.first,
              noMatchOutcomes.count == 1,
              case .noMatch(best: nil, runnerUp: nil) = noMatchOutcome else {
            return XCTFail("An empty gallery must remain a typed no-match")
        }

        let tiedGallery = try FaceRecognitionGallery(people: [
            person(1, name: "First", vectorIndex: 0),
            person(2, name: "Second", vectorIndex: 0)
        ])
        let ambiguous = await service([observation]).analyze(
            stagedInput: stagedInput(),
            gallery: tiedGallery,
            policy: try policy()
        )
        guard case let .completed(ambiguousOutcomes, nil) = ambiguous,
              let ambiguousOutcome = ambiguousOutcomes.first,
              ambiguousOutcomes.count == 1,
              case .ambiguous = ambiguousOutcome else {
            return XCTFail("A tied identity must remain a typed ambiguity")
        }

        let gallery = try FaceRecognitionGallery(people: [person(1, name: "Fixture", vectorIndex: 0)])
        let lowQuality = await service([Observation(ordinal: 0, embedding: query, captureQuality: 0.1)]).analyze(
            stagedInput: stagedInput(),
            gallery: gallery,
            policy: try policy()
        )
        guard case let .completed(lowQualityOutcomes, nil) = lowQuality,
              let lowQualityOutcome = lowQualityOutcomes.first,
              lowQualityOutcomes.count == 1,
              case .insufficientQuality(actual: 0.1, minimum: 0.2) = lowQualityOutcome else {
            return XCTFail("Low quality must remain a typed abstention")
        }

        let missingQuality = await service([Observation(ordinal: 0, embedding: query, captureQuality: nil)]).analyze(
            stagedInput: stagedInput(),
            gallery: gallery,
            policy: try policy()
        )
        guard case let .completed(missingQualityOutcomes, nil) = missingQuality,
              let missingQualityOutcome = missingQualityOutcomes.first,
              missingQualityOutcomes.count == 1,
              case .qualityUnavailable = missingQualityOutcome else {
            return XCTFail("Missing required quality must remain a typed abstention")
        }

        let invalidQuality = await service([Observation(ordinal: 0, embedding: query, captureQuality: .nan)]).analyze(
            stagedInput: stagedInput(),
            gallery: gallery,
            policy: try policy()
        )
        XCTAssertEqual(invalidQuality, .rejected(.invalidCaptureQuality(ordinal: 0)))
    }

    func testAnalyzerCannotExceedRequestedObservationBound() async throws {
        let limits = try Service.Limits(maximumFaces: 2)
        let observations = [
            Observation(ordinal: 0, embedding: try vector(0), captureQuality: 1),
            Observation(ordinal: 1, embedding: try vector(1), captureQuality: 1),
            Observation(ordinal: 2, embedding: try vector(2), captureQuality: 1)
        ]
        let analyzer = Service(limits: limits) { _, requestedMaximum in
            XCTAssertEqual(requestedMaximum, 2)
            return observations
        }
        let result = await analyzer.analyze(
            stagedInput: stagedInput(),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(result, .rejected(.faceLimitExceeded(maximum: 2, actual: 3)))
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 0)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidMaximumFaces)
        }
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 257)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidMaximumFaces)
        }
    }

    func testLimitsRejectUnboundedResourceConfiguration() throws {
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 1, maximumQueuedAnalyses: 1_025)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidLimits)
        }
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 1, maximumPendingBytes: 0)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidLimits)
        }
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 1, deadline: .infinity)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidLimits)
        }
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 1, maximumGalleryPeople: 0)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidLimits)
        }
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 1, maximumGalleryEmbeddings: 100_001)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidLimits)
        }
        XCTAssertThrowsError(try Service.Limits(maximumFaces: 1, maximumGalleryComparisons: 25_600_001)) {
            XCTAssertEqual($0 as? FaceRecognitionAnalysisError, .invalidLimits)
        }
    }

    func testInvalidAndExcessiveStagedBytesAreRejectedBeforeOperation() async throws {
        let calls = Counter()
        let limits = try Service.Limits(maximumFaces: 1, maximumPendingBytes: 10)
        let analyzer = Service(limits: limits) { _, _ in
            await calls.increment()
            return []
        }
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()

        let invalid = await analyze(analyzer, gallery: gallery, policy: acceptance, stagedBytes: 0)
        let excessive = await analyze(analyzer, gallery: gallery, policy: acceptance, stagedBytes: 11)
        let callCount = await calls.value
        XCTAssertEqual(invalid, .rejected(.invalidStagedInputByteCount))
        XCTAssertEqual(excessive, .rejected(.pendingByteLimitExceeded(maximum: 10, pending: 0, requested: 11)))
        XCTAssertEqual(callCount, 0)
    }

    func testStagedInputLeaseIsOneShotWhileActiveAndAfterRelease() async throws {
        let entered = Latch()
        let release = Latch()
        let releaseProbe = ReleaseProbe()
        let analyzer = Service { _, _ in
            await entered.release()
            await release.wait()
            return []
        }
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let input = stagedInput(releaseProbe: releaseProbe)
        let first = Task {
            await analyzer.analyze(stagedInput: input, gallery: gallery, policy: acceptance)
        }
        await entered.wait()

        let concurrentReuse = await analyzer.analyze(
            stagedInput: input,
            gallery: gallery,
            policy: acceptance
        )
        XCTAssertEqual(concurrentReuse, .rejected(.stagedInputLeaseAlreadySubmitted))
        XCTAssertEqual(releaseProbe.value, 0, "Reuse rejection must not release the active owner's stage")

        await release.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .completed(outcomes: [], faceNames: nil))
        XCTAssertEqual(releaseProbe.value, 1)

        let laterReuse = await analyzer.analyze(stagedInput: input, gallery: gallery, policy: acceptance)
        XCTAssertEqual(laterReuse, .rejected(.stagedInputLeaseAlreadySubmitted))
        XCTAssertEqual(releaseProbe.value, 1)
    }

    func testSerialWorkerBoundsQueueDepth() async throws {
        let entered = Latch()
        let release = Latch()
        let sleeper = ManualSleeper()
        let limits = try Service.Limits(
            maximumFaces: 1,
            maximumQueuedAnalyses: 1,
            maximumPendingBytes: 30
        )
        let analyzer = Service(limits: limits, sleep: { await sleeper.sleep($0) }) { _, _ in
            await entered.release()
            await release.wait()
            return []
        }
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let firstRelease = ReleaseProbe()
        let secondRelease = ReleaseProbe()
        let rejectedRelease = ReleaseProbe()
        let firstInput = stagedInput(bytes: 10, releaseProbe: firstRelease)
        let secondInput = stagedInput(bytes: 10, releaseProbe: secondRelease)
        let rejectedInput = stagedInput(bytes: 10, releaseProbe: rejectedRelease)
        let first = Task {
            await analyzer.analyze(
                stagedInput: firstInput,
                gallery: gallery,
                policy: acceptance
            )
        }
        await entered.wait()
        let second = Task {
            await analyzer.analyze(
                stagedInput: secondInput,
                gallery: gallery,
                policy: acceptance
            )
        }
        await sleeper.waitForCount(2)

        let overloaded = await analyzer.analyze(
            stagedInput: rejectedInput,
            gallery: gallery,
            policy: acceptance
        )
        XCTAssertEqual(overloaded, .rejected(.queueLimitExceeded(maximumQueuedAnalyses: 1)))
        XCTAssertEqual(rejectedRelease.value, 1)
        XCTAssertEqual(firstRelease.value, 0)
        XCTAssertEqual(secondRelease.value, 0)
        await release.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .completed(outcomes: [], faceNames: nil))
        XCTAssertEqual(secondResult, .completed(outcomes: [], faceNames: nil))
        XCTAssertEqual(firstRelease.value, 1)
        XCTAssertEqual(secondRelease.value, 1)
    }

    func testPendingByteBudgetIncludesActiveAndQueuedWork() async throws {
        let entered = Latch()
        let release = Latch()
        let sleeper = ManualSleeper()
        let limits = try Service.Limits(
            maximumFaces: 1,
            maximumQueuedAnalyses: 2,
            maximumPendingBytes: 10
        )
        let analyzer = Service(limits: limits, sleep: { await sleeper.sleep($0) }) { _, _ in
            await entered.release()
            await release.wait()
            return []
        }
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let activeRelease = ReleaseProbe()
        let rejectedRelease = ReleaseProbe()
        let activeInput = stagedInput(bytes: 6, releaseProbe: activeRelease)
        let rejectedInput = stagedInput(bytes: 5, releaseProbe: rejectedRelease)
        let first = Task {
            await analyzer.analyze(
                stagedInput: activeInput,
                gallery: gallery,
                policy: acceptance
            )
        }
        await entered.wait()

        let overloaded = await analyzer.analyze(
            stagedInput: rejectedInput,
            gallery: gallery,
            policy: acceptance
        )
        XCTAssertEqual(overloaded, .rejected(.pendingByteLimitExceeded(maximum: 10, pending: 6, requested: 5)))
        XCTAssertEqual(rejectedRelease.value, 1)
        XCTAssertEqual(activeRelease.value, 0)
        await release.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .completed(outcomes: [], faceNames: nil))
        XCTAssertEqual(activeRelease.value, 1)
    }

    func testDeadlineCoversQueueWaitSuppressesLateResultAndRetainsWorkerSlotUntilExit() async throws {
        let entered = Latch()
        let release = Latch()
        let sleeper = ManualSleeper()
        let calls = Counter()
        let limits = try Service.Limits(
            maximumFaces: 1,
            maximumQueuedAnalyses: 1,
            maximumPendingBytes: 10,
            deadline: 1
        )
        let analyzer = Service(limits: limits, sleep: { await sleeper.sleep($0) }) { _, _ in
            await calls.increment()
            await entered.release()
            await release.wait() // Deliberately ignores task cancellation.
            return []
        }
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let activeRelease = ReleaseProbe()
        let queuedRelease = ReleaseProbe()
        let finalRelease = ReleaseProbe()
        let activeInput = stagedInput(bytes: 5, releaseProbe: activeRelease)
        let queuedInput = stagedInput(bytes: 5, releaseProbe: queuedRelease)
        let first = Task {
            await analyzer.analyze(
                stagedInput: activeInput,
                gallery: gallery,
                policy: acceptance
            )
        }
        await entered.wait()
        await sleeper.waitForCount(1)
        await sleeper.fireFirst()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .failed(.deadlineExceeded))
        XCTAssertEqual(activeRelease.value, 0, "Late active work still owns its stage")

        let second = Task {
            await analyzer.analyze(
                stagedInput: queuedInput,
                gallery: gallery,
                policy: acceptance
            )
        }
        await sleeper.waitForCount(1)
        let callsWhileLateWorkRuns = await calls.value
        XCTAssertEqual(callsWhileLateWorkRuns, 1, "Timed-out Core ML work must retain the serial worker slot")
        await sleeper.fireFirst()
        let secondResult = await second.value
        XCTAssertEqual(secondResult, .failed(.deadlineExceeded), "The deadline starts when queued work is admitted")
        XCTAssertEqual(queuedRelease.value, 1, "Queued work has no hidden operation and releases immediately")
        XCTAssertEqual(activeRelease.value, 0)

        await release.release()
        let thirdResult = await analyzer.analyze(
            stagedInput: stagedInput(bytes: 5, releaseProbe: finalRelease),
            gallery: gallery,
            policy: acceptance
        )
        let finalCallCount = await calls.value
        XCTAssertEqual(thirdResult, .completed(outcomes: [], faceNames: nil))
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(activeRelease.value, 1)
        XCTAssertEqual(finalRelease.value, 1)
    }

    func testTemporaryServiceRetainsTimedOutActiveStageUntilHiddenWorkExits() async throws {
        let entered = Latch()
        let release = Latch()
        let exited = Latch()
        let sleeper = ManualSleeper()
        let releaseProbe = ReleaseProbe()
        let input = stagedInput(releaseProbe: releaseProbe)
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let limits = try Service.Limits(maximumFaces: 1, deadline: 1)
        let task = Task {
            await Service(
                limits: limits,
                sleep: { await sleeper.sleep($0) },
                operation: { _, _ in
                    await entered.release()
                    await release.wait()
                    await exited.release()
                    return []
                }
            ).analyze(stagedInput: input, gallery: gallery, policy: acceptance)
        }
        await entered.wait()
        await sleeper.waitForCount(1)
        await sleeper.fireFirst()

        let result = await task.value
        XCTAssertEqual(result, .failed(.deadlineExceeded))
        XCTAssertEqual(releaseProbe.value, 0, "The hidden worker must keep itself and its stage alive")
        await release.release()
        await exited.wait()
        await releaseProbe.waitForRelease()
        XCTAssertEqual(releaseProbe.value, 1)
    }

    func testGalleryBudgetsRejectBeforeAnalysisAndBoundComparisonWork() async throws {
        let calls = Counter()
        let resolves = Counter()
        let embedding = try vector(0)
        let twoPeople = try FaceRecognitionGallery(people: [
            person(1, name: "One", vectorIndex: 0),
            person(2, name: "Two", vectorIndex: 0)
        ])
        let onePersonTwoExamples = try FaceRecognitionGallery(people: [
            FaceRecognitionPerson(
                id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                name: "One",
                examples: [embedding, embedding]
            )
        ])
        let acceptance = try policy()

        let peopleLimited = Service(limits: try .init(maximumFaces: 2, maximumGalleryPeople: 1)) { _, _ in
            await calls.increment()
            return []
        }
        let peopleResult = await analyze(peopleLimited, gallery: twoPeople, policy: acceptance)
        XCTAssertEqual(peopleResult, .rejected(.galleryPeopleLimitExceeded(maximum: 1, actual: 2)))

        let embeddingsLimited = Service(limits: try .init(maximumFaces: 2, maximumGalleryEmbeddings: 1)) { _, _ in
            await calls.increment()
            return []
        }
        let embeddingsResult = await analyze(embeddingsLimited, gallery: onePersonTwoExamples, policy: acceptance)
        let preflightCallCount = await calls.value
        XCTAssertEqual(embeddingsResult, .rejected(.galleryEmbeddingLimitExceeded(maximum: 1, actual: 2)))
        XCTAssertEqual(preflightCallCount, 0)

        let comparisonsLimited = Service(
            limits: try .init(maximumFaces: 2, maximumGalleryComparisons: 1),
            resolver: { _, _, _ in
                await resolves.increment()
                return .noMatch(best: nil, runnerUp: nil)
            },
            operation: { _, _ in
                await calls.increment()
                return [
                    Observation(ordinal: 0, embedding: embedding, captureQuality: 1),
                    Observation(ordinal: 1, embedding: embedding, captureQuality: 1)
                ]
            }
        )
        let comparisonGallery = try FaceRecognitionGallery(people: [person(1, name: "One", vectorIndex: 0)])
        let comparisonsResult = await analyze(comparisonsLimited, gallery: comparisonGallery, policy: acceptance)
        let finalCallCount = await calls.value
        let resolveCount = await resolves.value
        XCTAssertEqual(comparisonsResult, .rejected(.galleryComparisonLimitExceeded(maximum: 1, actual: 2)))
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(resolveCount, 0)
    }

    func testInvalidFaceOrdinalsRejectAllResultsBeforeMatching() async throws {
        let embedding = try vector(0)
        let gallery = try FaceRecognitionGallery(people: [person(1, name: "Fixture", vectorIndex: 0)])
        let acceptance = try policy()
        for ordinals in [[0, 0], [1], [-1]] {
            let observations = ordinals.map {
                Observation(ordinal: $0, embedding: embedding, captureQuality: 1)
            }
            let result = await service(observations).analyze(
                stagedInput: stagedInput(),
                gallery: gallery,
                policy: acceptance
            )
            XCTAssertEqual(result, .rejected(.invalidFaceOrdinals))
        }
    }

    func testOperationFailureIsTypedAndDoesNotPublishPartialResults() async throws {
        let analyzer = Service { _, _ in throw FixtureError.failed }
        let result = await analyzer.analyze(
            stagedInput: stagedInput(),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(result, .failed(.operationFailed))
    }

    func testMatchingFailureIsTypedAndDoesNotPublishPartialResults() async throws {
        let observation = Observation(ordinal: 0, embedding: try vector(0), captureQuality: 1)
        let analyzer = Service(
            resolver: { _, _, _ in throw FixtureError.failed },
            operation: { _, _ in [observation] }
        )
        let result = await analyzer.analyze(
            stagedInput: stagedInput(),
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(result, .failed(.matchingFailed))
    }

    func testCancellationBeforeAnalysisDoesNotInvokeOperation() async throws {
        let waiting = Latch()
        let release = Latch()
        let calls = Counter()
        let analyzer = Service { _, _ in
            await calls.increment()
            return []
        }
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let releaseProbe = ReleaseProbe()
        let input = stagedInput(releaseProbe: releaseProbe)
        let task = Task {
            await waiting.release()
            await release.wait()
            return await analyzer.analyze(stagedInput: input, gallery: gallery, policy: acceptance)
        }
        await waiting.wait()
        task.cancel()
        await release.release()

        let result = await task.value
        let callCount = await calls.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(releaseProbe.value, 1)
    }

    func testQueuedCancellationReleasesOnlyQueuedStage() async throws {
        let entered = Latch()
        let release = Latch()
        let sleeper = ManualSleeper()
        let activeRelease = ReleaseProbe()
        let queuedRelease = ReleaseProbe()
        let analyzer = Service(
            limits: try .init(maximumFaces: 1, maximumQueuedAnalyses: 1),
            sleep: { await sleeper.sleep($0) },
            operation: { _, _ in
                await entered.release()
                await release.wait()
                return []
            }
        )
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let activeInput = stagedInput(releaseProbe: activeRelease)
        let queuedInput = stagedInput(releaseProbe: queuedRelease)
        let active = Task {
            await analyzer.analyze(stagedInput: activeInput, gallery: gallery, policy: acceptance)
        }
        await entered.wait()
        let queued = Task {
            await analyzer.analyze(stagedInput: queuedInput, gallery: gallery, policy: acceptance)
        }
        await sleeper.waitForCount(2)

        queued.cancel()
        let queuedResult = await queued.value
        XCTAssertEqual(queuedResult, .cancelled)
        XCTAssertEqual(queuedRelease.value, 1)
        XCTAssertEqual(activeRelease.value, 0)

        await release.release()
        let activeResult = await active.value
        XCTAssertEqual(activeResult, .completed(outcomes: [], faceNames: nil))
        XCTAssertEqual(activeRelease.value, 1)
    }

    func testTemporaryServiceRetainsCancelledActiveStageUntilHiddenWorkExits() async throws {
        let entered = Latch()
        let release = Latch()
        let exited = Latch()
        let releaseProbe = ReleaseProbe()
        let input = stagedInput(releaseProbe: releaseProbe)
        let gallery = try FaceRecognitionGallery(people: [])
        let acceptance = try policy()
        let task = Task {
            await Service { _, _ in
                await entered.release()
                await release.wait()
                await exited.release()
                return []
            }.analyze(stagedInput: input, gallery: gallery, policy: acceptance)
        }
        await entered.wait()
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(releaseProbe.value, 0, "The hidden worker must keep itself and its stage alive")
        await release.release()
        await exited.wait()
        await releaseProbe.waitForRelease()
        XCTAssertEqual(releaseProbe.value, 1)
    }

    func testCancellationAfterAsyncBoundarySuppressesUncooperativeResult() async throws {
        let entered = Latch()
        let release = Latch()
        let observation = Observation(ordinal: 0, embedding: try vector(0), captureQuality: 1)
        let analyzer = Service { _, _ in
            await entered.release()
            await release.wait()
            return [observation]
        }
        let gallery = try FaceRecognitionGallery(people: [person(1, name: "Fixture", vectorIndex: 0)])
        let acceptance = try policy()
        let releaseProbe = ReleaseProbe()
        let cleanupRelease = ReleaseProbe()
        let input = stagedInput(releaseProbe: releaseProbe)
        let task = Task {
            await analyzer.analyze(stagedInput: input, gallery: gallery, policy: acceptance)
        }
        await entered.wait()
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(releaseProbe.value, 0, "Cancelled active work still owns its stage")
        await release.release()
        _ = await analyzer.analyze(
            stagedInput: stagedInput(releaseProbe: cleanupRelease),
            gallery: gallery,
            policy: acceptance
        )
        XCTAssertEqual(releaseProbe.value, 1)
        XCTAssertEqual(cleanupRelease.value, 1)
    }

    func testCancellationDuringInjectedMatchingSuppressesAcceptedIdentity() async throws {
        let entered = Latch()
        let release = Latch()
        let observation = Observation(ordinal: 0, embedding: try vector(0), captureQuality: 1)
        let analyzer = Service(
            resolver: { observation, gallery, policy in
                await entered.release()
                await release.wait()
                return FaceRecognitionMatcher.match(
                    embedding: observation.embedding,
                    quality: observation.captureQuality,
                    gallery: gallery,
                    policy: policy
                )
            },
            operation: { _, _ in [observation] }
        )
        let gallery = try FaceRecognitionGallery(people: [person(1, name: "Private fixture", vectorIndex: 0)])
        let acceptance = try policy()
        let releaseProbe = ReleaseProbe()
        let cleanupRelease = ReleaseProbe()
        let input = stagedInput(releaseProbe: releaseProbe)
        let task = Task {
            await analyzer.analyze(stagedInput: input, gallery: gallery, policy: acceptance)
        }
        await entered.wait()
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(releaseProbe.value, 0, "Cancelled matching still owns its stage")
        await release.release()
        _ = await analyzer.analyze(
            stagedInput: stagedInput(releaseProbe: cleanupRelease),
            gallery: gallery,
            policy: acceptance
        )
        XCTAssertEqual(releaseProbe.value, 1)
        XCTAssertEqual(cleanupRelease.value, 1)
    }
}
