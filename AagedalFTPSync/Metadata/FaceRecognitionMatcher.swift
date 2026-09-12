import Foundation

/// These values describe one embedding space only. Model/preprocessing identity
/// must be checked by the library admission layer before constructing a gallery.
struct FaceRecognitionEmbedding: Equatable, Sendable {
    static let dimension = 512
    /// Maximum absolute deviation of the incoming L2 norm from one. Admitted
    /// float32 rounding drift is normalized before any distance calculation.
    static let normalizedNormTolerance = 0.0001
    let values: [Float]

    init(validatingNormalized values: [Float]) throws {
        let norm = try Self.norm(values)
        guard abs(norm - 1) <= Self.normalizedNormTolerance else {
            throw FaceRecognitionValidationError.notNormalized
        }
        self.values = values.map { Float(Double($0) / norm) }
    }

    /// For raw model output only; imported normalized vectors use the stricter
    /// initializer so malformed library data is not silently repaired.
    init(normalizing values: [Float]) throws {
        let norm = try Self.norm(values)
        self.values = values.map { Float(Double($0) / norm) }
    }

    private static func norm(_ values: [Float]) throws -> Double {
        guard values.count == dimension else { throw FaceRecognitionValidationError.invalidDimension }
        guard values.allSatisfy(\.isFinite) else { throw FaceRecognitionValidationError.nonfiniteEmbedding }
        let squared = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squared > 0, squared.isFinite else { throw FaceRecognitionValidationError.zeroEmbedding }
        return squared.squareRoot()
    }
}

enum FaceRecognitionValidationError: Error, Equatable {
    case invalidDimension, nonfiniteEmbedding, zeroEmbedding, notNormalized
    case emptyName, emptyExamples, duplicatePersonID, invalidPolicy
}

struct FaceRecognitionPerson: Equatable, Sendable {
    let id: UUID
    /// Literal imported data, including braces and original whitespace. Metadata
    /// writers apply their own field limits; the matcher never parses templates.
    let name: String
    let examples: [FaceRecognitionEmbedding]

    init(id: UUID, name: String, examples: [FaceRecognitionEmbedding]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FaceRecognitionValidationError.emptyName
        }
        guard !examples.isEmpty else { throw FaceRecognitionValidationError.emptyExamples }
        self.id = id; self.name = name; self.examples = examples
    }
}

struct FaceRecognitionGallery: Equatable, Sendable {
    let people: [FaceRecognitionPerson]
    init(people: [FaceRecognitionPerson]) throws {
        guard Set(people.map(\.id)).count == people.count else {
            throw FaceRecognitionValidationError.duplicatePersonID
        }
        self.people = people
    }
}

/// There is deliberately no production default. Thresholds must be supplied by
/// a separately calibrated policy for unattended publication, not copied from
/// grouping or display settings in another application.
struct FaceRecognitionAcceptancePolicy: Equatable, Sendable {
    enum UnavailableQualityPolicy: Equatable, Sendable { case reject, allow }
    /// Acceptance is strictly below this cosine distance, in (0, 2].
    let maximumCosineDistance: Double
    /// Required second-person distance minus best-person distance, in [0, 2].
    /// Exact ties remain ambiguous even when the requested minimum gap is zero.
    let minimumRunnerUpGap: Double
    let minimumCaptureQuality: Double
    let unavailableQualityPolicy: UnavailableQualityPolicy

    init(maximumCosineDistance: Double, minimumRunnerUpGap: Double,
         minimumCaptureQuality: Double, unavailableQualityPolicy: UnavailableQualityPolicy) throws {
        guard maximumCosineDistance.isFinite, maximumCosineDistance > 0, maximumCosineDistance <= 2,
              minimumRunnerUpGap.isFinite, (0...2).contains(minimumRunnerUpGap),
              minimumCaptureQuality.isFinite, (0...1).contains(minimumCaptureQuality) else {
            throw FaceRecognitionValidationError.invalidPolicy
        }
        self.maximumCosineDistance = maximumCosineDistance
        self.minimumRunnerUpGap = minimumRunnerUpGap
        self.minimumCaptureQuality = minimumCaptureQuality
        self.unavailableQualityPolicy = unavailableQualityPolicy
    }
}

