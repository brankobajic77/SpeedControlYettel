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
