// =============================================
// Yettel Speed SDK (Modular) — iOS 15+, Swift 5.9
// =============================================
// Split across multiple logical files for clean integration.
// Copy each section into its own .swift file inside your project.
// All comments are in English as requested.
//
// Folder suggestion:
//  Sources/
//   └─ YettelSpeedSDK/
//       ├─ Config/
//       │   └─ YettelSpeedConfig.swift
//       ├─ Networking/
//       │   ├─ APIClient.swift
//       │   └─ DTOs.swift
//       ├─ Domain/
//       │   ├─ Models.swift
//       │   └─ CameraRepository.swift
//       ├─ Persistence/
//       │   ├─ AvgSpeedDiskQueue.swift
//       │   └─ AvgSpeedRetryQueue.swift
//       ├─ Core/
//       │   ├─ SpeedMonitor.swift
//       │   ├─ Helpers.swift
//       │   └─ YettelSpeedSDK.swift
//       └─ DemoUI/
//           └─ LiveSpeedView.swift (optional)
//
// =============================================
// File: Config/YettelSpeedConfig.swift
// =============================================

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

// =============================================
// File: Networking/DTOs.swift
// =============================================

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

// =============================================
// File: Domain/Models.swift
// =============================================

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

// =============================================
// File: Core/Helpers.swift
// =============================================

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

// =============================================
// File: Networking/APIClient.swift
// =============================================

import Foundation

final class APIClient {
    private let baseURL: URL
    private let authProvider: () -> String?
    private let session: URLSession

    init(baseURL: URL, authProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.authProvider = authProvider
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var url = baseURL
        url.append(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        if let tok = authProvider() { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    func getCameras() async throws -> [CameraDTO] {
        let req = makeRequest(path: "/v1/traffic/cameras")
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp)
        return try JSONDecoder().decode([CameraDTO].self, from: data)
    }

    func getSegments() async throws -> [SegmentDTO] {
        let req = makeRequest(path: "/v1/traffic/segments")
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp)
        return try JSONDecoder().decode([SegmentDTO].self, from: data)
    }

    func postAvgSpeed(_ payload: AvgSpeedReportDTO) async throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let body = try enc.encode(payload)
        var req = makeRequest(path: "/v1/traffic/avg-speed-report", method: "POST", body: body)
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        try Self.validate(resp)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "APIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}

// =============================================
// File: Domain/CameraRepository.swift
// =============================================

import Foundation
import CoreLocation

final class CameraRepository {
    let api: APIClient
    private(set) var cameras: [String: Camera] = [:] // id -> Camera
    private(set) var pairs: [CameraPair] = []

    init(api: APIClient) { self.api = api }

    /// Fetch cameras & segments and map to domain models.
    func refresh(defaultRadius: CLLocationDistance) async throws {
        async let camDTOs = api.getCameras()
        async let segDTOs = api.getSegments()
        let (cDTOs, sDTOs) = try await (camDTOs, segDTOs)

        let byId: [String: Camera] = Dictionary(uniqueKeysWithValues: cDTOs.map { dto in
            let coord = CLLocationCoordinate2D(latitude: dto.lat, longitude: dto.lng)
            return (dto.id, Camera(id: dto.id, coordinate: coord, direction: dto.direction))
        })
        self.cameras = byId

        var mapped: [CameraPair] = []
        for s in sDTOs {
            guard let a = byId[s.startCameraId], let b = byId[s.endCameraId] else { continue }
            let r = s.geofenceRadius.map(CLLocationDistance.init) ?? defaultRadius
            mapped.append(.init(start: a, end: b, name: s.name, radius: r))
        }
        self.pairs = mapped
    }
}

// =============================================
// File: Persistence/AvgSpeedDiskQueue.swift
// =============================================

import Foundation

/// Simple JSON file queue for offline avg-speed reports.
final class AvgSpeedDiskQueue {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let q = DispatchQueue(label: "AvgSpeedDiskQueue")

    init(filename: String = "AvgSpeedQueue.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        self.encoder = enc; self.decoder = dec
    }

    func loadAll() -> [AvgSpeedReportDTO] {
        q.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? decoder.decode([AvgSpeedReportDTO].self, from: data)) ?? []
        }
    }

    func saveAll(_ items: [AvgSpeedReportDTO]) {
        q.async {
            do { let data = try self.encoder.encode(items); try data.write(to: self.url, options: .atomic) }
            catch { print("[DiskQueue] Save failed: \(error)") }
        }
    }
}

// =============================================
// File: Persistence/AvgSpeedRetryQueue.swift
// =============================================

import Foundation
import Network