struct FaceRecognitionCandidate: Equatable, Sendable {
    let personID: UUID
    let name: String
    let cosineDistance: Double
    /// Cosine similarity in [-1, 1], never an identity probability.
    var similarity: Double { 1 - cosineDistance }
}

enum FaceRecognitionMatchOutcome: Equatable, Sendable {
    case accepted(best: FaceRecognitionCandidate, runnerUp: FaceRecognitionCandidate?)
    case noMatch(best: FaceRecognitionCandidate?, runnerUp: FaceRecognitionCandidate?)
    case ambiguous(best: FaceRecognitionCandidate, runnerUp: FaceRecognitionCandidate)
    case insufficientQuality(actual: Double, minimum: Double)
    case qualityUnavailable
    case invalidQuality
}

enum FaceRecognitionMatcher {
    static func match(embedding: FaceRecognitionEmbedding, quality: Double?, gallery: FaceRecognitionGallery,
                      policy: FaceRecognitionAcceptancePolicy) -> FaceRecognitionMatchOutcome {
        if let quality {
            guard quality.isFinite, (0...1).contains(quality) else { return .invalidQuality }
            guard quality >= policy.minimumCaptureQuality else {
                return .insufficientQuality(actual: quality, minimum: policy.minimumCaptureQuality)
            }
        } else if policy.unavailableQualityPolicy == .reject { return .qualityUnavailable }

        var best: FaceRecognitionCandidate?
        var runnerUp: FaceRecognitionCandidate?
        // Every example of every person is visited. Neither a perfect match nor
        // the acceptance cutoff can discard a later, ambiguity-relevant person.
        for person in gallery.people {
            let distance = person.examples.reduce(2.0) { minimum, example in
                min(minimum, cosineDistance(embedding, example))
            }
            let candidate = FaceRecognitionCandidate(personID: person.id, name: person.name, cosineDistance: distance)
            if let currentBest = best {
                if precedes(candidate, currentBest) { runnerUp = currentBest; best = candidate }
                else if runnerUp == nil || precedes(candidate, runnerUp!) { runnerUp = candidate }
            } else { best = candidate }
        }
        guard let best else { return .noMatch(best: nil, runnerUp: nil) }
        guard best.cosineDistance < policy.maximumCosineDistance else {
            return .noMatch(best: best, runnerUp: runnerUp)
        }
        if let runnerUp {
            let gap = runnerUp.cosineDistance - best.cosineDistance
            if gap <= 0 || gap < policy.minimumRunnerUpGap { return .ambiguous(best: best, runnerUp: runnerUp) }
        }
        return .accepted(best: best, runnerUp: runnerUp)
    }

    private static func precedes(_ first: FaceRecognitionCandidate, _ second: FaceRecognitionCandidate) -> Bool {
        first.cosineDistance < second.cosineDistance ||
            (first.cosineDistance == second.cosineDistance && first.personID.uuidString < second.personID.uuidString)
    }

    private static func cosineDistance(_ first: FaceRecognitionEmbedding, _ second: FaceRecognitionEmbedding) -> Double {
        // Float32-normalized arrays retain minute rounding error. Dividing by
        // their actual norms ensures identical vectors have distance zero.
        var dot = 0.0, firstSquared = 0.0, secondSquared = 0.0
        for (a, b) in zip(first.values, second.values) {
            let a = Double(a), b = Double(b)
            dot += a * b; firstSquared += a * a; secondSquared += b * b
        }
        let similarity = dot / (firstSquared * secondSquared).squareRoot()
        return 1 - min(1, max(-1, similarity))
    }
}
