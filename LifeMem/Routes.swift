import CoreLocation
import Foundation
import Observation
import SwiftData

@Model
final class RecordedRoute {
    var id: UUID
    var startedAt: Date
    var isFinished: Bool
    var pointCount: Int
    var distanceMeters: Double

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.route)
    var points: [RoutePoint]

    init(startedAt: Date) {
        id = UUID()
        self.startedAt = startedAt
        isFinished = false
        pointCount = 0
        distanceMeters = 0
        points = []
    }
}

struct RouteActivitySegment: Identifiable {
    let id: PersistentIdentifier
    let mode: TravelMode
    let startedAt: Date
    var endedAt: Date
    let startCoordinate: CLLocationCoordinate2D
    var coordinates: [CLLocationCoordinate2D]

    static func group(sortedPoints: [RoutePoint]) -> [Self] {
        var segments: [RouteActivitySegment] = []
        var previousPoint: RoutePoint?
        for point in sortedPoints {
            let mode = point.mode
            if let previousPoint, previousPoint.mode == mode, !point.startsNewSegment {
                let index = segments.count - 1
                segments[index].endedAt = point.timestamp
                if mode != .stationary { segments[index].coordinates.append(point.coordinate) }
            } else {
                // Keep the map line continuous across a change in travel mode.
                var coordinates: [CLLocationCoordinate2D] = []
                if let previousPoint, !point.startsNewSegment, mode != .stationary, previousPoint.mode != .stationary {
                    coordinates.append(previousPoint.coordinate)
                }
                coordinates.append(point.coordinate)
                segments.append(RouteActivitySegment(
                    id: point.persistentModelID,
                    mode: mode,
                    startedAt: point.timestamp,
                    endedAt: point.timestamp,
                    startCoordinate: point.coordinate,
                    coordinates: coordinates
                ))
            }
            previousPoint = point
        }
        return segments
    }
}

struct RouteReviewEntry: Identifiable {
    enum Kind { case trip, visit, fragment }

    struct Endpoints {
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
    }

    var id: PersistentIdentifier { segments[0].id }
    var startedAt: Date { segments[0].startedAt }
    var endedAt: Date { segments[segments.count - 1].endedAt }

    let kind: Kind
    let followsGap: Bool
    let segments: [RouteActivitySegment]
    let endpoints: Endpoints?
    let visitCoordinate: CLLocationCoordinate2D?
}

struct RouteReviewDay: Identifiable {
    var id: Date { date }

    let date: Date
    let entries: [RouteReviewEntry]
}

struct RouteVisit: Identifiable {
    let id: PersistentIdentifier
    let date: Date
    let startedAt: Date
    let coordinate: CLLocationCoordinate2D
}

struct RoutePlace: Identifiable {
    var id: RouteVisit.ID { visits[0].id }
    var coordinate: CLLocationCoordinate2D { visits[0].coordinate }
    var mostRecentVisit: RouteVisit { visits[visits.count - 1] }

    private(set) var visits: [RouteVisit]

    fileprivate static func group(_ visits: [RouteVisit], within radius: CLLocationDistance) -> [RoutePlace] {
        var places: [RoutePlace] = []
        for visit in visits.sorted(by: { $0.startedAt < $1.startedAt }) {
            let location = visit.coordinate.location
            let nearest = places.indices.lazy
                .map { (index: $0, distance: places[$0].coordinate.location.distance(from: location)) }
                .min { $0.distance < $1.distance }
            if let nearest, nearest.distance <= radius {
                places[nearest.index].visits.append(visit)
            } else {
                places.append(RoutePlace(visits: [visit]))
            }
        }
        return places.sorted { $0.mostRecentVisit.startedAt > $1.mostRecentVisit.startedAt }
    }
}

struct RouteReview {
    private static let minimumVisitDuration: TimeInterval = 5 * 60
    static let placeRadius: CLLocationDistance = 100

    let days: [RouteReviewDay]
    let places: [RoutePlace]

