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
    var mode: TravelMode
    let startedAt: Date
    let movementStartedAt: Date
    var endedAt: Date
    let startCoordinate: CLLocationCoordinate2D
    var coordinates: [CLLocationCoordinate2D]
    var distanceMeters: CLLocationDistance

    static func group(
        sortedPoints: [RoutePoint],
        inferModes: Bool = false,
        leadingStayPoint: RoutePoint? = nil,
        trailingStayPoint: RoutePoint? = nil
    ) -> [Self] {
        var segments: [RouteActivitySegment] = []
        var previousPoint = leadingStayPoint
        var previousMode: TravelMode?
        for point in sortedPoints {
            let distance = previousPoint.map { measuredDistance(from: $0, to: point) } ?? 0
            let startsDrawingSegment = point.startsNewSegment && (leadingStayPoint == nil || !segments.isEmpty)
            let mode: TravelMode
            if inferModes, point.mode == .unknown, distance > 0, let previousPoint, !startsDrawingSegment {
                mode = TravelMode.estimated(metersPerSecond: distance / point.timestamp.timeIntervalSince(previousPoint.timestamp))
            } else {
                mode = point.mode
            }
            let bridgesPrevious = !startsDrawingSegment && mode != .stationary && previousMode != .stationary &&
                (!segments.isEmpty || distance > 0)
            if previousMode == mode, !startsDrawingSegment {
                let index = segments.count - 1
                segments[index].endedAt = point.timestamp
                if mode != .stationary {
                    segments[index].coordinates.append(point.coordinate)
                    segments[index].distanceMeters += distance
                }
            } else {
                // Keep the map line continuous across a change in travel mode.
                var coordinates: [CLLocationCoordinate2D] = []
                if let previousPoint, bridgesPrevious {
                    coordinates.append(previousPoint.coordinate)
                }
                coordinates.append(point.coordinate)
                segments.append(RouteActivitySegment(
                    id: point.persistentModelID,
                    mode: mode,
                    startedAt: point.timestamp,
                    movementStartedAt: bridgesPrevious ? previousPoint?.timestamp ?? point.timestamp : point.timestamp,
                    endedAt: point.timestamp,
                    startCoordinate: point.coordinate,
                    coordinates: coordinates,
                    distanceMeters: bridgesPrevious ? distance : 0
                ))
            }
            previousPoint = point
            previousMode = mode
        }
        if let trailingStayPoint, let previousPoint, let last = segments.indices.last, segments[last].mode != .stationary {
            let distance = measuredDistance(from: previousPoint, to: trailingStayPoint)
            if distance > 0 {
                if inferModes, segments[last].mode == .unknown {
                    let seconds = trailingStayPoint.timestamp.timeIntervalSince(previousPoint.timestamp)
                    segments[last].mode = TravelMode.estimated(metersPerSecond: distance / seconds)
                }
                segments[last].endedAt = trailingStayPoint.timestamp
                segments[last].coordinates.append(trailingStayPoint.coordinate)
                segments[last].distanceMeters += distance
            }
        }
        return segments
    }

    fileprivate static func measuredDistance(from first: RoutePoint, to second: RoutePoint) -> CLLocationDistance {
        let meters = first.coordinate.location.distance(from: second.coordinate.location)
        let noise = (first.accuracy + second.accuracy) * 0.35
        return meters >= noise ? meters : 0
    }
}

struct RouteReviewEntry: Identifiable {
    enum Kind { case trip, visit, fragment }

    struct Endpoints {
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
    }

    var id: PersistentIdentifier { segments[0].id }
    var startedAt: Date { stay?.startedAt ?? segments[0].movementStartedAt }
    var endedAt: Date { stay?.endedAt ?? segments[segments.count - 1].endedAt }

    let kind: Kind
    let followsGap: Bool
    let segments: [RouteActivitySegment]
    let endpoints: Endpoints?
    let stay: StayEvent?

    var visitCoordinate: CLLocationCoordinate2D? { stay?.coordinate }

    var timeline: [TimelineSegment] {
        if let stay { return [.stay(stay)] }
        return moves.map(TimelineSegment.move)
    }
    var moves: [MoveEvent] {
        guard stay == nil else { return [] }
        return segments.filter { $0.distanceMeters > 0 }.map(MoveEvent.init)
    }

}

struct RouteReviewDay: Identifiable {
    struct Movement {
        var duration: TimeInterval = 0
        var distance: CLLocationDistance = 0
    }

    var id: Date { date }

    let date: Date
    let entries: [RouteReviewEntry]
    private(set) var midnightMovement = Movement()

