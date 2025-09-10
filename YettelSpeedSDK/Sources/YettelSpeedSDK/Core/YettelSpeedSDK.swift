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