    init(routes: [RecordedRoute], calendar: Calendar) {
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        var visits: [RouteVisit] = []
        for route in routes {
            let points = route.points.sorted { $0.timestamp < $1.timestamp }
            for (index, run) in Self.continuousRuns(points).enumerated() {
                let slices = Self.timelineSlices(run)
                for (sliceIndex, slice) in slices.enumerated() {
                    let first = slice.points[slice.points.startIndex]
                    let firstDay = calendar.startOfDay(for: first.timestamp)
                    let lastDay = calendar.startOfDay(for: slice.points[slice.points.endIndex - 1].timestamp)
                    let pointsByDay = Dictionary(grouping: slice.points) { calendar.startOfDay(for: $0.timestamp) }
                    if let visit = slice.visitCoordinate {
                        visits.append(RouteVisit(id: first.persistentModelID, date: firstDay, startedAt: first.timestamp, coordinate: visit))
                    }
                    for (day, points) in pointsByDay {
                        let segments = RouteActivitySegment.group(sortedPoints: points)
                        let hasMovement = segments.contains { $0.mode != .stationary && $0.coordinates.count > 1 }
                        let kind: RouteReviewEntry.Kind = slice.visitCoordinate != nil ? .visit : (hasMovement ? .trip : .fragment)
                        let followsGap = index > 0 && slice.points.startIndex == run.startIndex && day == firstDay
                        let previousVisit = day == firstDay && sliceIndex > 0 ? slices[sliceIndex - 1].visitCoordinate : nil
                        let nextVisit = day == lastDay && sliceIndex + 1 < slices.count ? slices[sliceIndex + 1].visitCoordinate : nil
                        let endpoints = kind == .trip ? Self.endpoints(in: segments, previousVisit: previousVisit, nextVisit: nextVisit) : nil
                        entriesByDay[day, default: []].append(RouteReviewEntry(
                            kind: kind,
                            followsGap: followsGap,
                            segments: segments,
                            endpoints: endpoints,
                            visitCoordinate: slice.visitCoordinate
                        ))
                    }
                }
            }
        }
        days = entriesByDay.keys.sorted(by: >).map { date in
            RouteReviewDay(date: date, entries: entriesByDay[date, default: []].sorted { $0.startedAt < $1.startedAt })
        }
        places = RoutePlace.group(visits, within: Self.placeRadius)
    }

    private static func continuousRuns(_ points: [RoutePoint]) -> [ArraySlice<RoutePoint>] {
        guard !points.isEmpty else { return [] }
        var runs: [ArraySlice<RoutePoint>] = []
        var start = points.startIndex
        for index in points.indices.dropFirst() {
            let point = points[index]
            let previous = points[index - 1]
            let changesStationary = (point.mode == .stationary) != (previous.mode == .stationary)
            // A stationary transition also starts a drawing segment. By itself it does not indicate a recording gap.
            if point.timestamp.timeIntervalSince(previous.timestamp) > LocationSampling.maximumGap ||
                (point.startsNewSegment && !changesStationary) {
                runs.append(points[start..<index])
                start = index
            }
        }
        runs.append(points[start...])
        return runs
    }

    private struct TimelineSlice {
        let points: ArraySlice<RoutePoint>
        var visitCoordinate: CLLocationCoordinate2D?
    }

    private static func timelineSlices(_ run: ArraySlice<RoutePoint>) -> [TimelineSlice] {
        var slices: [TimelineSlice] = []
        var start = run.startIndex
        var index = start
        while let stationaryStart = run[index...].firstIndex(where: { $0.mode == .stationary }) {
            let end = run[stationaryStart...].firstIndex { $0.mode != .stationary } ?? run.endIndex
            let stationary = run[stationaryStart..<end]
            let first = run[stationaryStart]
            if run[end - 1].timestamp.timeIntervalSince(first.timestamp) >= minimumVisitDuration {
                let anchor = first.coordinate.location
                if stationary.allSatisfy({ $0.coordinate.location.distance(from: anchor) <= placeRadius }) {
                    if start < stationaryStart { slices.append(TimelineSlice(points: run[start..<stationaryStart])) }
                    slices.append(TimelineSlice(points: stationary, visitCoordinate: first.coordinate))
                    start = end
                }
            }
            index = end
        }
        if start < run.endIndex { slices.append(TimelineSlice(points: run[start...])) }
        return slices
    }

    private static func endpoints(
        in segments: [RouteActivitySegment],
        previousVisit: CLLocationCoordinate2D?,
        nextVisit: CLLocationCoordinate2D?
    ) -> RouteReviewEntry.Endpoints? {
        let movement = segments.filter { $0.mode != .stationary }
        guard let start = movement.first?.startCoordinate, let end = movement.last?.coordinates.last else { return nil }
        return RouteReviewEntry.Endpoints(start: place(near: start, visit: previousVisit), end: place(near: end, visit: nextVisit))
    }

    private static func place(near endpoint: CLLocationCoordinate2D, visit: CLLocationCoordinate2D?) -> CLLocationCoordinate2D {
        guard let visit, endpoint.location.distance(from: visit.location) <= placeRadius else { return endpoint }
        return visit
    }
}

