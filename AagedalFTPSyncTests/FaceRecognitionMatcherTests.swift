import Foundation
import XCTest
@testable import AagedalFTPSync

final class FaceRecognitionMatcherTests: XCTestCase {
    private func vector(similarity: Double = 1) throws -> FaceRecognitionEmbedding {
        var values = [Float](repeating: 0, count: 512)
        values[0] = Float(similarity)
        values[1] = Float(max(0, 1 - similarity * similarity).squareRoot())
        return try .init(validatingNormalized: values)
    }
    private func person(_ ordinal: Int, similarity: Double, name: String = "Fixture") throws -> FaceRecognitionPerson {
        let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal)))
        return try .init(id: id, name: name, examples: [vector(similarity: similarity)])
    }
    private func policy(distance: Double = 0.5, gap: Double = 0.04,
                        quality: Double = 0.2, unavailable: FaceRecognitionAcceptancePolicy.UnavailableQualityPolicy = .reject) throws -> FaceRecognitionAcceptancePolicy {
        try .init(maximumCosineDistance: distance, minimumRunnerUpGap: gap,
                  minimumCaptureQuality: quality, unavailableQualityPolicy: unavailable)
    }

    func testStrictEmbeddingAdmissionRejectsMalformedVectorsWithoutRepairingLibraryScale() throws {
        for count in [0, 511, 513] {
            XCTAssertThrowsError(try FaceRecognitionEmbedding(validatingNormalized: [Float](repeating: 1, count: count))) {
                XCTAssertEqual($0 as? FaceRecognitionValidationError, .invalidDimension)
            }
        }
        var values = [Float](repeating: 0, count: 512)
        XCTAssertThrowsError(try FaceRecognitionEmbedding(normalizing: values)) {
            XCTAssertEqual($0 as? FaceRecognitionValidationError, .zeroEmbedding)
        }
        for bad in [Float.nan, Float.infinity, -Float.infinity] {
            values[0] = bad
            XCTAssertThrowsError(try FaceRecognitionEmbedding(validatingNormalized: values)) {
                XCTAssertEqual($0 as? FaceRecognitionValidationError, .nonfiniteEmbedding)
            }
        }
        values[0] = 2
        XCTAssertThrowsError(try FaceRecognitionEmbedding(validatingNormalized: values)) {
            XCTAssertEqual($0 as? FaceRecognitionValidationError, .notNormalized)
        }
        XCTAssertEqual(try FaceRecognitionEmbedding(normalizing: values), try vector())
        values[0] = 1.00005
        XCTAssertEqual(try FaceRecognitionEmbedding(validatingNormalized: values), try vector())
        values[0] = 1.001
        XCTAssertThrowsError(try FaceRecognitionEmbedding(validatingNormalized: values))
    }

    func testRawNormalizationHandlesFiniteExtremeScales() throws {
        for scale in [Float.greatestFiniteMagnitude, Float.leastNonzeroMagnitude] {
            var values = [Float](repeating: 0, count: 512)
            values[0] = scale; values[1] = scale
            let embedding = try FaceRecognitionEmbedding(normalizing: values)
            XCTAssertTrue(embedding.values.allSatisfy(\.isFinite))
            XCTAssertEqual(embedding.values.reduce(0.0) { $0 + Double($1) * Double($1) }, 1, accuracy: 0.000001)
        }
    }

    func testRunnerUpBeyondAcceptanceCutoffStillMakesBestAmbiguous() throws {
        let best = try person(1, similarity: 0.51)
        let runner = try person(2, similarity: 0.49)
        let result = FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: [best, runner]), policy: try policy())
        guard case let .ambiguous(first, second) = result else { return XCTFail("Runner-up outside cutoff must not be filtered") }
        XCTAssertEqual(first.personID, best.id)
        XCTAssertEqual(second.personID, runner.id)
        XCTAssertGreaterThan(second.cosineDistance, 0.5)
        XCTAssertLessThan(second.cosineDistance - first.cosineDistance, 0.04)
    }

    func testLatePerfectCandidateIsVisitedAfterNearPerfectEarlyCandidate() throws {
        let early = try person(1, similarity: 0.995)
        let late = try person(50, similarity: 1)
        var people = [early]
        for ordinal in 2...49 { people.append(try person(ordinal, similarity: 0)) }
        people.append(late)
        let result = FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: people), policy: try policy())
        guard case let .ambiguous(best, runnerUp) = result else { return XCTFail("Late candidate must participate in ambiguity") }
        XCTAssertEqual(best.personID, late.id)
        XCTAssertEqual(best.cosineDistance, 0, accuracy: 1e-12)
        XCTAssertEqual(runnerUp.personID, early.id)
    }

    func testExamplesCompeteWithinPersonAndNamesRemainLiteral() throws {
        let name = "  {persons}, {date:YYYY-MM-DD} & Å  "
        let owner = try FaceRecognitionPerson(id: UUID(), name: name,
            examples: [vector(similarity: -1), vector(), vector()])
        let other = try person(2, similarity: 0)
        let result = FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: [owner, other]), policy: try policy())
        guard case let .accepted(best, runnerUp) = result else { return XCTFail("Same person's examples cannot be runners-up") }
        XCTAssertEqual(best.name, name)
        XCTAssertEqual(best.personID, owner.id)
        XCTAssertEqual(runnerUp?.personID, other.id)
        XCTAssertEqual(best.similarity, 1, accuracy: 1e-12)
    }

    func testExactTieIsAmbiguousAndOrderIndependentEvenWithZeroGap() throws {
        let a = try person(1, similarity: 1, name: "Same name")
        let b = try person(2, similarity: 1, name: "Same name")
        let forward = FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: [a, b]), policy: try policy(gap: 0))
        let reverse = FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: [b, a]), policy: try policy(gap: 0))
        XCTAssertEqual(forward, reverse)
        guard case let .ambiguous(best, runner) = forward else { return XCTFail("Distinct identities must stay distinct despite equal names") }
        XCTAssertEqual(best.personID, a.id)
        XCTAssertEqual(runner.personID, b.id)
    }

    func testNoMatchEmptyGalleryStrictDistanceBoundaryAndSinglePerson() throws {
        XCTAssertEqual(FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: []), policy: try policy()), .noMatch(best: nil, runnerUp: nil))
        let orthogonal = try person(1, similarity: 0)
        let boundary = FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: [orthogonal]), policy: try policy(distance: 1))
        guard case let .noMatch(best, runnerUp) = boundary else { return XCTFail("Distance cutoff is strict") }
        XCTAssertEqual(best?.cosineDistance, 1)
        XCTAssertNil(runnerUp)
        let only = try person(2, similarity: 1)
        guard case let .accepted(single, second) = FaceRecognitionMatcher.match(embedding: try vector(), quality: 1,
            gallery: try .init(people: [only]), policy: try policy()) else { return XCTFail("A sole qualifying person is accepted") }
        XCTAssertEqual(single.personID, only.id)
        XCTAssertNil(second)
    }

    func testQualityPolicyDistinguishesMissingInvalidAndInsufficientQuality() throws {
        let gallery = try FaceRecognitionGallery(people: [person(1, similarity: 1)])
        let query = try vector()
        let strict = try policy()
        XCTAssertEqual(FaceRecognitionMatcher.match(embedding: query, quality: nil, gallery: gallery, policy: strict), .qualityUnavailable)
        XCTAssertEqual(FaceRecognitionMatcher.match(embedding: query, quality: 0.1, gallery: gallery, policy: strict),
                       .insufficientQuality(actual: 0.1, minimum: 0.2))
        for quality in [Double.nan, .infinity, -0.01, 1.01] {
            XCTAssertEqual(FaceRecognitionMatcher.match(embedding: query, quality: quality, gallery: gallery, policy: strict), .invalidQuality)
        }
        guard case .accepted = FaceRecognitionMatcher.match(embedding: query, quality: 0.2, gallery: gallery, policy: strict) else {
            return XCTFail("Minimum quality itself is allowed")
        }
        guard case .accepted = FaceRecognitionMatcher.match(embedding: query, quality: nil, gallery: gallery,
            policy: try policy(unavailable: .allow)) else { return XCTFail("Unavailable quality requires explicit permission") }
    }

    func testPolicyAndGalleryValidationRejectInvalidAdmission() throws {
        for distance in [Double.nan, .infinity, -1, 0, 2.01] { XCTAssertThrowsError(try policy(distance: distance)) }
        for gap in [Double.nan, .infinity, -1, 2.01] { XCTAssertThrowsError(try policy(gap: gap)) }
        for quality in [Double.nan, .infinity, -1, 1.01] { XCTAssertThrowsError(try policy(quality: quality)) }
        let p = try person(1, similarity: 1)
        XCTAssertThrowsError(try FaceRecognitionGallery(people: [p, p])) {
            XCTAssertEqual($0 as? FaceRecognitionValidationError, .duplicatePersonID)
        }
        XCTAssertThrowsError(try FaceRecognitionPerson(id: UUID(), name: " \n", examples: [vector()]))
        XCTAssertThrowsError(try FaceRecognitionPerson(id: UUID(), name: "Name", examples: []))
    }
}
