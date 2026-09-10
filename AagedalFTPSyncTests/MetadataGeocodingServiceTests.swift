import Foundation
import XCTest
@testable import AagedalFTPSync

final class MetadataGeocodingServiceTests: XCTestCase {
    private typealias Service = MetadataGeocodingService
    private let identity = Service.Identity(provider: "fixture", version: "1", dataset: "cities-1")
    private let place = Service.Place(city: "Oslo", country: "Norway", source: "nearby settlement", distanceMeters: 20)

    private actor Gate<Value: Sendable> {
        private var calls = 0
        private var closedValue: Value?
        private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
        private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
        func enter() async -> Value {
            if let closedValue { return closedValue }
            calls += 1
            let index = calls
            return await withCheckedContinuation { continuation in
                pending[index] = continuation
                let ready = observers.filter { $0.0 <= calls }
                observers.removeAll { $0.0 <= calls }
                for observer in ready { observer.1.resume() }
            }
        }
        func entered(_ count: Int) async {
            if calls >= count { return }
            await withCheckedContinuation { observers.append((count, $0)) }
        }
        func release(_ index: Int, _ value: Value) { pending.removeValue(forKey: index)?.resume(returning: value) }
        func releaseAll(_ value: Value) {
            closedValue = value
            let continuations = pending.values
            pending.removeAll()
            for continuation in continuations { continuation.resume(returning: value) }
        }
        var count: Int { calls }
    }

    private final class Time: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private func query(_ latitude: Double = 59.9, locale: String = "nb-NO") -> Service.Query {
        Service.Query(latitude: latitude, longitude: 10.7, locale: locale)!
    }

    func testQueriesValidateWholePairsAndDoNotRoundAcrossBoundaries() {
        XCTAssertNil(Service.Query(latitude: .nan, longitude: 0, locale: "en-US"))
        XCTAssertNil(Service.Query(latitude: 0, longitude: .infinity, locale: "en-US"))
        XCTAssertNil(Service.Query(latitude: 91, longitude: 0, locale: "en-US"))
        XCTAssertNil(Service.Query(latitude: 0, longitude: -181, locale: "en-US"))
        XCTAssertNil(Service.Query(latitude: 0, longitude: 0, locale: "automatic"))
        XCTAssertNil(Service.Query(latitude: 0, longitude: 0, locale: ""))
        XCTAssertNil(Service.Query(latitude: 0, longitude: 0, locale: "AUTOMATIC"))
        XCTAssertNil(Service.Query(latitude: 0, longitude: 0, locale: "junk"))
        XCTAssertNotNil(Service.Query(latitude: -90, longitude: 180, locale: "en-US"))
        XCTAssertNotEqual(query(), query(59.90000001))
        XCTAssertNotEqual(query(), query(locale: "en-US"))
        XCTAssertEqual(Service.Query(latitude: -0.0, longitude: 0, locale: "en"),
                       Service.Query(latitude: 0, longitude: 0, locale: "en"))
    }