@MainActor
@Observable
final class RoutePlaceNames {
    private struct SavedName: Codable {
        var name: String
        let latitude: Double
        let longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    private let file: URL
    private var names: [SavedName] = []
    private let loadError: Error?

    init(file: URL) {
        self.file = file
        do {
            names = try JSONDecoder().decode([SavedName].self, from: Data(contentsOf: file))
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loadError = nil
        } catch {
            loadError = error
        }
    }

    func name(for coordinate: CLLocationCoordinate2D) -> String? {
        matchingIndex(for: coordinate).map { names[$0].name }
    }

    func save(_ name: String?, for coordinate: CLLocationCoordinate2D) throws {
        if let loadError { throw loadError }
        var updated = names
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = matchingIndex(for: coordinate) {
            if trimmed.isEmpty {
                updated.remove(at: index)
            } else {
                updated[index].name = trimmed
            }
        } else if !trimmed.isEmpty {
            updated.append(SavedName(name: trimmed, latitude: coordinate.latitude, longitude: coordinate.longitude))
        } else {
            return
        }
        let data = try JSONEncoder().encode(updated)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        names = updated
    }

    private func matchingIndex(for coordinate: CLLocationCoordinate2D) -> Int? {
        let location = coordinate.location
        let nearest = names.indices.lazy
            .map { (index: $0, distance: self.names[$0].location.distance(from: location)) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= RouteReview.placeRadius else { return nil }
        return nearest.index
    }
}

private extension CLLocationCoordinate2D {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

@Model
final class RoutePoint {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var travelMode: String
    var startsNewSegment: Bool
    var route: RecordedRoute?

    init(location: CLLocation, mode: TravelMode, startsNewSegment: Bool, route: RecordedRoute) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        travelMode = mode.rawValue
        self.startsNewSegment = startsNewSegment
        self.route = route
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mode: TravelMode { TravelMode(rawValue: travelMode) ?? .unknown }
}

enum TravelMode: String, CaseIterable {
    case unknown, walking, automotive, cycling, stationary

    var title: String {
        switch self {
        case .unknown: "识别中"
        case .walking: "步行"
        case .automotive: "乘车"
        case .cycling: "骑行"
        case .stationary: "静止"
        }
    }

    var recordedTitle: String {
        switch self {
        case .unknown: "未分类"
        case .stationary: "停留"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "location"
        case .walking: "figure.walk"
        case .automotive: "car"
        case .cycling: "bicycle"
        case .stationary: "pause.circle"
        }
    }
}

struct LocationSampling {
    static let maximumGap: TimeInterval = 90

    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    let maximumAccuracy: CLLocationAccuracy
    let maximumTravelSpeed: CLLocationSpeed

    init(mode: TravelMode) {
        switch mode {
        case .walking:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 8
            maximumAccuracy = 35
            maximumTravelSpeed = 12
        case .automotive:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 30
            maximumAccuracy = 55
            maximumTravelSpeed = 80
        case .cycling:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 15
            maximumAccuracy = 40
            maximumTravelSpeed = 30
        case .stationary:
            desiredAccuracy = kCLLocationAccuracyHundredMeters
            distanceFilter = kCLDistanceFilterNone
            maximumAccuracy = 50
            maximumTravelSpeed = 80
        case .unknown:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 10
            maximumAccuracy = 45
            maximumTravelSpeed = 80
        }
    }

    func assess(_ location: CLLocation, after previous: CLLocation?, mode: TravelMode, previousMode: TravelMode? = nil) -> RouteStep? {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              (0...maximumAccuracy).contains(location.horizontalAccuracy) else { return nil }
        guard let previous else { return .newSegment }
        let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
        guard seconds > 0 else { return nil }
        if seconds > Self.maximumGap { return .newSegment }
        if mode == .stationary {
            if previousMode != .stationary { return .newSegment }
            return seconds >= 30 ? .continuation(distance: 0) : nil
        }
        if previousMode == .stationary { return .newSegment }
        let meters = location.distance(from: previous)
        let noiseAllowance = (location.horizontalAccuracy + previous.horizontalAccuracy) * 0.35
        guard meters >= max(distanceFilter, noiseAllowance),
              meters / seconds <= maximumTravelSpeed else { return nil }
        return .continuation(distance: meters)
    }
}

enum RouteStep {
    case newSegment
    case continuation(distance: CLLocationDistance)

    var distance: CLLocationDistance {
        switch self {
        case .newSegment: 0
        case let .continuation(distance): distance
        }
    }

    var startsNewSegment: Bool {
        if case .newSegment = self { return true }
        return false
    }
}
