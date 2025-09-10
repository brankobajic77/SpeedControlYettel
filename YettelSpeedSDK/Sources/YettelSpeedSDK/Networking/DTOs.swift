import Foundation

/// Network shape for a traffic camera.
public struct CameraDTO: Codable, Hashable {
    public let id: String
    public let lat: Double
    public let lng: Double
    /// Optional camera bearing (degrees 0..360) — helps with direction filtering.
    public let direction: Double?
}

/// Network shape for a segment (ordered camera pair A→B).
public struct SegmentDTO: Codable, Hashable {
    public let name: String
    public let startCameraId: String
    public let endCameraId: String
    /// Optional geofence radius override for this segment's cameras (meters).
    public let geofenceRadius: Double?
}

/// Payload to report an average-speed measurement back to backend.
public struct AvgSpeedReportDTO: Codable, Hashable {
    public let segmentName: String
    public let startCameraId: String
    public let endCameraId: String
    public let startedAt: Date
    public let endedAt: Date
    public let routeDistanceMeters: Double
    public let avgSpeedKmH: Double
    public let appVersion: String
    public let deviceId: String?
}

