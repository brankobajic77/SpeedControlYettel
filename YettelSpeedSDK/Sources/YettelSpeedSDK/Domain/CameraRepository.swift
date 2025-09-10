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
