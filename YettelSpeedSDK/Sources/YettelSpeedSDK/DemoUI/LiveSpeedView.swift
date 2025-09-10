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

