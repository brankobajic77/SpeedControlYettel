import Foundation
import CoreLocation

public extension CLLocationCoordinate2D {
    /// Haversine distance wrapper via CLLocation for simplicity (meters).
    func distance(from other: CLLocationCoordinate2D) -> CLLocationDistance {
        let a = CLLocation(latitude: latitude, longitude: longitude)
        let b = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return a.distance(from: b)
    }
}

/// Compute forward bearing (degrees 0..360) from A to B.
public func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let φ1 = from.latitude * .pi / 180, φ2 = to.latitude * .pi / 180
    let Δλ = (to.longitude - from.longitude) * .pi / 180
    let y = sin(Δλ) * cos(φ2)
    let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
    let θ = atan2(y, x) * 180 / .pi
    return fmod((θ + 360), 360)
}

/// Check if two bearings are within tolerance along shortest circular arc.
public func isBearing(_ a: Double, closeTo b: Double, tol: Double) -> Bool {
    let diff = abs(fmod((a - b + 540), 360) - 180) // 0..180
    return diff <= tol
}
