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
    private var lastFix: CLLocation?
    private var lastMode = TravelMode.unknown
    private var dwellAnchor: CLLocation?
    private var departureAnchor: CLLocation?
    private var latestUpdate: Date?
    private var speed = SpeedModeEstimate()
    private var mode = TravelMode.unknown

    init(context: ModelContext) { self.context = context }

    func restore(now: Date) throws {
        var query = FetchDescriptor<RecordedRoute>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        query.fetchLimit = 1
        guard let saved = try context.fetch(query).first, saved.isAutomatic == true,
              !saved.isFinished || saved.automaticPauseAt.map({ now.timeIntervalSince($0) < Self.shortStop }) == true
        else { return }
        route = saved
        let id = saved.id
        var points = FetchDescriptor<RoutePoint>(predicate: #Predicate { $0.route?.id == id },
                                                  sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        points.fetchLimit = 1
        if let point = try context.fetch(points).first {
            lastFix = CLLocation(coordinate: point.coordinate, altitude: 0, horizontalAccuracy: point.accuracy,
                                 verticalAccuracy: -1, timestamp: point.timestamp)
            lastMode = point.mode
            let lastEvent = max(point.timestamp, saved.automaticPauseAt ?? .distantPast)
            latestUpdate = lastEvent
            if now.timeIntervalSince(lastEvent) >= Self.shortStop { try end() }
        }
    }

    func receive(_ location: CLLocation?, stationary: Bool, receivedAt: Date) throws {
        // A pause can close the trip even when its coordinate fails the sampling checks.
        let time = location?.timestamp ?? receivedAt
        guard time <= receivedAt.addingTimeInterval(5), time >= (latestUpdate ?? .distantPast) else { return }
        if stationary {
            departureAnchor = nil
            dwellAnchor = nil
            if let route, !route.isFinished {
                try close(route, at: location, rejoinAfter: time)
            }
            latestUpdate = time
            return
        }
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate),
              (0...LocationSampling(mode: .unknown).maximumAccuracy).contains(location.horizontalAccuracy),
              time > (latestUpdate ?? .distantPast) else { return }
        if let previous = latestUpdate, time.timeIntervalSince(previous) >= Self.shortStop { try end() }
        latestUpdate = time
        if let route, !route.isFinished {
            // Some devices keep delivering fixes after arrival instead of sending a system pause.
            if let dwellAnchor, location.distance(from: dwellAnchor) <= max(25, location.horizontalAccuracy),
               location.speed < 0.7 || location.speedAccuracy < 0 {
                if time.timeIntervalSince(dwellAnchor.timestamp) >= Self.shortStop {
                    try close(route, at: location, rejoinAfter: nil)
                    forget()
                    latestUpdate = time
                    return
                }
            } else {
                dwellAnchor = location
            }
            if append(location, mode: travelMode(for: location), to: route) { try save() }
            return
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
           anchor.timestamp.timeIntervalSince(stopped) < Self.shortStop,
           let lastFix, anchor.distance(from: lastFix) <= 100 {
            trip = recent
        } else {
            trip = RecordedRoute(startedAt: anchor.timestamp)
            trip.isAutomatic = true
            context.insert(trip)
        }
        route = trip
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

    private func close(_ route: RecordedRoute, at location: CLLocation?, rejoinAfter pause: Date?) throws {
        if let location { append(location, mode: .stationary, to: route) }
        route.isFinished = true
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
        speed = SpeedModeEstimate()
        mode = .unknown
    }

    private func travelMode(for fix: CLLocation) -> TravelMode {
        if let estimate = speed.observe(fix, currentMode: mode) { mode = estimate }
        return mode
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