    var timeline: [TimelineSegment] { entries.flatMap(\.timeline) }
    var stays: [StayEvent] { entries.compactMap(\.stay) }
    var moves: [MoveEvent] { entries.flatMap(\.moves) }
    var movingDistanceMeters: CLLocationDistance { moves.reduce(midnightMovement.distance) { $0 + $1.distanceMeters } }
    var movingDuration: TimeInterval { moves.reduce(midnightMovement.duration) { $0 + $1.duration } }
}

enum TimelineSegment: Identifiable {
    case stay(StayEvent)
    case move(MoveEvent)

    var id: PersistentIdentifier {
        switch self {
        case let .stay(event): event.id
        case let .move(event): event.id
        }
    }
}

struct StayEvent: Identifiable {
    let id: PersistentIdentifier
    let visitID: PersistentIdentifier
    let coordinate: CLLocationCoordinate2D
    let startedAt: Date
    let endedAt: Date

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

struct MoveEvent: Identifiable {
    let activity: RouteActivitySegment

    var id: PersistentIdentifier { activity.id }
    var startedAt: Date { activity.movementStartedAt }
    var endedAt: Date { activity.endedAt }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var distanceMeters: CLLocationDistance { activity.distanceMeters }
    var averageKilometersPerHour: Double { duration > 0 ? distanceMeters / duration * 3.6 : 0 }
    var mode: TravelMode { activity.mode }
    var coordinates: [CLLocationCoordinate2D] { activity.coordinates }
}

struct RouteJourney: Identifiable {
    struct StayConnection {
        let coordinate: CLLocationCoordinate2D
        let time: Date
    }

    let id: PersistentIdentifier
    let endpoints: RouteReviewEntry.Endpoints
    let departedAt: Date
    let duration: TimeInterval
    let mode: TravelMode
    let departureStay: StayConnection?
    let arrivalStay: StayConnection?
}

struct RouteVisit: Identifiable {
    let id: PersistentIdentifier
    let date: Date
    let startedAt: Date
    let endedAt: Date
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

struct RouteReviewRevision: Hashable {
    private struct RouteVersion: Hashable {
        let id: UUID
        let pointCount: Int
    }

    let calendar: Calendar
    private let routes: [RouteVersion]

    init(calendar: Calendar, routes: [RecordedRoute]) {
        self.calendar = calendar
        self.routes = routes.map { RouteVersion(id: $0.id, pointCount: $0.pointCount) }
    }
}

struct RouteReview {
    private static let minimumVisitDuration: TimeInterval = 8 * 60
    private static let stayRadius: CLLocationDistance = 60
    static let placeRadius: CLLocationDistance = 100

    let days: [RouteReviewDay]
    let places: [RoutePlace]
    let journeys: [RouteJourney]

