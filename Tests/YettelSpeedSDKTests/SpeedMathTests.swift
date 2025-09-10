import XCTest
@testable import YettelSpeedSDK
import CoreLocation

final class SpeedMathTests: XCTestCase {
    func testBearingTolerance() {
        let a = CLLocationCoordinate2D(latitude: 42.6510, longitude: 23.3640)
        let b = CLLocationCoordinate2D(latitude: 42.6660, longitude: 23.3210)
        let br = bearing(from: a, to: b)
        XCTAssertTrue(isBearing(br + 5, closeTo: br, tol: 10))
        XCTAssertFalse(isBearing(br + 50, closeTo: br, tol: 10))
    }
}
