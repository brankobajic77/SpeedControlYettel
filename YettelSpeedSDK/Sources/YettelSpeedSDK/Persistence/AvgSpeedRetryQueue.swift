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