    init(routes: [RecordedRoute], calendar: Calendar) {
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        var midnightMovement: [Date: RouteReviewDay.Movement] = [:]
        var visits: [RouteVisit] = []
        var journeys: [RouteJourney] = []
        for route in routes {
            let points = route.points.sorted { $0.timestamp < $1.timestamp }
            for (index, run) in Self.cleanRuns(points).enumerated() {
                let slices = Self.timelineSlices(run)
                for (sliceIndex, slice) in slices.enumerated() {
                    let first = slice.points[slice.points.startIndex]
                    let firstDay = calendar.startOfDay(for: first.timestamp)
                    let lastDay = calendar.startOfDay(for: slice.points[slice.points.endIndex - 1].timestamp)
                    let pointsByDay = Dictionary(grouping: slice.points) { calendar.startOfDay(for: $0.timestamp) }
                    let last = slice.points[slice.points.endIndex - 1]
                    let previousSlice = sliceIndex > 0 ? slices[sliceIndex - 1] : nil
                    let nextSlice = sliceIndex + 1 < slices.count ? slices[sliceIndex + 1] : nil
                    let previousCoordinate = previousSlice?.visitCoordinate
                    let nextCoordinate = nextSlice?.visitCoordinate
                    let leading = slice.visitCoordinate == nil && previousCoordinate != nil ? previousSlice?.points.last : nil
                    let trailing = slice.visitCoordinate == nil && nextCoordinate != nil ? nextSlice?.points.first : nil
                    if let visit = slice.visitCoordinate {
                        visits.append(RouteVisit(id: first.persistentModelID, date: firstDay, startedAt: first.timestamp, endedAt: last.timestamp, coordinate: visit))
                    } else {
                        if firstDay != lastDay {
                            for (from, to) in zip(slice.points, slice.points.dropFirst())
                                where from.mode != .stationary && to.mode != .stationary && !to.startsNewSegment {
                                Self.allocateMidnightEdge(from: from, to: to, calendar: calendar, totals: &midnightMovement)
                            }
                        }
                        if let from = leading, first.mode != .stationary {
                            Self.allocateMidnightEdge(from: from, to: first, calendar: calendar, totals: &midnightMovement)
                        }
                        if let to = trailing, last.mode != .stationary {
                            Self.allocateMidnightEdge(from: last, to: to, calendar: calendar, totals: &midnightMovement)
                        }
                    }
                    var completeSegments: [RouteActivitySegment]?
                    for (day, points) in pointsByDay {
                        let followsGap = index > 0 && slice.points.startIndex == run.startIndex && day == firstDay
                        let previousVisit = day == firstDay ? previousCoordinate : nil
                        let nextVisit = day == lastDay ? nextCoordinate : nil
                        let sameDayLeading = leading.flatMap { calendar.isDate($0.timestamp, inSameDayAs: day) ? $0 : nil }
                        let sameDayTrailing = trailing.flatMap { calendar.isDate($0.timestamp, inSameDayAs: day) ? $0 : nil }
                        let segments = RouteActivitySegment.group(
                            sortedPoints: points,
                            inferModes: slice.visitCoordinate == nil,
                            leadingStayPoint: sameDayLeading,
                            trailingStayPoint: sameDayTrailing
                        )
                        if slice.visitCoordinate == nil, firstDay == lastDay, leading?.timestamp == sameDayLeading?.timestamp,
                           trailing?.timestamp == sameDayTrailing?.timestamp {
                            completeSegments = segments
                        }
                        let hasMovement = segments.contains { $0.distanceMeters > 0 }
                        let kind: RouteReviewEntry.Kind = slice.visitCoordinate != nil ? .visit : (hasMovement ? .trip : .fragment)
                        let endpoints = kind == .trip ? Self.endpoints(in: segments, previousVisit: previousVisit, nextVisit: nextVisit) : nil
                        let stay = slice.visitCoordinate.map { coordinate in
                            let dayEnd = calendar.dateInterval(of: .day, for: day)?.end ?? last.timestamp
                            return StayEvent(
                                id: segments[0].id,
                                visitID: first.persistentModelID,
                                coordinate: coordinate,
                                startedAt: max(day, first.timestamp),
                                endedAt: min(dayEnd, last.timestamp)
                            )
                        }
                        entriesByDay[day, default: []].append(RouteReviewEntry(
                            kind: kind,
                            followsGap: followsGap,
                            segments: segments,
                            endpoints: endpoints,
                            stay: stay
                        ))
                    }

                    if slice.visitCoordinate == nil {
                        let segments = completeSegments ?? RouteActivitySegment.group(
                            sortedPoints: Array(slice.points), inferModes: true,
                            leadingStayPoint: leading, trailingStayPoint: trailing
                        )
                        let arrival = trailing.flatMap { point in
                            nextCoordinate.map { RouteJourney.StayConnection(coordinate: $0, time: point.timestamp) }
                        }
                        if let journey = Self.journey(in: segments, departure: previousCoordinate, arrival: arrival) {
                            journeys.append(journey)
                        }
                    }
                }
            }
        }
        days = entriesByDay.keys.sorted(by: >).map { date in
            RouteReviewDay(
                date: date,
                entries: entriesByDay[date, default: []].sorted { $0.startedAt < $1.startedAt },
                midnightMovement: midnightMovement[date, default: .init()]
            )
        }
        places = RoutePlace.group(visits, within: Self.placeRadius)
        self.journeys = journeys
    }

    private static func journey(
        in segments: [RouteActivitySegment],
        departure: CLLocationCoordinate2D?,
        arrival: RouteJourney.StayConnection?
    ) -> RouteJourney? {
        let moving = segments.filter { $0.distanceMeters > 0 }
        guard let first = moving.first, let last = moving.last,
              let endpoints = endpoints(in: moving, previousVisit: departure, nextVisit: arrival?.coordinate) else { return nil }
        let seconds = last.endedAt.timeIntervalSince(first.movementStartedAt)
        guard seconds > 0 else { return nil }
        let durations = moving.reduce(into: [TravelMode: TimeInterval]()) {
            $0[$1.mode, default: 0] += $1.endedAt.timeIntervalSince($1.movementStartedAt)
        }
        let mode = TravelMode.allCases.max { durations[$0, default: 0] < durations[$1, default: 0] } ?? .unknown
        return RouteJourney(
            id: first.id, endpoints: endpoints, departedAt: first.startedAt, duration: seconds, mode: mode,
            departureStay: departure.map { RouteJourney.StayConnection(coordinate: $0, time: first.startedAt) },
            arrivalStay: arrival
        )
    }