    func testIdenticalRequestsCoalesceAndOneCallerCancellationDoesNotCancelOthers() async {
        let provider = Gate<Service.ProviderResponse>()
        let timers = Gate<Void>()
        let service = Service(identity: identity, sleep: { _ in await timers.enter() }, provider: { _ in await provider.enter() })
        let q = query()
        let first = Task { await service.resolve(q) }
        await provider.entered(1)
        let second = Task { await service.resolve(q) }
        await timers.entered(2)
        first.cancel()
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .cancelled)
        await provider.release(1, .found(place))
        let result = await second.value
        XCTAssertEqual(result, .found(place, identity))
        let count = await provider.count
        XCTAssertEqual(count, 1)
        let cached = await service.resolve(q)
        XCTAssertEqual(cached, result)
        await timers.releaseAll(())
    }

    func testDeadlineReleasesCallerButUncooperativeProviderRetainsWorkerAndKey() async {
        let provider = Gate<Service.ProviderResponse>()
        let timers = Gate<Void>()
        var limits = Service.Limits(); limits.concurrent = 1; limits.work = 2
        let service = Service(identity: identity, limits: limits,
                              sleep: { _ in await timers.enter() }, provider: { _ in await provider.enter() })
        let q = query()
        let first = Task { await service.resolve(q) }
        await provider.entered(1); await timers.entered(1)
        await timers.release(1, ())
        let expired = await first.value
        XCTAssertEqual(expired, .deadlineExceeded)
        let duplicate = await service.resolve(q)
        XCTAssertEqual(duplicate, .overloaded)
        let nextQuery = query(60)
        let queued = Task { await service.resolve(nextQuery) }
        await timers.entered(2)
        let count = await provider.count
        XCTAssertEqual(count, 1, "Deadline must not free an occupied provider slot")
        await provider.release(1, .found(place))
        await provider.entered(2)
        await provider.release(2, .noResult)
        let second = await queued.value
        XCTAssertEqual(second, .noResult)
        let retried = Task { await service.resolve(q) }
        await provider.entered(3)
        await provider.release(3, .noResult)
        let retry = await retried.value
        XCTAssertEqual(retry, .noResult, "Abandoned late success must not populate cache")
        await timers.releaseAll(())
    }

    func testWorkAndCoalescedCallerLimitsAreBoundedAndQueuedCancellationRemovesWork() async {
        let provider = Gate<Service.ProviderResponse>()
        let timers = Gate<Void>()
        var limits = Service.Limits(); limits.work = 2; limits.callers = 2
        let service = Service(identity: identity, limits: limits,
                              sleep: { _ in await timers.enter() }, provider: { _ in await provider.enter() })
        let firstQuery = query(), secondQuery = query(60)
        let first = Task { await service.resolve(firstQuery) }
        await provider.entered(1)
        let queued = Task { await service.resolve(secondQuery) }
        await timers.entered(2)
        let overflow = await service.resolve(query(61))
        let coalescedOverflow = await service.resolve(firstQuery)
        XCTAssertEqual(overflow, .overloaded)
        XCTAssertEqual(coalescedOverflow, .overloaded)
        queued.cancel()
        let cancelled = await queued.value
        XCTAssertEqual(cancelled, .cancelled)
        await provider.release(1, .noResult)
        let result = await first.value
        XCTAssertEqual(result, .noResult)
        let count = await provider.count
        XCTAssertEqual(count, 1, "Cancelled queued work must never reach provider")
        await timers.releaseAll(())
    }

    func testQueuedDeadlineDoesNotStartProviderAndAbandonedFailureDoesNotBackoff() async {
        let provider = Gate<Service.ProviderResponse>()
        let timers = Gate<Void>()
        let service = Service(identity: identity, sleep: { _ in await timers.enter() },
                              provider: { _ in await provider.enter() })
        let q = query(), other = query(60)
        let first = Task { await service.resolve(q) }
        await provider.entered(1); await timers.entered(1)
        let queued = Task { await service.resolve(other) }
        await timers.entered(2)
        await timers.release(2, ())
        let expired = await queued.value
        XCTAssertEqual(expired, .deadlineExceeded)
        first.cancel()
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .cancelled)
        let next = Task { await service.resolve(other) }
        await timers.entered(3)
        await provider.release(1, .failure(retryAfter: 300))
        await provider.entered(2)
        await provider.release(2, .noResult)
        let result = await next.value
        XCTAssertEqual(result, .noResult)
        await timers.releaseAll(())
    }

    func testFailureAppliesFiniteProviderWideBackoffToQueuedAndNewRequests() async {
        let provider = Gate<Service.ProviderResponse>()
        let timers = Gate<Void>()
        let time = Time()
        let service = Service(identity: identity, now: { time.read() },
                              sleep: { _ in await timers.enter() }, provider: { _ in await provider.enter() })
        let q = query(), other = query(60)
        let first = Task { await service.resolve(q) }
        await provider.entered(1)
        let queued = Task { await service.resolve(other) }
        await timers.entered(2)
        await provider.release(1, .failure(retryAfter: .infinity))
        let failure = await first.value, deferred = await queued.value
        XCTAssertEqual(failure, .providerFailure)
        XCTAssertEqual(deferred, .backoff)
        let early = await service.resolve(q)
        XCTAssertEqual(early, .backoff)
        time.advance(11)
        let retry = Task { await service.resolve(q) }
        await provider.entered(2)
        await provider.release(2, .noResult)
        let recovered = await retry.value
        XCTAssertEqual(recovered, .noResult)
        await timers.releaseAll(())
    }

    func testCacheSeparatesLocaleAndExactCoordinatesAndExpiresAndEvicts() async {
        let provider = Gate<Service.ProviderResponse>()
        let timers = Gate<Void>()
        let time = Time()
        var limits = Service.Limits(); limits.cacheEntries = 1; limits.cacheTTL = 5
        let service = Service(identity: identity, limits: limits, now: { time.read() },
                              sleep: { _ in await timers.enter() }, provider: { _ in await provider.enter() })
        let queries = [query(), query(locale: "en-US"), query(), query(59.90000001), query(59.90000001)]
        for (index, q) in queries.enumerated() {
            if index == 4 { time.advance(6) }
            let task = Task { await service.resolve(q) }
            await provider.entered(index + 1)
            await provider.release(index + 1, .found(place))
            let result = await task.value
            XCTAssertEqual(result, .found(place, identity))
        }
        let count = await provider.count
        XCTAssertEqual(count, 5)
        await timers.releaseAll(())
    }

    func testProviderResultsRetainProvenanceAndRejectDistanceAndMalformedValues() async {
        let cases: [(Double, Service.Outcome)] = [(.nan, .invalidProviderResult), (-1, .invalidProviderResult), (100_001, .tooDistant)]
        for (distance, expected) in cases {
            let place = Service.Place(city: "City", country: nil, source: "fixture", distanceMeters: distance)
            let service = Service(identity: identity, provider: { _ in .found(place) })
            let result = await service.resolve(query())
            XCTAssertEqual(result, expected)
        }
        let invalid = Service.Place(city: nil, country: nil, source: "fixture", distanceMeters: nil)
        let service = Service(identity: identity, provider: { _ in .found(invalid) })
        let result = await service.resolve(query())
        XCTAssertEqual(result, .invalidProviderResult)
    }
}
