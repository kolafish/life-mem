import CoreLocation
import CoreMotion
import Foundation
import Observation
import SwiftUI
import UIKit

@main
struct TripProbeApp: App {
    @UIApplicationDelegateAdaptor(TripProbeDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { TripProbeView(probe: delegate.probe) }
    }
}

@MainActor
final class TripProbeDelegate: NSObject, UIApplicationDelegate {
    let probe = TripProbe()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        probe.restore(launchedForLocation: options?[.location] != nil)
        return true
    }
}

private func acceptsSignificantFix(_ timestamp: Date, receivedAt: Date, after previous: TimeInterval,
                                   ignoringThrough cutoff: Date?) -> Bool {
    timestamp <= receivedAt && timestamp.timeIntervalSince1970 > previous && (cutoff.map { timestamp > $0 } ?? true)
}

@MainActor
@Observable
final class TripProbe: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let departureMeasurementWindow: TimeInterval = 30 * 60
    private static let initialFixWindow: TimeInterval = 15

    enum Phase: String {
        case off = "未开启"
        case listening = "低功耗监听"
        case checking = "正在验证移动"
        case sampling = "高精度采样"
    }

    struct Statistics: Codable {
        var backgroundLaunches = 0
        var significantChanges = 0
        var visitDepartures = 0
        var checks = 0
        var confirmed = 0
        var endedWithoutMovement = 0
        var highAccuracySeconds = 0
        var significantCallbacks: Int?
        var visitCallbacks: Int?
        var listenerErrors: Int?
        var lastEventDelay: Int?
        var lastFirstFixDelay: Int?
        var lastDepartureToFix: Int?
    }

    private(set) var resumeTrial: ResumeTrial? {
        didSet {
            // The trace store checkpoints each fix. Preferences retain the summary between trials.
            if oldValue?.beganAt != resumeTrial?.beganAt || oldValue?.pauses != resumeTrial?.pauses
                || oldValue?.resumes != resumeTrial?.resumes {
                persistResumeSummary()
            }
        }
    }

    private func persistResumeSummary() {
        defaults.set(try? resumeTrial.map { try JSONEncoder().encode($0) }, forKey: "resumeTrial")
    }

    private var liveTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private(set) var testingResume = false

    private enum Signal {
        case significantChange, visitDeparture
    }

    private let defaults = UserDefaults.standard
    private let signals = CLLocationManager()
    private let gps = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private let clock = ContinuousClock()
    private var watchdog: Task<Void, Never>?
    private var initialFixCutoff: Date?
    private var startedAt: Date?
    private var startedTick: ContinuousClock.Instant?
    private var lastMovement: ContinuousClock.Instant?
    private var firstFix: CLLocation?
    private var latestFixTime: Date?
    private var movingFixes = 0
    private var motionSuggestsMovement = false

    private(set) var phase = Phase.off
    private(set) var authorization = CLAuthorizationStatus.notDetermined
    private(set) var preciseLocation = false
    private(set) var error: String?
    private(set) var markedDeparture: Date? {
        didSet { defaults.set(markedDeparture, forKey: "markedDeparture") }
    }
    private(set) var stats = Statistics() {
        didSet { defaults.set(try? JSONEncoder().encode(stats), forKey: "probeStatistics") }
    }

    override init() {
        super.init()
        if let data = defaults.data(forKey: "probeStatistics"),
           let saved = try? JSONDecoder().decode(Statistics.self, from: data) { stats = saved }
        if let data = defaults.data(forKey: "resumeTrial") {
            resumeTrial = try? JSONDecoder().decode(ResumeTrial.self, from: data)
        }
        signals.delegate = self
        gps.delegate = self
        gps.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        gps.distanceFilter = kCLDistanceFilterNone
        gps.pausesLocationUpdatesAutomatically = false
        gps.showsBackgroundLocationIndicator = true
        authorization = signals.authorizationStatus
        preciseLocation = signals.accuracyAuthorization == .fullAccuracy
    }

    func restore(launchedForLocation: Bool) {
        guard defaults.bool(forKey: "listeningEnabled") else { return }
        guard authorization == .authorizedAlways else {
            defaults.set(false, forKey: "listeningEnabled")
            markedDeparture = nil
            return
        }
        if let saved = defaults.object(forKey: "markedDeparture") as? Date,
           (0..<Self.departureMeasurementWindow).contains(Date.now.timeIntervalSince(saved)) {
            markedDeparture = saved
        } else {
            markedDeparture = nil
        }
        if defaults.bool(forKey: "testingResume"), resumeTrial != nil {
            startResumeStream()
        } else {
            if launchedForLocation { stats.backgroundLaunches += 1 }
            listen(ignoresInitialFix: !launchedForLocation)
        }
    }

    func enable() {
        guard phase == .off else { return }
        error = nil
        switch authorization {
        case .notDetermined: signals.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: signals.requestAlwaysAuthorization()
        case .authorizedAlways:
            defaults.set(false, forKey: "testingResume")
            defaults.set(true, forKey: "listeningEnabled")
            listen(ignoresInitialFix: true)
        default: error = "请在系统设置中允许始终定位，再回来开启测试。"
        }
    }

    func enableResumeTrial() {
        guard phase == .off, authorization == .authorizedAlways else { return }
        error = nil
        markedDeparture = nil
        resumeTrial = ResumeTrial(beganAt: .now)
        defaults.set(true, forKey: "testingResume")
        defaults.set(true, forKey: "listeningEnabled")
        startResumeStream()
    }

    private func startResumeStream() {
        testingResume = true
        phase = .listening
        backgroundSession = CLBackgroundActivitySession()
        guard let trial = resumeTrial else { return }
        liveTask = Task {
            do {
                let directory = URL.applicationSupportDirectory.appending(path: "ResumeTrace", directoryHint: .isDirectory)
                let trace = try await ResumeTrace.open(directory: directory, trial: trial)
                let checkpoint = await trace.checkpoint
                try Task.checkCancellation()
                resumeTrial = checkpoint
                for try await update in CLLocationUpdate.liveUpdates() {
                    try Task.checkCancellation()
                    guard let fix = update.location else { continue }
                    let mark = markedDeparture
                    let next = try await trace.record(fix, stationary: update.isStationary, receivedAt: .now,
                        markedAt: mark, markWindow: Self.departureMeasurementWindow)
                    try Task.checkCancellation()
                    if let next {
                        if next.resumes > (resumeTrial?.resumes ?? 0), markedDeparture == mark {
                            markedDeparture = nil
                        }
                        resumeTrial = next
                    }
                }
                try Task.checkCancellation()
                stop()
                error = "定位更新已结束，可重新开启测试。"
            } catch {
                guard !Task.isCancelled else { return }
                stop()
                self.error = "定位或轨迹保存失败。已保存的点仍在本机，请检查定位权限和剩余空间，再重新开启测试。"
            }
        }
    }

    func stop() {
        if testingResume { persistResumeSummary() }
        liveTask?.cancel()
        liveTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        testingResume = false
        defaults.set(false, forKey: "testingResume")
        defaults.set(false, forKey: "listeningEnabled")
        markedDeparture = nil
        signals.stopMonitoringVisits()
        signals.stopMonitoringSignificantLocationChanges()
        endGPS()
        phase = .off
    }

    func markDeparture() {
        guard phase == .listening else { return }
        markedDeparture = .now
        if testingResume { resumeTrial?.lastMarkedDelay = nil }
        else { stats.lastDepartureToFix = nil }
    }

    func expireDepartureMark(_ departure: Date) {
        guard markedDeparture == departure,
              Date.now.timeIntervalSince(departure) >= Self.departureMeasurementWindow else { return }
        markedDeparture = nil
    }

    func requestMotion() {
        guard CMMotionActivityManager.isActivityAvailable(), CMMotionActivityManager.authorizationStatus() == .notDetermined else { return }
        // Request permission in the foreground. Use activity updates only while checking or sampling.
        let now = Date.now
        motion.queryActivityStarting(from: now.addingTimeInterval(-1), to: now, to: .main) { _, _ in }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = signals.authorizationStatus
        preciseLocation = signals.accuracyAuthorization == .fullAccuracy
        if authorization != .authorizedAlways && phase != .off { stop() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard phase != .off, !testingResume, authorization == .authorizedAlways else { return }
        if manager === signals {
            stats.significantCallbacks = (stats.significantCallbacks ?? 0) + 1
            guard let fix = locations.last,
                  acceptsSignificantFix(fix.timestamp, receivedAt: .now, after: defaults.double(forKey: "lastSignificantFix"),
                                        ignoringThrough: initialFixCutoff) else { return }
            defaults.set(fix.timestamp.timeIntervalSince1970, forKey: "lastSignificantFix")
            receive(.significantChange, at: fix.timestamp)
        } else if manager === gps {
            for fix in locations { assess(fix) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard manager === signals, phase != .off, !testingResume, authorization == .authorizedAlways else { return }
        stats.visitCallbacks = (stats.visitCallbacks ?? 0) + 1
        guard visit.departureDate != .distantFuture else { return }
        let timestamp = visit.departureDate.timeIntervalSince1970
        guard timestamp > defaults.double(forKey: "lastVisitDeparture") else { return }
        defaults.set(timestamp, forKey: "lastVisitDeparture")
        receive(.visitDeparture, at: visit.departureDate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError failure: Error) {
        if manager === signals, phase != .off, !testingResume {
            stats.listenerErrors = (stats.listenerErrors ?? 0) + 1
        }
        if (failure as? CLError)?.code == .denied {
            if signals.authorizationStatus != .authorizedAlways { stop() }
        }
    }

    private func listen(ignoresInitialFix: Bool) {
        initialFixCutoff = ignoresInitialFix ? .now.addingTimeInterval(Self.initialFixWindow) : nil
        phase = .listening
        signals.startMonitoringVisits()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            signals.startMonitoringSignificantLocationChanges()
        }
    }

    private func receive(_ source: Signal, at timestamp: Date) {
        let delay = Date.now.timeIntervalSince(timestamp)
        guard delay.isFinite, delay >= 0 else { return }
        switch source {
        case .significantChange: stats.significantChanges += 1
        case .visitDeparture: stats.visitDepartures += 1
        }
        stats.lastEventDelay = Int(delay)
        guard delay <= 300, phase == .listening else { return }

        phase = .checking
        stats.checks += 1
        startedAt = .now
        startedTick = clock.now
        firstFix = nil
        latestFixTime = nil
        movingFixes = 0
        motionSuggestsMovement = false
        gps.allowsBackgroundLocationUpdates = true
        gps.startUpdatingLocation()
        if CMMotionActivityManager.authorizationStatus() == .authorized {
            let session = startedAt
            motion.startActivityUpdates(to: .main) { [weak self] activity in
                MainActor.assumeIsolated {
                    guard let self, self.startedAt == session, let activity, activity.confidence != .low else { return }
                    self.motionSuggestsMovement = activity.walking || activity.running || activity.cycling || activity.automotive
                }
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard let self else { return }
                self.expireIfNeeded()
            }
        }
    }

    private func assess(_ fix: CLLocation) {
        expireIfNeeded()
        guard let startedAt, fix.timestamp >= startedAt,
              fix.timestamp > (latestFixTime ?? .distantPast),
              (0...50).contains(fix.horizontalAccuracy), CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        latestFixTime = fix.timestamp
        if firstFix == nil {
            firstFix = fix
            stats.lastFirstFixDelay = Int(max(0, Date.now.timeIntervalSince(startedAt)))
            if let departure = markedDeparture {
                let delay = fix.timestamp.timeIntervalSince(departure)
                if delay >= 0 {
                    if delay < Self.departureMeasurementWindow { stats.lastDepartureToFix = Int(delay) }
                    markedDeparture = nil
                }
            }
        }

        let reliableSpeed = (0.9...55).contains(fix.speed) && (0...1.5).contains(fix.speedAccuracy)
        movingFixes = reliableSpeed ? min(2, movingFixes + 1) : 0
        let displaced = firstFix.map { fix.distance(from: $0) > max(20, $0.horizontalAccuracy + fix.horizontalAccuracy) } ?? false
        if phase == .checking, movingFixes == 2 || (motionSuggestsMovement && displaced) {
            phase = .sampling
            stats.confirmed += 1
            lastMovement = clock.now
        }
        if phase == .sampling, reliableSpeed || motionSuggestsMovement && displaced {
            lastMovement = clock.now
            firstFix = fix
        }
    }

    private func expireIfNeeded() {
        guard let startedTick else { return }
        let now = clock.now
        let total = startedTick.duration(to: now)
        if phase == .checking, total >= .seconds(45) {
            stats.endedWithoutMovement += 1
            endGPS()
        } else if phase == .sampling,
                  total >= .seconds(15 * 60) || (lastMovement.map { $0.duration(to: now) >= .seconds(3 * 60) } ?? false) {
            endGPS()
        }
    }

    private func endGPS() {
        watchdog?.cancel()
        watchdog = nil
        gps.stopUpdatingLocation()
        gps.allowsBackgroundLocationUpdates = false
        motion.stopActivityUpdates()
        if let startedTick { stats.highAccuracySeconds += Int(startedTick.duration(to: clock.now).components.seconds) }
        startedAt = nil
        startedTick = nil
        firstFix = nil
        latestFixTime = nil
        lastMovement = nil
        if phase != .off { phase = .listening }
    }
}

private struct TripProbeView: View {
    let probe: TripProbe
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundRefresh = UIBackgroundRefreshStatus.available

    private var backgroundRefreshLabel: String {
        switch backgroundRefresh {
        case .available: "已开启"
        case .denied: "已关闭"
        case .restricted: "受系统限制"
        @unknown default: "未知"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("状态", value: probe.testingResume
                        ? (probe.resumeTrial?.waitingForMovement == true ? "已静止，等待出发" : "实时定位中")
                        : probe.phase.rawValue)
                    LabeledContent("始终定位", value: probe.authorization == .authorizedAlways ? "已允许" : "待允许")
                    LabeledContent("精确位置", value: probe.preciseLocation ? "已开启" : "未开启")
                    LabeledContent("后台 App 刷新", value: backgroundRefreshLabel)
                    if probe.phase == .off {
                        Button(probe.authorization == .authorizedAlways ? "开启监听" : "设置定位权限", action: probe.enable)
                        if probe.authorization == .authorizedAlways {
                            Button("测试静止后恢复", action: probe.enableResumeTrial)
                        }
                        if CMMotionActivityManager.authorizationStatus() == .notDetermined {
                            Button("允许使用运动辅助", action: probe.requestMotion)
                        }
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } else {
                        if probe.markedDeparture != nil {
                            Label("已标记，可以锁屏出发", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.primary)
                        }
                        if probe.phase == .listening && (!probe.testingResume || probe.resumeTrial?.waitingForMovement == true) {
                            Button(probe.markedDeparture == nil ? "标记这次出发" : "重新标记出发", action: probe.markDeparture)
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        Button("停止监听", role: .destructive, action: probe.stop)
                    }
                    if let error = probe.error { Text(error).foregroundStyle(.secondary) }
                } footer: {
                    Text("静止恢复测试会在本机保存轨迹、自动暂停和恢复时间。可随时停止监听。")
                }
                Section {
                    NavigationLink("定位对照") { LocationComparisonView() }
                        .disabled(probe.phase != .off)
                } footer: {
                    if probe.phase != .off { Text("停止守护监听后可以运行定位对照。") }
                }
                if let trial = probe.resumeTrial {
                    Section("静止恢复测试") {
                        counter("自动暂停", trial.pauses)
                        counter("移动后恢复", trial.resumes)
                        counter("本轮已保存轨迹点", trial.savedPoints ?? 0)
                        if let delay = trial.lastMarkedDelay { counter("标记出发到恢复（秒）", delay) }
                    }
                }
                Section("低功耗监听统计") {
                    counter("定位事件后台启动", probe.stats.backgroundLaunches)
                    counter("显著位置回调（含初始）", probe.stats.significantCallbacks ?? 0)
                    counter("停留回调（含到达）", probe.stats.visitCallbacks ?? 0)
                    counter("低功耗监听错误", probe.stats.listenerErrors ?? 0)
                    counter("显著位置变化事件", probe.stats.significantChanges)
                    counter("离开停留事件", probe.stats.visitDepartures)
                    counter("启动验证", probe.stats.checks)
                    counter("确认移动", probe.stats.confirmed)
                    counter("无移动结束验证", probe.stats.endedWithoutMovement)
                    counter("已结束高精度采样秒数", probe.stats.highAccuracySeconds)
                    if let delay = probe.stats.lastEventDelay { counter("最近事件延迟秒数", delay) }
                    if let delay = probe.stats.lastFirstFixDelay { counter("最近首个有效点耗时", delay) }
                    if let delay = probe.stats.lastDepartureToFix { counter("从标记出发到首个有效点的秒数", delay) }
                }
            }
            .navigationTitle("守护测试")
            .onChange(of: scenePhase, initial: true) {
                backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
            }
            .task(id: probe.markedDeparture) {
                guard let departure = probe.markedDeparture else { return }
                let expiry = departure.addingTimeInterval(TripProbe.departureMeasurementWindow)
                do {
                    try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
                    probe.expireDepartureMark(departure)
                } catch { return }
            }
        }
    }

    private func counter(_ title: String, _ count: Int) -> some View {
        LabeledContent(title, value: count.formatted())
            .monospacedDigit()
    }
}
