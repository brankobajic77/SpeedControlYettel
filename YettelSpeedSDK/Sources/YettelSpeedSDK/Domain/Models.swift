import Foundation
import CoreLocation

/// Domain model for a camera.
public struct Camera: Hashable {
    public let id: String
    public let coordinate: CLLocationCoordinate2D
    public let direction: Double?
}

/// Domain model for an ordered camera pair (segment A→B).
public struct CameraPair: Hashable {
    public let start: Camera
    public let end: Camera
    public let name: String
    public let radius: CLLocationDistance
}

/// Result of one average-speed measurement.
public struct AverageSpeedResult: Hashable {
    public let segmentName: String
    public let startCameraId: String
    public let endCameraId: String
    public let startTime: Date
    public let endTime: Date
    public let routeDistanceMeters: CLLocationDistance
    public let averageSpeedKmh: Double
}