/// Retry queue with exponential backoff and connectivity awareness.
final class AvgSpeedRetryQueue {
    private var items: [AvgSpeedReportDTO]
    private let disk: AvgSpeedDiskQueue
    private let api: APIClient
    private let backoffBase: TimeInterval = 3
    private let maxBackoff: TimeInterval = 60
    private var currentBackoff: TimeInterval = 0
    private var isUploading = false
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "AvgSpeedRetryQueue.Net")

    init(disk: AvgSpeedDiskQueue, api: APIClient) {
        self.disk = disk
        self.api = api
        self.items = disk.loadAll()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied { self.flush() }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func enqueue(_ report: AvgSpeedReportDTO) { items.append(report); disk.saveAll(items); flush() }

    func flush() {
        guard !isUploading, !items.isEmpty else { return }
        isUploading = true
        Task { await uploadNext() }
    }

    private func removeFirst() { if !items.isEmpty { items.removeFirst(); disk.saveAll(items) } }
    private func peek() -> AvgSpeedReportDTO? { items.first }
    private func resetBackoff() { currentBackoff = 0 }

    private func scheduleRetry() {
        currentBackoff = currentBackoff == 0 ? backoffBase : min(maxBackoff, currentBackoff * 2)
        let delay = currentBackoff
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.isUploading = false
            self?.flush()
        }
    }

    private func uploadNext() async {
        guard let next = peek() else { isUploading = false; return }
        do {
            try await api.postAvgSpeed(next)
            removeFirst(); resetBackoff()
            if items.isEmpty { isUploading = false } else { await uploadNext() }
        } catch {
            print("[RetryQueue] Upload failed: \(error)")
            scheduleRetry()
        }
    }
}

// =============================================
// File: Core/SpeedMonitor.swift
// =============================================

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

// =============================================
// File: Core/YettelSpeedSDK.swift
// =============================================

import Foundation
import Combine

public final class YettelSpeedSDK: ObservableObject {
    private let config: YettelSpeedConfig
    private let api: APIClient
    private let repo: CameraRepository
    private let diskQueue: AvgSpeedDiskQueue
    private let retryQueue: AvgSpeedRetryQueue
    public let monitor: SpeedMonitor

    @Published public private(set) var lastResults: [AverageSpeedResult] = []
    private var cancellables = Set<AnyCancellable>()

    public init(config: YettelSpeedConfig) {
        self.config = config
        self.api = APIClient(baseURL: config.baseURL, authProvider: config.authProvider)
        self.repo = CameraRepository(api: api)
        self.diskQueue = AvgSpeedDiskQueue()
        self.retryQueue = AvgSpeedRetryQueue(disk: diskQueue, api: api)
        self.monitor = SpeedMonitor(repo: repo, config: config, retryQueue: retryQueue)
        monitor.onAverageSpeedComputed = { [weak self] r in self?.appendResult(r) }
        monitor.resultPublisher.sink { [weak self] r in self?.appendResult(r) }.store(in: &cancellables)
    }

    private func appendResult(_ r: AverageSpeedResult) {
        lastResults.insert(r, at: 0)
        if lastResults.count > 100 { lastResults.removeLast() }
    }

    /// Call AFTER user consented to location. Refreshes remote data and starts monitoring.
    public func start() {
        Task {
            do { try await repo.refresh(defaultRadius: config.defaultRadius) }
            catch { print("[SDK] Refresh failed: \(error)") }
            monitor.start()
        }
    }

    public func stop() { monitor.stop() }
}

// =============================================
// File: DemoUI/LiveSpeedView.swift (Optional)
// =============================================

#if canImport(SwiftUI)
import SwiftUI
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

public struct LiveSpeedView: View {
    @StateObject var vm: SpeedDemoViewModel

    public init(sdk: YettelSpeedSDK) { _vm = StateObject(wrappedValue: SpeedDemoViewModel(sdk: sdk)) }

