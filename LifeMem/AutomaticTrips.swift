import CoreLocation
import Foundation
import Observation
import SwiftData

/// Turns a stream of live location fixes into ordinary routes in the local archive.
@MainActor
@Observable
final class AutomaticTrips {
    static let shortStop: TimeInterval = 8 * 60

    private let context: ModelContext
    private(set) var route: RecordedRoute?
    var sessionStart: Date?
    var motionActivity: (mode: TravelMode, since: Date)?
    private var lastFix: CLLocation?
    private var lastMode = TravelMode.unknown
    private var dwellAnchor: CLLocation?
    private var observedArrival = false
    private var approach = ArrivalMotion()
    private var departureAnchor: CLLocation?
    private var latestUpdate: Date?
    private var speed = SpeedModeEstimate()
    private var mode = TravelMode.unknown

    init(context: ModelContext) { self.context = context }

    func restore(now: Date) throws {
        var query = FetchDescriptor<RecordedRoute>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        query.fetchLimit = 1
        guard let saved = try context.fetch(query).first, saved.isAutomatic == true,
              saved.automaticSessionStart == nil || saved.automaticSessionStart == sessionStart,
              !saved.isFinished || saved.automaticPauseAt.map({ now.timeIntervalSince($0) <= ArrivalMotion.maximumResumption }) == true
        else { return }
        route = saved
        let ordered = saved.points.sorted { $0.timestamp < $1.timestamp }.map(\.locationPoint)
        if let last = ordered.last {
            lastFix = last.fix
            lastMode = last.mode
            mode = last.mode
            var previous: LocationPoint<PersistentIdentifier>?
            for point in ordered {
                if let previous, !point.continuesObservation(after: previous) { approach = ArrivalMotion() }
                approach.observe(point.mode, at: point.fix)
                previous = point
            }
            latestUpdate = max(last.timestamp, saved.automaticPauseAt ?? .distantPast)
            if approach.supportsVisit, last.mode == .stationary {
                for point in ordered.reversed() {
                    guard point.mode == .stationary,
                          dwellAnchor.map({ $0.timestamp.timeIntervalSince(point.timestamp) <= LocationSampling.maximumGap }) ?? true,
                          point.fix.distance(from: last.fix) <= max(25, last.accuracy) else { break }
                    dwellAnchor = point.fix
                }
                observedArrival = dwellAnchor.map { last.timestamp.timeIntervalSince($0.timestamp) >= Self.shortStop } ?? false
            }
        }
    }

    func receive(_ location: CLLocation?, stationary: Bool, receivedAt: Date) throws {
        // A pause can close the trip even when its coordinate fails the sampling checks.
        let time = location?.timestamp ?? receivedAt
        guard time <= receivedAt.addingTimeInterval(5), time >= (latestUpdate ?? .distantPast) else { return }
        if stationary {
            departureAnchor = nil
            if let route, !route.isFinished {
                try close(route, at: location, rejoinAfter: time)
            }
            latestUpdate = time
            return
        }
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate),
              (0...LocationSampling(mode: .unknown).maximumAccuracy).contains(location.horizontalAccuracy),
              time > (latestUpdate ?? .distantPast) else { return }
        if let previous = latestUpdate, time.timeIntervalSince(previous) >= Self.shortStop,
           let route, !route.isFinished {
            // Save the interruption provisionally. Radio silence alone cannot establish arrival.
            try close(route, at: nil, rejoinAfter: previous, observedRest: false)
        }
        latestUpdate = time
        if let route, !route.isFinished {
            if let lastFix, time.timeIntervalSince(lastFix.timestamp) > LocationSampling.maximumGap {
                approach = ArrivalMotion()
                dwellAnchor = nil
                observedArrival = false
                speed = SpeedModeEstimate()
                mode = .unknown
            }
            let sampleMode = travelMode(for: location)
            if observedArrival, sampleMode != .stationary, let lastFix {
                let distance = location.distance(from: lastFix)
                let elapsed = time.timeIntervalSince(lastFix.timestamp)
                guard elapsed > 0, distance / elapsed <= LocationSampling.speedLimit,
                      distance >= max(25, lastFix.horizontalAccuracy + location.horizontalAccuracy) else { return }
                // The full observed dwell belongs to the arriving route. Start the next
                // recording at its last fix without drawing across an observation gap.
                if supportsDeparture(from: lastFix, to: location) {
                    try close(route, at: nil, rejoinAfter: nil)
                    departureAnchor = lastFix
                } else {
                    observedArrival = false
                    dwellAnchor = nil
                    if append(location, mode: sampleMode, to: route) { try save() }
                    return
                }
            } else {
                if sampleMode == .stationary, approach.supportsVisit {
                    if let anchor = dwellAnchor, location.distance(from: anchor) <= max(25, location.horizontalAccuracy) {
                        if time.timeIntervalSince(anchor.timestamp) >= Self.shortStop { observedArrival = true }
                    } else if !observedArrival { dwellAnchor = location }
                } else if !observedArrival { dwellAnchor = nil }
                if append(location, mode: sampleMode, to: route) { try save() }
                return
            }
        }

