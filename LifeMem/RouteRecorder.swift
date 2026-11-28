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
    private(set) var recoveredUnfinishedRoute = false
    private(set) var isDeletingRoute = false
    private(set) var needsPreciseLocation = false
    private(set) var locationUnavailable = false
    var notice: String?

    let automaticTrips: AutomaticTrips
    private let preferences: UserDefaults
    private(set) var automaticEnabled: Bool
    private(set) var automaticNeedsSettings = false
    private var automaticTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?

    private let context: ModelContext
    private let summaryIndex: RouteSummaryIndex
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private var recordingStartedAt: Date?
    private var lastPoint: (location: CLLocation, mode: TravelMode)?
    private var sensorMode: TravelMode = .unknown
    private var speedEstimate = SpeedModeEstimate()
    private var recordingID = UUID()

    init(context: ModelContext, summaryIndex: RouteSummaryIndex, preferences: UserDefaults) {
        self.preferences = preferences
        automaticEnabled = preferences.bool(forKey: "automaticRecordingEnabled")
        automaticTrips = AutomaticTrips(context: context)
        self.context = context
        self.summaryIndex = summaryIndex
        super.init()
        locationManager.delegate = self
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.pausesLocationUpdatesAutomatically = false
        recoverUnfinishedRoute()
        if automaticEnabled && state == .idle {
            updateAutomaticAuthorization()
        }
    }

    func setAutomatic(_ enabled: Bool) {
        guard enabled != automaticEnabled, !isDeletingRoute else { return }
        if enabled {
            guard state == .idle else { return }
            automaticEnabled = true
            preferences.set(Date.now, forKey: "automaticRecordingSince")
            preferences.set(true, forKey: "automaticRecordingEnabled")
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
            updateAutomaticAuthorization()
        } else {
            stopAutomatic()
        }
    }

    private func updateAutomaticAuthorization() {
        needsPreciseLocation = locationManager.accuracyAuthorization == .reducedAccuracy
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            startAutomaticStream()
        case .notDetermined, .restricted, .denied:
            if automaticTask != nil {
                stopAutomatic()
                notice = "自动记录已关闭。允许使用定位后，可以重新开启。"
            } else {
                automaticNeedsSettings = true
            }
        @unknown default:
            stopAutomatic()
            notice = "暂时无法读取定位权限。"
        }
    }

    private func startAutomaticStream() {
        guard automaticTask == nil, state == .idle, automaticEnabled else { return }
        automaticNeedsSettings = false
        needsPreciseLocation = locationManager.accuracyAuthorization == .reducedAccuracy
        locationUnavailable = false
        let enabledAt = preferences.object(forKey: "automaticRecordingSince") as? Date ?? .now
        automaticTrips.sessionStart = enabledAt
        do { try automaticTrips.restore(now: .now) }
        catch {
            automaticFailure()
            return
        }
        // On a background relaunch the first fix may predate this process.
        backgroundSession = CLBackgroundActivitySession()
        automaticTask = Task {
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard !Task.isCancelled else { return }
                    guard !isDeletingRoute else { continue }
                    if let fix = update.location, fix.timestamp < enabledAt { continue }
                    let stationary: Bool
                    if #available(iOS 18, *) { stationary = update.stationary }
                    else { stationary = update.isStationary }
                    locationUnavailable = update.location == nil && !stationary
                    try automaticTrips.receive(update.location, stationary: stationary, receivedAt: .now)
                }
                guard !Task.isCancelled else { return }
                stopAutomatic()
                notice = "自动定位已结束，请重新开启自动记录。"
            } catch {
                guard !Task.isCancelled else { return }
                automaticFailure()
            }
        }
    }

    private func cancelAutomaticStream() {
        automaticTask?.cancel()
        automaticTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        automaticEnabled = false
        automaticNeedsSettings = false
        preferences.set(false, forKey: "automaticRecordingEnabled")
    }

    private func automaticFailure() {
        cancelAutomaticStream()
        automaticTrips.forget()
        recoverUnfinishedRoute()
        notice = "自动记录已中断，之前保存的轨迹仍可回看。请检查定位权限和剩余空间后重试。"
    }

    private func stopAutomatic() {
        cancelAutomaticStream()
        do {
            try automaticTrips.end()
            recoverUnfinishedRoute()
        } catch { automaticFailure() }
    }

    func start() {
        guard !automaticEnabled, !isDeletingRoute, state == .idle || state == .paused else { return }
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
        guard !isDeletingRoute, state == .paused, let route = activeRoute else { return }
        if route.pointCount == 0 {
            context.delete(route)
        } else {
            route.isFinished = true
        }
        do {
            try context.save()
            activeRoute = nil
            recoveredUnfinishedRoute = false
            state = .idle
        } catch {
            context.rollback()
            notice = "暂时无法结束这条路线。请检查设备的可用存储空间后重试。"
        }
    }

    func canDelete(_ route: RecordedRoute) -> Bool {
        guard !isDeletingRoute, route.modelContext === context, !route.isDeleted else { return false }
        if automaticTrips.route?.id == route.id && !route.isFinished { return false }
        return activeRoute?.id != route.id || state == .paused
    }

    func delete(_ route: RecordedRoute) async throws {
        guard canDelete(route) else { return }
        isDeletingRoute = true
        defer { isDeletingRoute = false }

        let id = route.id
        let wasActive = activeRoute?.id == id
        try await summaryIndex.prepareToDelete(routeID: id)
        let wasAutomatic = automaticTrips.route?.id == id
        context.delete(route)
        do {
            try context.save()
        } catch {
            context.rollback()
            await summaryIndex.cancelDeletion(routeID: id)
            throw error
        }

        if wasAutomatic { automaticTrips.forget() }
        if wasActive {
            activeRoute = nil
            recoveredUnfinishedRoute = false
            state = .idle
            recoverUnfinishedRoute()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if automaticEnabled {
            updateAutomaticAuthorization()
            return
        }
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
                  (0...LocationSampling.accuracyLimit).contains(location.horizontalAccuracy) else { continue }
            if let lastPoint, location.timestamp <= lastPoint.location.timestamp { continue }
            updateMode(from: location)
            let sampling = LocationSampling(mode: mode)
            guard let step = sampling.assess(location, after: lastPoint?.location, mode: mode, previousMode: lastPoint?.mode) else { continue }
            let point = RoutePoint(
                location: location,
                mode: mode,
                startsNewSegment: step.startsNewSegment,
                startsRecordingRun: lastPoint == nil,
                route: route
            )
            context.insert(point)
            route.pointCount += 1
            route.distanceMeters += step.distance
            do {
                try context.save()
                lastPoint = (location, mode)
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
            notice = "定位权限已关闭。已保存的路线可以在「回顾」中查看。"
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
            let saved = try context.fetch(request).first
            if automaticEnabled && saved?.isAutomatic == true { return }
            if saved != nil && automaticEnabled { cancelAutomaticStream() }
            activeRoute = saved
            if activeRoute != nil {
                state = .paused
                recoveredUnfinishedRoute = true
            }
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
        if let activeRoute, activeRoute.isAutomatic == true {
            activeRoute.isAutomatic = nil
            activeRoute.automaticPauseAt = nil
            do { try context.save() }
            catch {
                context.rollback()
                notice = "暂时无法继续这条记录，请检查可用存储空间。"
                return
            }
        }
        recoveredUnfinishedRoute = false
        state = .recording
        recordingStartedAt = .now
        recordingID = UUID()
        lastPoint = nil
        sensorMode = .unknown
        speedEstimate = SpeedModeEstimate()
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
        let detected: TravelMode
        if activity.automotive {
            detected = .automotive
        } else if activity.walking || activity.running {
            detected = .walking
        } else if activity.cycling {
            detected = .cycling
        } else if activity.stationary {
            detected = .stationary
        } else {
            detected = .unknown
        }
        guard detected != sensorMode else { return }
        sensorMode = detected
        speedEstimate = SpeedModeEstimate()
        mode = detected
        configureLocation(for: detected)
    }

    private func updateMode(from location: CLLocation) {
        guard sensorMode == .unknown || sensorMode == .stationary,
              let newMode = speedEstimate.observe(location, currentMode: mode), newMode != mode else { return }
        mode = newMode
        configureLocation(for: newMode)
    }

    private func configureLocation(for mode: TravelMode) {
        let sampling = LocationSampling(mode: mode)
        locationManager.desiredAccuracy = sampling.desiredAccuracy
        // Speed-based classification needs samples while slowing down or stopped.
        locationManager.distanceFilter = sensorMode == .unknown || sensorMode == .stationary
            ? kCLDistanceFilterNone : sampling.distanceFilter
        switch mode {
        case .automotive: locationManager.activityType = .automotiveNavigation
        case .walking, .cycling: locationManager.activityType = .fitness
        case .stationary, .unknown: locationManager.activityType = .other
        }
    }
}