    public var body: some View {
        VStack(spacing: 12) {
            header
            controls
            List(vm.results, id: \.self) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.segmentName).font(.headline)
                    Text(String(format: "Avg: %.1f km/h  •  Dist: %.0f m  •  Dur: %.0f s",
                                r.averageSpeedKmh, r.routeDistanceMeters, r.endTime.timeIntervalSince(r.startTime)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Start: \(vm.fmt(r.startTime))  End: \(vm.fmt(r.endTime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Yettel Average Speed Monitor").font(.title3).bold()
                Text(vm.permissionText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: vm.toggle) {
                Text(vm.isRunning ? "Stop" : "Start")
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(vm.isRunning ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button("Clear") { vm.clear() }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
    }
}

public final class SpeedDemoViewModel: ObservableObject {
    @Published var results: [AverageSpeedResult] = []
    @Published var isRunning = false
    @Published var permissionText = "Location permission: Unknown"

    private let sdk: YettelSpeedSDK

    init(sdk: YettelSpeedSDK) {
        self.sdk = sdk
        // Bind to SDK updates
        sdk.$lastResults
            .receive(on: DispatchQueue.main)
            .assign(to: &self.$results)
        updatePermissionText()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updatePermissionText()
        }
        #endif
    }

    func toggle() {
        if isRunning { sdk.stop() } else { sdk.start() }
        isRunning.toggle()
    }

    func clear() { results.removeAll() }

    func fmt(_ d: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .none; df.timeStyle = .medium
        return df.string(from: d)
    }

    private func updatePermissionText() {
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .authorizedAlways: permissionText = "Location permission: Always"
        case .authorizedWhenInUse: permissionText = "Location permission: When In Use"
        case .denied: permissionText = "Location permission: Denied"
        case .restricted: permissionText = "Location permission: Restricted"
        case .notDetermined: permissionText = "Location permission: Not Determined"
        @unknown default: permissionText = "Location permission: Unknown"
        }
    }
}
#endif

// =============================================
// Integration Notes (Info.plist & App setup)
// =============================================
// 1) Info.plist:
//    - NSLocationWhenInUseUsageDescription = "This feature measures average speed between road sections using your location."
//    - NSLocationAlwaysAndWhenInUseUsageDescription = "Allows background monitoring of speed segments."
//    Background Modes → Location updates = ON
//
// 2) Create & keep SDK singleton (DI):
//    let cfg = YettelSpeedConfig(baseURL: URL(string: "https://api.yettel.bg")!, authProvider: { TokenStore.shared.jwt })
//    let speedSDK = YettelSpeedSDK(config: cfg)
//    // After user consents:
//    speedSDK.start()
//
// 3) Backend endpoints (proposed):
//    GET /v1/traffic/cameras   -> [CameraDTO]
//    GET /v1/traffic/segments  -> [SegmentDTO]
//    POST /v1/traffic/avg-speed-report  (AvgSpeedReportDTO)
//    Use Authorization: Bearer <JWT>
//
// 4) Privacy: Show an in-app consent screen. Consider anonymizing deviceId. Respect local laws.
// =============================================
// Yettel Speed SDK (Modular) — iOS 15+, Swift 5.9
// =============================================
// Split across multiple logical files for clean integration.
// Copy each section into its own .swift file inside your project.
// All comments are in English as requested.
//
// Folder suggestion:
//  Sources/
//   └─ YettelSpeedSDK/
//       ├─ Config/
//       │   └─ YettelSpeedConfig.swift
//       ├─ Networking/
//       │   ├─ APIClient.swift
//       │   └─ DTOs.swift
//       ├─ Domain/
//       │   ├─ Models.swift
//       │   └─ CameraRepository.swift
//       ├─ Persistence/
//       │   ├─ AvgSpeedDiskQueue.swift
//       │   └─ AvgSpeedRetryQueue.swift
//       ├─ Core/
//       │   ├─ SpeedMonitor.swift
//       │   ├─ Helpers.swift
//       │   └─ YettelSpeedSDK.swift
//       └─ DemoUI/
//           └─ LiveSpeedView.swift (optional)
//
// =============================================
// File: Config/YettelSpeedConfig.swift
// =============================================

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

// =============================================
// File: Networking/DTOs.swift
// =============================================

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

// =============================================
// File: Domain/Models.swift
// =============================================

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

// =============================================
// File: Core/Helpers.swift
// =============================================

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

// =============================================
// File: Networking/APIClient.swift
// =============================================

import Foundation

final class APIClient {
    private let baseURL: URL
    private let authProvider: () -> String?
    private let session: URLSession

    init(baseURL: URL, authProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.authProvider = authProvider
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var url = baseURL
        url.append(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        if let tok = authProvider() { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    func getCameras() async throws -> [CameraDTO] {
        let req = makeRequest(path: "/v1/traffic/cameras")
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp)
        return try JSONDecoder().decode([CameraDTO].self, from: data)
    }

    func getSegments() async throws -> [SegmentDTO] {
        let req = makeRequest(path: "/v1/traffic/segments")
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp)
        return try JSONDecoder().decode([SegmentDTO].self, from: data)
    }

    func postAvgSpeed(_ payload: AvgSpeedReportDTO) async throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let body = try enc.encode(payload)
        var req = makeRequest(path: "/v1/traffic/avg-speed-report", method: "POST", body: body)
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        try Self.validate(resp)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "APIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}

// =============================================
// File: Domain/CameraRepository.swift
// =============================================

import Foundation
import CoreLocation

final class CameraRepository {
    let api: APIClient
    private(set) var cameras: [String: Camera] = [:] // id -> Camera
    private(set) var pairs: [CameraPair] = []

    init(api: APIClient) { self.api = api }

    /// Fetch cameras & segments and map to domain models.
    func refresh(defaultRadius: CLLocationDistance) async throws {
        async let camDTOs = api.getCameras()
        async let segDTOs = api.getSegments()
        let (cDTOs, sDTOs) = try await (camDTOs, segDTOs)

        let byId: [String: Camera] = Dictionary(uniqueKeysWithValues: cDTOs.map { dto in
            let coord = CLLocationCoordinate2D(latitude: dto.lat, longitude: dto.lng)
            return (dto.id, Camera(id: dto.id, coordinate: coord, direction: dto.direction))
        })
        self.cameras = byId

        var mapped: [CameraPair] = []
        for s in sDTOs {
            guard let a = byId[s.startCameraId], let b = byId[s.endCameraId] else { continue }
            let r = s.geofenceRadius.map(CLLocationDistance.init) ?? defaultRadius
            mapped.append(.init(start: a, end: b, name: s.name, radius: r))
        }
        self.pairs = mapped
    }
}

// =============================================
// File: Persistence/AvgSpeedDiskQueue.swift
// =============================================

import Foundation

/// Simple JSON file queue for offline avg-speed reports.
final class AvgSpeedDiskQueue {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let q = DispatchQueue(label: "AvgSpeedDiskQueue")

    init(filename: String = "AvgSpeedQueue.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        self.encoder = enc; self.decoder = dec
    }

    func loadAll() -> [AvgSpeedReportDTO] {
        q.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? decoder.decode([AvgSpeedReportDTO].self, from: data)) ?? []
        }
    }

    func saveAll(_ items: [AvgSpeedReportDTO]) {
        q.async {
            do { let data = try self.encoder.encode(items); try data.write(to: self.url, options: .atomic) }
            catch { print("[DiskQueue] Save failed: \(error)") }
        }
    }
}

// =============================================
// File: Persistence/AvgSpeedRetryQueue.swift
// =============================================

import Foundation
import Network

/// Retry queue with exponential backoff and connectivity awareness.
final class AvgSpeedRetryQueue {
    private var items: [AvgSpeedReportDTO]
    private let disk: AvgSpeedDiskQueue
    private let api: APIClient
    private let backoffBase: TimeInterval = 3
    private let maxBackoff: TimeInterval = 60
    private var currentBackoff: TimeInterval = 0
    private var isUploading = false
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "AvgSpeedRetryQueue.Net")

    init(disk: AvgSpeedDiskQueue, api: APIClient) {
        self.disk = disk
        self.api = api
        self.items = disk.loadAll()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied { self.flush() }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func enqueue(_ report: AvgSpeedReportDTO) { items.append(report); disk.saveAll(items); flush() }

    func flush() {
        guard !isUploading, !items.isEmpty else { return }
        isUploading = true
        Task { await uploadNext() }
    }

    private func removeFirst() { if !items.isEmpty { items.removeFirst(); disk.saveAll(items) } }
    private func peek() -> AvgSpeedReportDTO? { items.first }
    private func resetBackoff() { currentBackoff = 0 }

    private func scheduleRetry() {
        currentBackoff = currentBackoff == 0 ? backoffBase : min(maxBackoff, currentBackoff * 2)
        let delay = currentBackoff
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.isUploading = false
            self?.flush()
        }
    }

    private func uploadNext() async {
        guard let next = peek() else { isUploading = false; return }
        do {
            try await api.postAvgSpeed(next)
            removeFirst(); resetBackoff()
            if items.isEmpty { isUploading = false } else { await uploadNext() }
        } catch {
            print("[RetryQueue] Upload failed: \(error)")
            scheduleRetry()
        }
    }
}

// =============================================
// File: Core/SpeedMonitor.swift
// =============================================

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

// =============================================
// File: Core/YettelSpeedSDK.swift
// =============================================

import Foundation
import Combine

public final class YettelSpeedSDK: ObservableObject {
    private let config: YettelSpeedConfig
    private let api: APIClient
    private let repo: CameraRepository
    private let diskQueue: AvgSpeedDiskQueue
    private let retryQueue: AvgSpeedRetryQueue
    public let monitor: SpeedMonitor

    @Published public private(set) var lastResults: [AverageSpeedResult] = []
    private var cancellables = Set<AnyCancellable>()

    public init(config: YettelSpeedConfig) {
        self.config = config
        self.api = APIClient(baseURL: config.baseURL, authProvider: config.authProvider)
        self.repo = CameraRepository(api: api)
        self.diskQueue = AvgSpeedDiskQueue()
        self.retryQueue = AvgSpeedRetryQueue(disk: diskQueue, api: api)
        self.monitor = SpeedMonitor(repo: repo, config: config, retryQueue: retryQueue)
        monitor.onAverageSpeedComputed = { [weak self] r in self?.appendResult(r) }
        monitor.resultPublisher.sink { [weak self] r in self?.appendResult(r) }.store(in: &cancellables)
    }

    private func appendResult(_ r: AverageSpeedResult) {
        lastResults.insert(r, at: 0)
        if lastResults.count > 100 { lastResults.removeLast() }
    }

    /// Call AFTER user consented to location. Refreshes remote data and starts monitoring.
    public func start() {
        Task {
            do { try await repo.refresh(defaultRadius: config.defaultRadius) }
            catch { print("[SDK] Refresh failed: \(error)") }
            monitor.start()
        }
    }

    public func stop() { monitor.stop() }
}

// =============================================
// File: DemoUI/LiveSpeedView.swift (Optional)
// =============================================

#if canImport(SwiftUI)
import SwiftUI
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

public struct LiveSpeedView: View {
    @StateObject var vm: SpeedDemoViewModel

    public init(sdk: YettelSpeedSDK) { _vm = StateObject(wrappedValue: SpeedDemoViewModel(sdk: sdk)) }

    public var body: some View {
        VStack(spacing: 12) {
            header
            controls
            List(vm.results, id: \.self) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.segmentName).font(.headline)
                    Text(String(format: "Avg: %.1f km/h  •  Dist: %.0f m  •  Dur: %.0f s",
                                r.averageSpeedKmh, r.routeDistanceMeters, r.endTime.timeIntervalSince(r.startTime)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Start: \(vm.fmt(r.startTime))  End: \(vm.fmt(r.endTime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Yettel Average Speed Monitor").font(.title3).bold()
                Text(vm.permissionText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: vm.toggle) {
                Text(vm.isRunning ? "Stop" : "Start")
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(vm.isRunning ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button("Clear") { vm.clear() }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
    }
}

public final class SpeedDemoViewModel: ObservableObject {
    @Published var results: [AverageSpeedResult] = []
    @Published var isRunning = false
    @Published var permissionText = "Location permission: Unknown"

    private let sdk: YettelSpeedSDK

    init(sdk: YettelSpeedSDK) {
        self.sdk = sdk
        // Bind to SDK updates
        sdk.$lastResults
            .receive(on: DispatchQueue.main)
            .assign(to: &self.$results)
        updatePermissionText()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updatePermissionText()
        }
        #endif
    }

    func toggle() {
        if isRunning { sdk.stop() } else { sdk.start() }
        isRunning.toggle()
    }

    func clear() { results.removeAll() }

    func fmt(_ d: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .none; df.timeStyle = .medium
        return df.string(from: d)
    }

    private func updatePermissionText() {
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .authorizedAlways: permissionText = "Location permission: Always"
        case .authorizedWhenInUse: permissionText = "Location permission: When In Use"
        case .denied: permissionText = "Location permission: Denied"
        case .restricted: permissionText = "Location permission: Restricted"
        case .notDetermined: permissionText = "Location permission: Not Determined"
        @unknown default: permissionText = "Location permission: Unknown"
        }
    }
}
#endif

// =============================================
// Integration Notes (Info.plist & App setup)
// =============================================
// 1) Info.plist:
//    - NSLocationWhenInUseUsageDescription = "This feature measures average speed between road sections using your location."
//    - NSLocationAlwaysAndWhenInUseUsageDescription = "Allows background monitoring of speed segments."
//    Background Modes → Location updates = ON
//
// 2) Create & keep SDK singleton (DI):
//    let cfg = YettelSpeedConfig(baseURL: URL(string: "https://api.yettel.bg")!, authProvider: { TokenStore.shared.jwt })
//    let speedSDK = YettelSpeedSDK(config: cfg)
//    // After user consents:
//    speedSDK.start()
//
// 3) Backend endpoints (proposed):
//    GET /v1/traffic/cameras   -> [CameraDTO]
//    GET /v1/traffic/segments  -> [SegmentDTO]
//    POST /v1/traffic/avg-speed-report  (AvgSpeedReportDTO)
//    Use Authorization: Bearer <JWT>
//
// 4) Privacy: Show an in-app consent screen. Consider anonymizing deviceId. Respect local laws.