    private static func allocateMidnightEdge(
        from first: RoutePoint,
        to second: RoutePoint,
        calendar: Calendar,
        totals: inout [Date: RouteReviewDay.Movement]
    ) {
        let startDay = calendar.startOfDay(for: first.timestamp)
        let endDay = calendar.startOfDay(for: second.timestamp)
        guard startDay != endDay else { return }
        let distance = RouteActivitySegment.measuredDistance(from: first, to: second)
        guard distance > 0 else { return }
        let seconds = second.timestamp.timeIntervalSince(first.timestamp)
        let before = endDay.timeIntervalSince(first.timestamp)
        totals[startDay, default: .init()].duration += before
        totals[startDay, default: .init()].distance += distance * before / seconds
        totals[endDay, default: .init()].duration += seconds - before
        totals[endDay, default: .init()].distance += distance * (seconds - before) / seconds
    }

    private static func cleanRuns(_ points: [RoutePoint]) -> [[RoutePoint]] {
        var runs: [[RoutePoint]] = []
        var run: [RoutePoint] = []
        var previousObserved: RoutePoint?
        for point in points {
            if let previousObserved {
                let changesStationary = (point.mode == .stationary) != (previousObserved.mode == .stationary)
                // Early versions also used the drawing flag for changes to and from stationary.
                let boundary = point.startsRecordingRun ?? (point.startsNewSegment && !changesStationary)
                if boundary, !run.isEmpty {
                    runs.append(run)
                    run = []
                }
            }
            previousObserved = point
            guard CLLocationCoordinate2DIsValid(point.coordinate),
                  (0...LocationSampling.accuracyLimit).contains(point.accuracy) else { continue }
            if let previous = run.last {
                let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
                guard seconds > 0 else { continue }
                if seconds > LocationSampling.maximumGap {
                    runs.append(run)
                    run = []
                } else if point.coordinate.location.distance(from: previous.coordinate.location) / seconds > LocationSampling.speedLimit {
                    continue
                }
            }
            run.append(point)
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    private struct TimelineSlice {
        let points: ArraySlice<RoutePoint>
        var visitCoordinate: CLLocationCoordinate2D?
    }

    private static func timelineSlices(_ run: [RoutePoint]) -> [TimelineSlice] {
        var slices: [TimelineSlice] = []
        var start = run.startIndex
        var candidate = start
        while candidate < run.endIndex {
            let first = run[candidate]
            guard isStayCandidate(first) else {
                candidate += 1
                continue
            }
            let anchor = first.coordinate.location
            var end = candidate + 1
            while end < run.endIndex {
                let point = run[end]
                guard isStayCandidate(point) else { break }
                let distance = point.coordinate.location.distance(from: anchor)
                if distance > stayRadius {
                    let next = end + 1
                    guard distance <= stayRadius + point.accuracy, next < run.endIndex,
                          isStayCandidate(run[next]),
                          run[next].timestamp.timeIntervalSince(run[end - 1].timestamp) <= LocationSampling.maximumGap,
                          run[next].coordinate.location.distance(from: anchor) <= stayRadius else { break }
                }
                end += 1
            }
            guard run[end - 1].timestamp.timeIntervalSince(first.timestamp) >= minimumVisitDuration else {
                candidate += 1
                continue
            }
            if start < candidate { slices.append(TimelineSlice(points: run[start..<candidate])) }
            let points = run[candidate..<end]
            slices.append(TimelineSlice(points: points, visitCoordinate: center(of: points, near: first.coordinate)))
            start = end
            candidate = end
        }
        if start < run.endIndex { slices.append(TimelineSlice(points: run[start...])) }
        return slices
    }

    private static func isStayCandidate(_ point: RoutePoint) -> Bool {
        point.mode == .stationary || point.mode == .unknown
    }

    private static func center(of points: ArraySlice<RoutePoint>, near anchor: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let anchorLocation = anchor.location
        var latitude = 0.0
        var longitudeOffset = 0.0
        var weight = 0.0
        for point in points where point.coordinate.location.distance(from: anchorLocation) <= stayRadius {
            let confidence = 1 / max(point.accuracy, 5)
            let delta = (point.longitude - anchor.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            latitude += point.latitude * confidence
            longitudeOffset += delta * confidence
            weight += confidence
        }
        let longitude = anchor.longitude + longitudeOffset / weight
        if (-180...180).contains(longitude) {
            return CLLocationCoordinate2D(latitude: latitude / weight, longitude: longitude)
        }
        let wrapped = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: latitude / weight, longitude: wrapped)
    }

    private static func endpoints(
        in segments: [RouteActivitySegment],
        previousVisit: CLLocationCoordinate2D?,
        nextVisit: CLLocationCoordinate2D?
    ) -> RouteReviewEntry.Endpoints? {
        let movement = segments.filter { $0.mode != .stationary }
        guard let start = movement.first?.coordinates.first, let end = movement.last?.coordinates.last else { return nil }
        return RouteReviewEntry.Endpoints(start: place(near: start, visit: previousVisit), end: place(near: end, visit: nextVisit))
    }

    private static func place(near endpoint: CLLocationCoordinate2D, visit: CLLocationCoordinate2D?) -> CLLocationCoordinate2D {
        guard let visit, endpoint.location.distance(from: visit.location) <= placeRadius else { return endpoint }
        return visit
    }
}

enum PlaceCategory: String, CaseIterable, Codable, Identifiable {
    case home, work, dining, shopping, exercise, leisure, other

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "家"
        case .work: "工作／学习"
        case .dining: "餐饮"
        case .shopping: "购物"
        case .exercise: "运动"
        case .leisure: "休闲"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .dining: "fork.knife"
        case .shopping: "basket.fill"
        case .exercise: "figure.run"
        case .leisure: "cup.and.saucer.fill"
        case .other: "mappin.circle.fill"
        }
    }

