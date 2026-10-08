import XCTest
import CoreLocation
import MapKit
@testable import AagedalFTPSync

@MainActor
final class AppleMetadataGeocodingProviderTests: XCTestCase {
    private final class Request: AppleMetadataGeocodingRequest {
        var completion: (@Sendable (MetadataGeocodingService.ProviderResponse) -> Void)?
        var started: (() -> Void)?
        var cancelled: (() -> Void)?
        func start(completion: @escaping @Sendable (MetadataGeocodingService.ProviderResponse) -> Void) {
            self.completion = completion
            started?()
        }
        func cancel() { cancelled?() }
        func finish(_ response: MetadataGeocodingService.ProviderResponse) {
            let callback = completion
            completion = nil
            callback?(response)
        }
    }

    func testExplicitOptInIsRequiredAndConstructionIsInert() {
        let request = Request()
        var constructions = 0
        let factory: AppleMetadataGeocodingProvider.RequestFactory = { _ in constructions += 1; return request }
        XCTAssertNil(AppleMetadataGeocodingProvider.makeService(allowSendingCoordinatesToApple: false, requestFactory: factory))
        XCTAssertNotNil(AppleMetadataGeocodingProvider.makeService(allowSendingCoordinatesToApple: true, requestFactory: factory))
        XCTAssertEqual(constructions, 0)
        XCTAssertEqual(AppleMetadataGeocodingProvider.onlineLimits.concurrent, 1)
        XCTAssertEqual(AppleMetadataGeocodingProvider.onlineLimits.minimumStartInterval, 1)
        XCTAssertEqual(AppleMetadataGeocodingProvider.onlineLimits.work, 16)
        XCTAssertEqual(AppleMetadataGeocodingProvider.onlineLimits.callers, 64)
    }

    func testSuppliedCoordinatesAndConcreteLocaleReachRequestUnchanged() async throws {
        let query = try XCTUnwrap(MetadataGeocodingService.Query(latitude: -0.125, longitude: 0, locale: "fr_FR"))
        let request = Request()
        let started = expectation(description: "Native seam started")
        request.started = { started.fulfill() }
        var received: MetadataGeocodingService.Query?
        let service = try XCTUnwrap(AppleMetadataGeocodingProvider.makeService(allowSendingCoordinatesToApple: true) {
            received = $0
            return request
        })
        let task = Task { await service.resolve(query) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(received, query)
        let place = MetadataGeocodingService.Place(city: "Paris", country: "France", source: "injected", distanceMeters: nil)
        request.finish(.found(place))
        let result = await task.value
        XCTAssertEqual(result, .found(place, AppleMetadataGeocodingProvider.identity))
    }

    func testCancelledNativeRequestRetainsWorkerUntilCallback() async throws {
        let query = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 0, longitude: 0, locale: "en_US"))
        let request = Request()
        let started = expectation(description: "Native seam started")
        let cancelled = expectation(description: "Cancellation delivered")
        request.started = { started.fulfill() }
        request.cancelled = { cancelled.fulfill() }
        var constructions = 0
        let service = try XCTUnwrap(AppleMetadataGeocodingProvider.makeService(allowSendingCoordinatesToApple: true) { _ in
            constructions += 1
            return request
        })
        let task = Task { await service.resolve(query) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        let cancelledResult = await task.value
        XCTAssertEqual(cancelledResult, .cancelled)
        // Cancellation has been delivered but the native callback is still held.
        // Early continuation resumption would incorrectly admit another request.
        let pendingResult = await service.resolve(query)
        XCTAssertEqual(pendingResult, .overloaded)
        XCTAssertEqual(constructions, 1)
        XCTAssertNotNil(request.completion)
        request.finish(.noResult)
    }

    func testMissingFieldsRemainMissingAndDoNotGuessFromFormattedAddress() {
        guard case .noResult = AppleMetadataGeocodingProvider.response(city: "", country: nil, source: "test") else {
            return XCTFail("Empty administrative fields must remain no result")
        }
        guard case .found(let place) = AppleMetadataGeocodingProvider.response(city: nil, country: "Norway", source: "test") else {
            return XCTFail("Country-only response should be preserved")
        }
        XCTAssertNil(place.city)
        XCTAssertEqual(place.country, "Norway")
        XCTAssertNil(place.distanceMeters)
    }

    func testSynchronousCompletionBeforeStartReturns() async throws {
        let query = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 0, longitude: 0, locale: "en_US"))
        let request = Request()
        request.started = { [weak request] in request?.finish(.noResult) }
        let result = await AppleMetadataGeocodingProvider.perform(query, requestFactory: { _ in request })
        guard case .noResult = result else { return XCTFail("Synchronous callback must complete exactly once") }
        XCTAssertNil(request.completion)
    }

    func testNoPlacemarkErrorsDoNotBecomeGlobalProviderBackoff() {
        for error in [NSError(domain: MKErrorDomain, code: Int(MKError.placemarkNotFound.rawValue)),
                      NSError(domain: kCLErrorDomain, code: CLError.geocodeFoundNoResult.rawValue)] {
            guard case .noResult = AppleMetadataGeocodingProvider.errorResponse(error) else {
                return XCTFail("An explicit no-placemark response is not a provider failure")
            }
        }
        for error in [NSError(domain: "unrelated", code: Int(MKError.placemarkNotFound.rawValue)),
                      NSError(domain: MKErrorDomain, code: Int(MKError.serverFailure.rawValue)),
                      NSError(domain: kCLErrorDomain, code: CLError.network.rawValue)] {
            guard case .failure = AppleMetadataGeocodingProvider.errorResponse(error) else {
                return XCTFail("Other errors must remain failures")
            }
        }
    }

    func testRequestConstructionFailureIsExplicit() async throws {
        let query = try XCTUnwrap(MetadataGeocodingService.Query(latitude: 0, longitude: 0, locale: "en_US"))
        let response = await AppleMetadataGeocodingProvider.perform(query, requestFactory: { _ in nil })
        guard case .failure = response else { return XCTFail("Construction failure must not become no result") }
    }
}
