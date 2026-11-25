import CoreLocation
import CoreMotion
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RouteRecorder: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum State {
        case idle, requestingPermission, recording, paused
    }

    private(set) var state: State = .idle
    private(set) var mode: TravelMode = .unknown
    private(set) var activeRoute: RecordedRoute?
    private(set) var needsPreciseLocation = false
    private(set) var locationUnavailable = false
    var notice: String?

    private let context: ModelContext
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private var recordingStartedAt: Date?
    private var lastPoint: CLLocation?
    private var sensorMode: TravelMode = .unknown
    private var speedCandidate: TravelMode = .unknown
    private var speedObservations = 0
    private var recordingID = UUID()

    init(context: ModelContext) {
        self.context = context
        super.init()
        locationManager.delegate = self
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.pausesLocationUpdatesAutomatically = false
        recoverUnfinishedRoute()
    }

    func start() {
        guard state == .idle || state == .paused else { return }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            state = .requestingPermission
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginRecording()
        case .denied, .restricted:
            notice = "请在系统设置中允许 Life Mem 使用定位，然后重新开始记录。"
        @unknown default:
            notice = "暂时无法读取定位权限。"
        }
    }

    func pause() {
        guard state == .recording else { return }
        stopUpdates()
        state = .paused
    }

    func finish() {
        guard state == .paused, let route = activeRoute else { return }
        if route.pointCount == 0 {
            context.delete(route)
        } else {
            route.isFinished = true
        }
        do {
            try context.save()
            activeRoute = nil
            state = .idle
        } catch {
            context.rollback()
            notice = "暂时无法结束这条路线。请检查设备的可用存储空间后重试。"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            needsPreciseLocation = manager.accuracyAuthorization == .reducedAccuracy
            if state == .requestingPermission { beginRecording() }
        case .denied, .restricted:
            if state == .recording { pause() }
            if state == .requestingPermission { state = activeRoute == nil ? .idle : .paused }
            notice = "记录路线需要定位权限。可以在系统设置中选择「使用 App 期间」。"
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .recording, let route = activeRoute, let recordingStartedAt else { return }
        let latestAllowed = Date().addingTimeInterval(5)
        for location in locations where location.timestamp >= recordingStartedAt && location.timestamp <= latestAllowed {
            guard CLLocationCoordinate2DIsValid(location.coordinate),
                  (0...65).contains(location.horizontalAccuracy) else { continue }
            if let lastPoint, location.timestamp <= lastPoint.timestamp { continue }
            updateMode(from: location)
            let sampling = LocationSampling(mode: mode)
            guard let step = sampling.assess(location, after: lastPoint, mode: mode) else { continue }
            let point = RoutePoint(location: location, mode: mode, startsNewSegment: step.startsNewSegment, route: route)
            context.insert(point)
            route.pointCount += 1
            route.distanceMeters += step.distance
            do {
                try context.save()
                lastPoint = location
                locationUnavailable = false
            } catch {
                context.rollback()
                pause()
                notice = "保存失败，已暂停记录。已保存的轨迹仍可回看。请检查存储空间后再继续。"
                return
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard state == .recording else { return }
        if (error as? CLError)?.code == .denied {
            pause()
            notice = "定位权限已关闭。已保存的路线可以在「路线」中回看。"
        } else {
            locationUnavailable = true
        }
    }

    private func recoverUnfinishedRoute() {
        var request = FetchDescriptor<RecordedRoute>(
            predicate: #Predicate { !$0.isFinished },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        request.fetchLimit = 1
        do {
            activeRoute = try context.fetch(request).first
            if activeRoute != nil { state = .paused }
        } catch {
            notice = "暂时无法读取未完成的路线。"
        }
    }

    private func beginRecording() {
        if activeRoute == nil {
            let route = RecordedRoute(startedAt: .now)
            context.insert(route)
            do {
                try context.save()
                activeRoute = route
            } catch {
                context.rollback()
                state = .idle
                notice = "路线无法保存。请检查设备的可用存储空间后重试。"
                return
            }
        }
        state = .recording
        recordingStartedAt = .now
        recordingID = UUID()
        lastPoint = nil
        sensorMode = .unknown
        speedCandidate = .unknown
        speedObservations = 0
        mode = .unknown
        needsPreciseLocation = locationManager.accuracyAuthorization == .reducedAccuracy
        locationUnavailable = false
        configureLocation(for: .unknown)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()

        if CMMotionActivityManager.isActivityAvailable() {
            let currentRecordingID = recordingID
            motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity, activity.confidence != .low else { return }
                MainActor.assumeIsolated {
                    guard let self, self.state == .recording, self.recordingID == currentRecordingID else { return }
                    self.updateMotionActivity(activity)
                }
            }
        }
    }

    private func stopUpdates() {
        recordingStartedAt = nil
        recordingID = UUID()
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        motionManager.stopActivityUpdates()
    }

    private func updateMotionActivity(_ activity: CMMotionActivity) {
        // Core Motion can report both automotive and stationary at a traffic light.
        if activity.automotive {
            sensorMode = .automotive
        } else if activity.walking || activity.running {
            sensorMode = .walking
        } else if activity.cycling {
            sensorMode = .cycling
        } else if activity.stationary {
            sensorMode = .stationary
        } else {
            sensorMode = .unknown
        }
        speedCandidate = .unknown
        speedObservations = 0
        applyMode(sensorMode)
    }

    private func updateMode(from location: CLLocation) {
        guard sensorMode == .unknown || sensorMode == .stationary,
              location.speed >= 0, (0...3).contains(location.speedAccuracy),
              location.horizontalAccuracy <= 35 else { return }
        let candidate: TravelMode
        switch location.speed {
        case 7.5...: candidate = .automotive
        case 0.7...2.8: candidate = .walking
        default: candidate = .unknown
        }
        if candidate == speedCandidate {
            speedObservations = min(speedObservations + 1, 2)
        } else {
            speedCandidate = candidate
            speedObservations = 1
        }
        // Uncertain speed samples should not interrupt a previously recognized trip.
        if candidate != .unknown, speedObservations >= 2 { applyMode(candidate) }
    }

    private func applyMode(_ newMode: TravelMode) {
        guard mode != newMode else { return }
        mode = newMode
        configureLocation(for: newMode)
    }

    private func configureLocation(for mode: TravelMode) {
        let sampling = LocationSampling(mode: mode)
        locationManager.desiredAccuracy = sampling.desiredAccuracy
        locationManager.distanceFilter = sampling.distanceFilter
        switch mode {
        case .automotive: locationManager.activityType = .automotiveNavigation
        case .walking, .cycling: locationManager.activityType = .fitness
        case .stationary, .unknown: locationManager.activityType = .other
        }
    }
}