    var defaultName: String { self == .work ? "公司" : title }
}

@MainActor
@Observable
final class RoutePlaceNames {
    private struct SavedName: Codable {
        var name: String
        var category: PlaceCategory?
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

    func category(for coordinate: CLLocationCoordinate2D) -> PlaceCategory? {
        matchingIndex(for: coordinate).flatMap { names[$0].category }
    }

    func save(_ name: String?, category: PlaceCategory? = nil, for coordinate: CLLocationCoordinate2D) throws {
        if let loadError { throw loadError }
        var updated = names
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = matchingIndex(for: coordinate) {
            if trimmed.isEmpty {
                updated.remove(at: index)
            } else {
                updated[index].name = trimmed
                updated[index].category = category
            }
        } else if !trimmed.isEmpty {
            updated.append(SavedName(name: trimmed, category: category, latitude: coordinate.latitude, longitude: coordinate.longitude))
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
    var startsRecordingRun: Bool?
    var route: RecordedRoute?

    init(location: CLLocation, mode: TravelMode, startsNewSegment: Bool, startsRecordingRun: Bool? = nil, route: RecordedRoute) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        travelMode = mode.rawValue
        self.startsNewSegment = startsNewSegment
        self.startsRecordingRun = startsRecordingRun
        self.route = route
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mode: TravelMode { TravelMode(rawValue: travelMode) ?? .unknown }
}

enum TravelMode: String, CaseIterable {
    case unknown, walking, automotive, cycling, stationary

    fileprivate static func estimated(metersPerSecond: CLLocationSpeed) -> Self {
        switch metersPerSecond * 3.6 {
        case 0..<7: .walking
        case 7...25: .cycling
        default: .automotive
        }
    }

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
    static let accuracyLimit: CLLocationAccuracy = 50
    static let speedLimit: CLLocationSpeed = 200 / 3.6

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
            maximumAccuracy = Self.accuracyLimit
            maximumTravelSpeed = Self.speedLimit
        case .cycling:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 15
            maximumAccuracy = 40
            maximumTravelSpeed = 30
        case .stationary:
            desiredAccuracy = kCLLocationAccuracyHundredMeters
            distanceFilter = kCLDistanceFilterNone
            maximumAccuracy = Self.accuracyLimit
            maximumTravelSpeed = Self.speedLimit
        case .unknown:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 10
            maximumAccuracy = 45
            maximumTravelSpeed = Self.speedLimit
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
        let meters = location.distance(from: previous)
        guard meters / seconds <= maximumTravelSpeed else { return nil }
        if mode == .stationary {
            if previousMode != .stationary { return .newSegment }
            return seconds >= 30 ? .continuation(distance: 0) : nil
        }
        if previousMode == .stationary { return .newSegment }
        let noiseAllowance = (location.horizontalAccuracy + previous.horizontalAccuracy) * 0.35
        if meters >= max(distanceFilter, noiseAllowance) { return .continuation(distance: meters) }
        if mode == .unknown, seconds >= 30 { return .continuation(distance: 0) }
        return nil
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