        guard let anchor = departureAnchor, time.timeIntervalSince(anchor.timestamp) <= LocationSampling.maximumGap else {
            departureAnchor = location
            return
        }
        let meters = location.distance(from: anchor)
        let duration = time.timeIntervalSince(anchor.timestamp)
        guard duration > 0, meters / duration <= LocationSampling.speedLimit,
              meters >= max(25, anchor.horizontalAccuracy + location.horizontalAccuracy) else { return }

        let trip: RecordedRoute
        if let recent = route, let stopped = recent.automaticPauseAt,
           anchor.timestamp.timeIntervalSince(stopped) <= ArrivalMotion.maximumResumption,
           ((!observedArrival && anchor.timestamp.timeIntervalSince(stopped) < Self.shortStop) || !supportsDeparture(from: anchor, to: location)),
           let lastFix, anchor.distance(from: lastFix) <= ArrivalMotion.resumptionRadius {
            trip = recent
        } else {
            var query = FetchDescriptor<RecordedRoute>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
            query.fetchLimit = 1
            let previous = try context.fetch(query).first
            approach = ArrivalMotion()
            trip = RecordedRoute(startedAt: anchor.timestamp)
            trip.automaticSessionStart = sessionStart
            if let sessionStart, previous?.automaticSessionStart == sessionStart, previous?.endedAtRest == true {
                trip.previousAutomaticRouteID = previous?.id
            }
            trip.isAutomatic = true
            context.insert(trip)
        }
        route = trip
        dwellAnchor = nil
        observedArrival = false
        trip.endedAtRest = nil
        trip.isFinished = false
        trip.automaticPauseAt = nil
        lastFix = nil
        speed = SpeedModeEstimate()
        mode = .unknown
        departureAnchor = nil
        append(anchor, mode: travelMode(for: anchor), to: trip)
        append(location, mode: travelMode(for: location), to: trip)
        try save()
    }

    private func close(_ route: RecordedRoute, at location: CLLocation?, rejoinAfter pause: Date?, observedRest: Bool = true) throws {
        if let location { append(location, mode: .stationary, to: route) }
        route.isFinished = true
        let eventTime = pause ?? location?.timestamp ?? lastFix?.timestamp
        route.endedAtRest = observedRest && eventTime.flatMap { time in
            lastFix.map { (0...LocationSampling.maximumGap).contains(time.timeIntervalSince($0.timestamp)) }
        } == true
        route.automaticPauseAt = pause
        try save()
    }

    func end() throws {
        if let route, !route.isFinished || route.automaticPauseAt != nil {
            route.isFinished = true
            route.automaticPauseAt = nil
            try save()
        }
        forget()
    }

    func forget() {
        route = nil
        lastFix = nil
        latestUpdate = nil
        departureAnchor = nil
        dwellAnchor = nil
        observedArrival = false
        approach = ArrivalMotion()
        speed = SpeedModeEstimate()
        mode = .unknown
    }

    private func supportsDeparture(from stop: CLLocation, to fix: CLLocation) -> Bool {
        guard approach.supportsVisit else { return false }
        if !approach.includesDriving { return true }
        if let activity = motionActivity, activity.since <= fix.timestamp {
            if activity.mode == .walking || activity.mode == .cycling { return true }
            if activity.mode == .automotive { return false }
        }
        if fix.speed >= 7.5, (0...3).contains(fix.speedAccuracy) { return false }
        return ArrivalMotion.returnsTowards(approach.walkOrigin, from: stop, to: fix)
    }

    private func travelMode(for fix: CLLocation) -> TravelMode {
        if let estimate = speed.observe(fix, currentMode: mode) { mode = estimate }
        guard let activity = motionActivity, activity.since <= fix.timestamp else { return mode }
        switch activity.mode {
        case .automotive: return .automotive
        case .walking, .cycling:
            if mode == .stationary, (0..<0.7).contains(fix.speed) { return .stationary }
            return activity.mode
        case .stationary:
            return fix.speed < 0.7 ? .stationary : mode
        case .unknown: return mode
        }
    }

    @discardableResult
    private func append(_ fix: CLLocation, mode: TravelMode, to route: RecordedRoute) -> Bool {
        guard let step = LocationSampling(mode: mode).assess(fix, after: lastFix, mode: mode, previousMode: lastMode)
        else { return false }
        let point = RoutePoint(location: fix, mode: mode, startsNewSegment: step.startsNewSegment,
                               startsRecordingRun: lastFix == nil, route: route)
        context.insert(point)
        route.pointCount += 1
        route.distanceMeters += step.distance
        if lastFix.map({ fix.timestamp.timeIntervalSince($0.timestamp) > LocationSampling.maximumGap }) ?? true {
            approach = ArrivalMotion()
        }
        approach.observe(mode, at: fix)
        lastFix = fix
        lastMode = mode
        return true
    }

    private func save() throws {
        do { try context.save() }
        catch {
            context.rollback()
            forget()
            throw error
        }
    }
}
