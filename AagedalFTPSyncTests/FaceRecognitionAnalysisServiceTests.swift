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

    func testDefaultServiceIsUnavailableAndDoesNotInvokeAnalysisOperation() async throws {
        let inert = Service()
        XCTAssertEqual(inert.readiness, .unavailable(.unverifiedPreprocessingContract))
        let result = await inert.analyze(
            imageURL: imageURL,
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(result, .unavailable(.unverifiedPreprocessingContract))

        let explicitlyUnavailable = Service(unavailable: .componentUnavailable)
        let resultWithoutOperation = await explicitlyUnavailable.analyze(
            imageURL: imageURL,
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
            imageURL: imageURL,
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
            imageURL: imageURL,
            gallery: try FaceRecognitionGallery(people: []),
            policy: try policy()
        )
        XCTAssertEqual(result, .completed(outcomes: [], faceNames: nil))
    }

    func testMatcherAbstentionsRemainTypedObservationOutcomes() async throws {
        let query = try vector(0)
        let observation = Observation(ordinal: 0, embedding: query, captureQuality: 1)

        let noMatch = await service([observation]).analyze(
            imageURL: imageURL,
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
            imageURL: imageURL,
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
            imageURL: imageURL,
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
            imageURL: imageURL,
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
            imageURL: imageURL,
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
            imageURL: imageURL,
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

    func testInvalidFaceOrdinalsRejectAllResultsBeforeMatching() async throws {
        let embedding = try vector(0)
        let gallery = try FaceRecognitionGallery(people: [person(1, name: "Fixture", vectorIndex: 0)])
        let acceptance = try policy()
        for ordinals in [[0, 0], [1], [-1]] {
            let observations = ordinals.map {
                Observation(ordinal: $0, embedding: embedding, captureQuality: 1)
            }
            let result = await service(observations).analyze(
                imageURL: imageURL,
                gallery: gallery,
                policy: acceptance
            )
            XCTAssertEqual(result, .rejected(.invalidFaceOrdinals))
        }
    }

    func testOperationFailureIsTypedAndDoesNotPublishPartialResults() async throws {
        let analyzer = Service { _, _ in throw FixtureError.failed }
        let result = await analyzer.analyze(
            imageURL: imageURL,
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
            imageURL: imageURL,
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
        let sourceURL = imageURL
        let task = Task {
            await waiting.release()
            await release.wait()
            return await analyzer.analyze(imageURL: sourceURL, gallery: gallery, policy: acceptance)
        }
        await waiting.wait()
        task.cancel()
        await release.release()

        let result = await task.value
        let callCount = await calls.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(callCount, 0)
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
        let sourceURL = imageURL
        let task = Task {
            await analyzer.analyze(imageURL: sourceURL, gallery: gallery, policy: acceptance)
        }
        await entered.wait()
        task.cancel()
        await release.release()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
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
        let sourceURL = imageURL
        let task = Task {
            await analyzer.analyze(imageURL: sourceURL, gallery: gallery, policy: acceptance)
        }
        await entered.wait()
        task.cancel()
        await release.release()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }
}
