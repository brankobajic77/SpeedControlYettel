import Foundation
import CoreLocation

public struct YettelSpeedConfig {
    /// Base URL for the backend (e.g., https://api.yettel.bg)
    public let baseURL: URL
    /// Provide a fresh token whenever called (read from Keychain/session).
    public let authProvider: () -> String?
    /// Max geofences to monitor concurrently (iOS hard limit ~20). Keep <= 20.
    public let maxMonitoredRegions: Int
    /// Default geofence radius for cameras (meters).
    public let defaultRadius: CLLocationDistance
    /// Minimum seconds between two entries into the same camera region.
    public let minCameraReentrySeconds: TimeInterval
    /// Direction tolerance in degrees for course filtering (0..180).
    public let directionToleranceDeg: Double

    public init(baseURL: URL,
                authProvider: @escaping () -> String?,
                maxMonitoredRegions: Int = 18,
                defaultRadius: CLLocationDistance = 120,
                minCameraReentrySeconds: TimeInterval = 30,
                directionToleranceDeg: Double = 60) {
        self.baseURL = baseURL
        self.authProvider = authProvider
        self.maxMonitoredRegions = maxMonitoredRegions
        self.defaultRadius = defaultRadius
        self.minCameraReentrySeconds = minCameraReentrySeconds
        self.directionToleranceDeg = directionToleranceDeg
    }
}

