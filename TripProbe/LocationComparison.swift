import CoreLocation
import MapKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class LocationComparison: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waitingForPermission = false
    private var startedAt: Date?
    private var timeout: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var sample: CLLocation?
    private(set) var mapFix: CLLocation?
    private(set) var status = "点「开始对照」后会采样 45 秒。"
    private(set) var precise = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        precise = manager.accuracyAuthorization == .fullAccuracy
    }

    var separation: Double? {
        guard let sample, let mapFix, abs(sample.timestamp.timeIntervalSince(mapFix.timestamp)) <= 5 else { return nil }
        return sample.distance(from: mapFix)
    }

    var convertedCoordinate: CLLocationCoordinate2D? {
        sample.flatMap { AMapCoordinateCandidate.converted($0.coordinate) }
    }

    var convertedSeparation: Double? {
        guard separation != nil, let convertedCoordinate, let mapFix else { return nil }
        return CLLocation(latitude: convertedCoordinate.latitude, longitude: convertedCoordinate.longitude).distance(from: mapFix)
    }

    func start() {
        guard !isRunning else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            waitingForPermission = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            status = "请在系统设置中允许「使用 App 期间」定位。"
        }
    }

    private func begin() {
        waitingForPermission = false
        sample = nil
        mapFix = nil
        startedAt = .now
        isRunning = true
        status = "等待蓝点与紫圈出现。请保持在同一位置。"
        manager.startUpdatingLocation()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) }
            catch { return }
            self?.stop()
        }
    }

    func stop() {
        waitingForPermission = false
        guard isRunning else { return }
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        isRunning = false
        startedAt = nil
        status = sample == nil || mapFix == nil ? "对照结束。定位结果尚未齐全。" : "对照结束。下方保留最后一组读数。"
    }

    func forget() {
        stop()
        sample = nil
        mapFix = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        precise = manager.accuracyAuthorization == .fullAccuracy
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if waitingForPermission { begin() }
        case .denied, .restricted:
            stop()
            status = "请在系统设置中允许「使用 App 期间」定位。"
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, accepts(fix), fix.timestamp >= (sample?.timestamp ?? .distantPast) else { return }
        sample = fix
    }

    func updateMapFix(_ fix: CLLocation) {
        guard accepts(fix), fix.timestamp >= (mapFix?.timestamp ?? .distantPast) else { return }
        mapFix = fix
    }

    private func accepts(_ fix: CLLocation) -> Bool {
        guard let startedAt else { return false }
        return fix.timestamp >= startedAt && fix.timestamp <= Date.now.addingTimeInterval(5) &&
            CLLocationCoordinate2DIsValid(fix.coordinate) && fix.horizontalAccuracy.isFinite && fix.horizontalAccuracy >= 0
    }
}

struct LocationComparisonView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var comparison = LocationComparison()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(comparison.status)
                Button(comparison.isRunning ? "结束对照" : "开始对照") {
                    if comparison.isRunning { comparison.stop() } else { comparison.start() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if comparison.isRunning || comparison.sample != nil {
                    ComparisonMap(isRunning: comparison.isRunning, sample: comparison.sample, mapFix: comparison.mapFix,
                                  convertedCoordinate: comparison.convertedCoordinate,
                                  updateMapFix: comparison.updateMapFix)
                        .frame(height: 250)
                        .clipShape(.rect(cornerRadius: 12))
                        .accessibilityLabel("定位对照地图")
                    Text("蓝点是地图实时定位，紫圈是原始位置，橙圈是高德坐标换算预览。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("蓝点与紫圈中心距离", value: meters(comparison.separation))
                    if comparison.convertedCoordinate != nil {
                        LabeledContent("蓝点与橙圈中心距离", value: meters(comparison.convertedSeparation))
                    }
                    LabeledContent("精确位置", value: comparison.precise ? "已开启" : "未开启")
                    LabeledContent("紫圈定位精度估计", value: meters(comparison.sample?.horizontalAccuracy))
                }
            }
            .padding(16)
        }
        .navigationTitle("定位对照")
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { comparison.forget() }
        }
        .onDisappear { comparison.forget() }
    }

    private func meters(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) 米" } ?? "等待定位"
    }
}

private struct ComparisonMap: UIViewRepresentable {
    let isRunning: Bool
    let sample: CLLocation?
    let mapFix: CLLocation?
    let convertedCoordinate: CLLocationCoordinate2D?
    let updateMapFix: (CLLocation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.updateMapFix = updateMapFix
        if map.showsUserLocation != isRunning { map.showsUserLocation = isRunning }
        if sample?.timestamp != coordinator.sampleTime {
            map.removeOverlays(map.overlays)
            coordinator.convertedCircle = nil
            coordinator.sampleTime = sample?.timestamp
            if let sample { map.addOverlay(MKCircle(center: sample.coordinate, radius: 12)) }
            if let convertedCoordinate {
                let circle = MKCircle(center: convertedCoordinate, radius: 20)
                coordinator.convertedCircle = circle
                map.addOverlay(circle)
            }
        }
        if sample == nil { coordinator.fittedPair = false }
        if !coordinator.fittedPair, let sample, let mapFix {
            let first = MKMapPoint(sample.coordinate)
            let second = MKMapPoint(mapFix.coordinate)
            let padding = 150 * MKMapPointsPerMeterAtLatitude(sample.coordinate.latitude)
            let rect = MKMapRect(x: min(first.x, second.x) - padding, y: min(first.y, second.y) - padding,
                                 width: abs(first.x - second.x) + 2 * padding, height: abs(first.y - second.y) + 2 * padding)
            map.setVisibleMapRect(rect, animated: false)
            coordinator.fittedPair = true
        } else if !coordinator.fittedPair, let fix = sample ?? mapFix, !coordinator.centered {
            map.setRegion(MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: 700, longitudinalMeters: 700), animated: false)
            coordinator.centered = true
        }
        if sample == nil && mapFix == nil { coordinator.centered = false }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var updateMapFix: ((CLLocation) -> Void)?
        var convertedCircle: MKCircle?
        var sampleTime: Date?
        var centered = false
        var fittedPair = false

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let fix = userLocation.location else { return }
            // Defer the view-state update if MapKit emits during updateUIView.
            Task { @MainActor [weak self] in self?.updateMapFix?(fix) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = circle === convertedCircle ? .systemOrange : .systemPurple
            renderer.lineWidth = 3
            return renderer
        }
    }
}
