import Foundation

/// One shared instance per provider configuration. Coordinates are never spatially rounded.
/// This service does not select a provider, request permission, or write metadata.
actor MetadataGeocodingService {
    struct Identity: Hashable, Sendable {
        let provider: String
        let version: String
        let dataset: String
    }

    struct Query: Hashable, Sendable {
        let latitude: Double
        let longitude: Double
        /// A resolved, concrete locale, never an "automatic" preference.
        let locale: String

        private static let supportedLocales = Set(Locale.availableIdentifiers.map {
            $0.replacingOccurrences(of: "_", with: "-").lowercased()
        })

        init?(latitude: Double, longitude: Double, locale: String) {
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  !locale.isEmpty, locale.utf8.count <= 128,
                  Self.supportedLocales.contains(locale.replacingOccurrences(of: "_", with: "-").lowercased()),
                  locale.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
            else { return nil }
            self.latitude = latitude == 0 ? 0 : latitude
            self.longitude = longitude == 0 ? 0 : longitude
            self.locale = locale
        }
    }

    struct Place: Equatable, Sendable {
        let city: String?
        let country: String?
        /// Provider-defined provenance (for example, nearby GeoNames settlement).
        let source: String
        let distanceMeters: Double?
    }

    enum ProviderResponse: Sendable {
        case found(Place)
        case noResult
        case failure(retryAfter: TimeInterval?)
    }

    enum Outcome: Equatable, Sendable {
        case found(Place, Identity)
        case noResult
        case tooDistant
        case invalidProviderResult
        case providerFailure
        case backoff
        case overloaded
        case deadlineExceeded
        case cancelled
    }

    struct Limits: Sendable {
        /// For a serial provider, minimum pause after completion before the next start.
        /// This also covers delayed execution of detached work; offline defaults to unpaced.
        var minimumStartInterval: TimeInterval = 0
        var concurrent = 1
        var work = 32
        var callers = 128
        var cacheEntries = 128
        var cacheTTL: TimeInterval = 300
        var deadline: TimeInterval = 15
        var failureBackoff: TimeInterval = 10
        var maximumBackoff: TimeInterval = 300
        var maximumDistanceMeters: Double = 100_000

        fileprivate var valid: Bool {
            minimumStartInterval.isFinite && (0...3600).contains(minimumStartInterval) &&
            (minimumStartInterval == 0 || concurrent == 1) &&
            (1...16).contains(concurrent) && work >= concurrent && work <= 4096 &&
            callers >= work && callers <= 16_384 && (0...4096).contains(cacheEntries) &&
            [cacheTTL, deadline, failureBackoff, maximumBackoff, maximumDistanceMeters].allSatisfy { $0.isFinite && $0 > 0 } &&
            deadline <= 3600 && cacheTTL <= 86_400 && maximumBackoff <= 86_400 && failureBackoff <= maximumBackoff
        }
    }

    typealias Provider = @Sendable (Query) async -> ProviderResponse
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    private struct Key: Hashable { let query: Query; let identity: Identity }
    private struct Waiter {
        let continuation: CheckedContinuation<Outcome, Never>
        let timer: Task<Void, Never>
    }
    private struct Work {
        let id: UUID
        var waiters: [UUID: Waiter]
        var task: Task<Void, Never>?
    }
    private struct Cached { let outcome: Outcome; let expires: TimeInterval; var access: UInt64 }
    nonisolated let identity: Identity
    private let limits: Limits
    private let provider: Provider
    private let now: @Sendable () -> TimeInterval
    private let sleep: Sleep
    private var work: [Key: Work] = [:]
    private var queue: [Key] = []
    private var cache: [Key: Cached] = [:]
    private var access: UInt64 = 0
    private var active = 0
    private var callers = 0
    private var backoffUntil: TimeInterval = 0
    private var lastStart: TimeInterval?
    private var pacingWake: (id: UUID, task: Task<Void, Never>)?

    init(identity: Identity, limits: Limits = Limits(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
         provider: @escaping Provider) {
        precondition(limits.valid)
        precondition([identity.provider, identity.version, identity.dataset].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 })
        self.identity = identity
        self.limits = limits
        self.now = now
        self.sleep = sleep
        self.provider = provider
    }

    func resolve(_ query: Query) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        let key = Key(query: query, identity: identity)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can arrive before this actor admits the waiter.
                guard !Task.isCancelled else { continuation.resume(returning: .cancelled); return }
                admit(key, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.removeWaiter(key, id: waiterID, outcome: .cancelled) }
        }
    }

    private func admit(_ key: Key, waiterID: UUID, continuation: CheckedContinuation<Outcome, Never>) {
        let time = now()
        cache = cache.filter { $0.value.expires > time }
        if var cached = cache[key] {
            access &+= 1; cached.access = access; cache[key] = cached
            continuation.resume(returning: cached.outcome); return
        }
        guard time >= backoffUntil else { continuation.resume(returning: .backoff); return }
        guard callers < limits.callers else { continuation.resume(returning: .overloaded); return }
        if let existing = work[key], existing.waiters.isEmpty {
            // A cancelled, uncooperative provider still owns this key and its worker slot.
            continuation.resume(returning: .overloaded); return
        }
        if work[key] == nil {
            guard work.count < limits.work else { continuation.resume(returning: .overloaded); return }
            work[key] = Work(id: UUID(), waiters: [:], task: nil)
            queue.append(key)
        }
        let delay = limits.deadline
        let sleeper = sleep
        let timer = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleeper(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.removeWaiter(key, id: waiterID, outcome: .deadlineExceeded)
        }
        work[key]?.waiters[waiterID] = Waiter(continuation: continuation, timer: timer)
        callers += 1
        pump()
    }

    private func removeWaiter(_ key: Key, id: UUID, outcome: Outcome) {
        guard let waiter = work[key]?.waiters.removeValue(forKey: id) else { return }
        callers -= 1
        waiter.timer.cancel()
        waiter.continuation.resume(returning: outcome)
        if work[key]?.waiters.isEmpty == true {
            if let task = work[key]?.task {
                task.cancel() // Slot is freed only by finished(), never by this cancellation.
            } else {
                work.removeValue(forKey: key)
                queue.removeAll { $0 == key }
                if queue.isEmpty { cancelPacingWake() }
            }
        }
    }

    private func cancelPacingWake() {
        pacingWake?.task.cancel()
        pacingWake = nil
    }

    private func schedulePacingWake(after delay: TimeInterval) {
        guard pacingWake == nil else { return }
        let id = UUID()
        let sleeper = sleep
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleeper(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.resumePacing(id: id)
        }
        pacingWake = (id, task)
    }

    private func resumePacing(id: UUID) {
        guard pacingWake?.id == id else { return }
        pacingWake = nil
        pump() // Recheck monotonic time; an early wake must not start early.
    }

    private func pump() {
        while active < limits.concurrent, let key = queue.first {
            guard let item = work[key] else { queue.removeFirst(); continue }
            let time = now()
            if time < backoffUntil {
                queue.removeFirst()
                completeWaiters(key, outcome: .backoff)
                work.removeValue(forKey: key)
                continue
            }
            if let lastStart {
                let delay = lastStart + limits.minimumStartInterval - time
                if delay > 0 {
                    schedulePacingWake(after: delay)
                    return
                }
            }
            cancelPacingWake()
            queue.removeFirst()
            active += 1
            lastStart = time
            let provider = provider
            let id = item.id
            // Detached provider work cannot block this actor's cancellation/deadline handling.
            work[key]?.task = Task.detached { [weak self] in
                let response = await provider(key.query)
                await self?.finished(key, id: id, response: response)
            }
        }
        if queue.isEmpty { cancelPacingWake() }
    }

    private func finished(_ key: Key, id: UUID, response: ProviderResponse) {
        guard let item = work[key], item.id == id else { return }
        active -= 1
        if limits.minimumStartInterval > 0 { lastStart = now() }
        guard !item.waiters.isEmpty else {
            // An abandoned response has no authority over cache, backoff, or later callers.
            work.removeValue(forKey: key)
            pump()
            return
        }
        let outcome: Outcome
        switch response {
        case .found(let place):
            let strings = [place.city, place.country, place.source].compactMap { $0 }
            if strings.contains(where: { $0.isEmpty || $0.utf8.count > 4096 }) ||
                (place.city == nil && place.country == nil) ||
                place.distanceMeters.map({ !$0.isFinite || $0 < 0 }) == true {
                outcome = .invalidProviderResult
            } else if let distance = place.distanceMeters, distance > limits.maximumDistanceMeters {
                outcome = .tooDistant
            } else {
                outcome = .found(place, identity)
            }
        case .noResult: outcome = .noResult
        case .failure(let retryAfter):
            outcome = .providerFailure
            let delay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? limits.failureBackoff
            backoffUntil = max(backoffUntil, now() + min(limits.maximumBackoff, max(limits.failureBackoff, delay)))
        }
        // Late results for abandoned work cannot populate the cache or affect callers.
        if !item.waiters.isEmpty, limits.cacheEntries > 0 {
            switch outcome {
            case .found, .noResult, .tooDistant:
                if cache.count >= limits.cacheEntries, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
                    cache.removeValue(forKey: oldest)
                }
                access &+= 1
                cache[key] = Cached(outcome: outcome, expires: now() + limits.cacheTTL, access: access)
            default: break
            }
        }
        completeWaiters(key, outcome: outcome)
        work.removeValue(forKey: key)
        pump()
    }

    private func completeWaiters(_ key: Key, outcome: Outcome) {
        guard let waiters = work[key]?.waiters else { return }
        work[key]?.waiters.removeAll()
        callers -= waiters.count
        for waiter in waiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }
}
