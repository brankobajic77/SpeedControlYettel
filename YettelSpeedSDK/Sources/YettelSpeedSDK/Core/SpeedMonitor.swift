import Foundation
import CoreLocation
import MapKit
import UserNotifications
import Combine

final class SpeedMonitor: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let repo: CameraRepository
    private let config: YettelSpeedConfig
    private let retryQueue: AvgSpeedRetryQueue

    private var lastLocation: CLLocation?
    private var startPassTimestamps: [String: Date] = [:] // start camera -> time
    private var lastCameraEntryTime: [String: Date] = [:]
    private var activeRegionIds: Set<String> = []

    let resultPublisher = PassthroughSubject<AverageSpeedResult, Never>()
    var onAverageSpeedComputed: ((AverageSpeedResult) -> Void)?

    init(repo: CameraRepository, config: YettelSpeedConfig, retryQueue: AvgSpeedRetryQueue) {
        self.repo = repo
        self.config = config
        self.retryQueue = retryQueue
        super.init()
        configureLocation()
        configureNotifications()
    }

    func start() {
        locationManager.startUpdatingLocation()
        Task { await refreshRegionsAroundLastLocation() }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        for region in locationManager.monitoredRegions { locationManager.stopMonitoring(for: region) }
        activeRegionIds.removeAll()
    }

    // MARK: - Location setup & geofences

    private func configureLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = true
        if CLLocationManager.authorizationStatus() == .notDetermined { locationManager.requestAlwaysAuthorization() }
    }

    private func startMonitoring(camera: Camera, radius: CLLocationDistance) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        guard !activeRegionIds.contains(camera.id) else { return }
        let region = CLCircularRegion(center: camera.coordinate, radius: radius, identifier: camera.id)
        region.notifyOnEntry = true
        region.notifyOnExit = false
        locationManager.startMonitoring(for: region)
        activeRegionIds.insert(camera.id)
    }

    private func stopMonitoring(cameraId: String) {
        guard activeRegionIds.contains(cameraId) else { return }
        if let region = locationManager.monitoredRegions.first(where: { $0.identifier == cameraId }) {
            locationManager.stopMonitoring(for: region)
        }
        activeRegionIds.remove(cameraId)
    }

    private func refreshRegions(near coordinate: CLLocationCoordinate2D) {
        let allCams = Array(repo.cameras.values)
        guard !allCams.isEmpty else { return }
        let sorted = allCams.sorted { $0.coordinate.distance(from: coordinate) < $1.coordinate.distance(from: coordinate) }
        let target = Set(sorted.prefix(config.maxMonitoredRegions).map { $0.id })
        for id in activeRegionIds where !target.contains(id) { stopMonitoring(cameraId: id) }
        for id in target where !activeRegionIds.contains(id) {
            if let cam = repo.cameras[id] {
                // Pick max radius across segments that use this camera
                let r = repo.pairs.reduce(config.defaultRadius) { acc, p in
                    var rr = acc
                    if p.start.id == id { rr = max(rr, p.radius) }
                    if p.end.id == id { rr = max(rr, p.radius) }
                    return rr
                }
                startMonitoring(camera: cam, radius: r)
            }
        }
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Average speed"
        content.body = text
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: start()
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        refreshRegions(near: loc.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        let cameraId = circular.identifier

        // Anti-bounce
        if let last = lastCameraEntryTime[cameraId], Date().timeIntervalSince(last) < config.minCameraReentrySeconds { return }
        lastCameraEntryTime[cameraId] = Date()

        // Try START match with direction gate
        if let pair = repo.pairs.first(where: { $0.start.id == cameraId }) {
            if directionGateOK(for: pair) {
                startPassTimestamps[pair.start.id] = Date()
            }
            return
        }

        // Try END matches
        let ends = repo.pairs.filter { $0.end.id == cameraId }
        guard !ends.isEmpty else { return }

        for pair in ends {
            guard let startTime = startPassTimestamps[pair.start.id] else { continue }
            if !directionGateOK(for: pair) { continue }

            let endTime = Date()
            startPassTimestamps.removeValue(forKey: pair.start.id)

            computeRouteDistance(from: pair.start.coordinate, to: pair.end.coordinate) { [weak self] distanceMeters in
                guard let self = self, let distanceMeters else { return }
                let duration = endTime.timeIntervalSince(startTime)
                guard duration > 0 else { return }
                let kmPerH = (distanceMeters / duration) * 3.6
                let result = AverageSpeedResult(segmentName: pair.name,
                                                startCameraId: pair.start.id,
                                                endCameraId: pair.end.id,
                                                startTime: startTime,
                                                endTime: endTime,
                                                routeDistanceMeters: distanceMeters,
                                                averageSpeedKmh: kmPerH)
                DispatchQueue.main.async {
                    self.onAverageSpeedComputed?(result)
                    self.resultPublisher.send(result)
                    self.notify(String(format: "%@: %.1f km/h", pair.name, kmPerH))
                    Task { await self.report(result: result) }
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        print("[SpeedMonitor] Region monitoring failed: \(error)")
    }

    // MARK: - Direction filtering

    private func directionGateOK(for pair: CameraPair) -> Bool {
        let expected = bearing(from: pair.start.coordinate, to: pair.end.coordinate)
        if let course = lastLocation?.course, course >= 0 { return isBearing(course, closeTo: expected, tol: config.directionToleranceDeg) }
        if let camDir = repo.cameras[pair.start.id]?.direction { return isBearing(camDir, closeTo: expected, tol: 45) }
        return true // no data to filter by
    }

    // MARK: - Distance via MapKit (+ fallback)

    private func computeRouteDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, completion: @escaping (CLLocationDistance?) -> Void) {
        let src = MKMapItem(placemark: .init(coordinate: from))
        let dst = MKMapItem(placemark: .init(coordinate: to))
        let req = MKDirections.Request()
        req.source = src; req.destination = dst
        req.transportType = .automobile
        req.requestsAlternateRoutes = false

        MKDirections(request: req).calculate { response, _ in
            if let route = response?.routes.first { completion(route.distance) }
            else { completion(MKMetersBetweenMapPoints(MKMapPoint(from), MKMapPoint(to))) }
        }
    }

    // MARK: - Reporting

    private func report(result: AverageSpeedResult) async {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let dto = AvgSpeedReportDTO(segmentName: result.segmentName,
                                    startCameraId: result.startCameraId,
                                    endCameraId: result.endCameraId,
                                    startedAt: result.startTime,
                                    endedAt: result.endTime,
                                    routeDistanceMeters: result.routeDistanceMeters,
                                    avgSpeedKmH: result.averageSpeedKmh,
                                    appVersion: appVersion,
                                    deviceId: nil)
        retryQueue.enqueue(dto)
    }

    private func refreshRegionsAroundLastLocation() async {
        if let loc = locationManager.location?.coordinate { refreshRegions(near: loc) }
    }
}

