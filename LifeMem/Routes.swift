import CoreLocation
import Foundation
import SwiftData

struct RouteReviewRevision: Hashable {
    fileprivate struct RouteVersion: Hashable {
        let id: UUID
        let pointCount: Int
    }

    let calendar: Calendar
    fileprivate let routes: [RouteVersion]

    init(calendar: Calendar, routes: [RecordedRoute]) {
        // Freeze the effective settings before storing a key built from an autoupdating calendar.
        var resolved = Calendar(identifier: calendar.identifier)
        resolved.locale = calendar.locale.map { Locale(identifier: $0.identifier) }
        resolved.timeZone = TimeZone(identifier: calendar.timeZone.identifier) ?? calendar.timeZone
        resolved.firstWeekday = calendar.firstWeekday
        resolved.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        self.calendar = resolved
        self.routes = routes.map { RouteVersion(id: $0.id, pointCount: $0.pointCount) }
    }
}

@MainActor
final class RouteReviewCache {
    private var revision: RouteReviewRevision?
    private var contributions: [RouteReviewRevision.RouteVersion: RouteReview.Contribution] = [:]
    private var snapshot: RouteReview?

    func review(routes: [RecordedRoute], calendar: Calendar) -> RouteReview {
        let current = RouteReviewRevision(calendar: calendar, routes: routes)
        if revision == current, let snapshot { return snapshot }
        if revision?.calendar != current.calendar { contributions.removeAll() }

        var retained: [RouteReviewRevision.RouteVersion: RouteReview.Contribution] = [:]
        let ordered = zip(routes, current.routes).map { route, version in
            let value = contributions[version] ?? RouteReview.contribution(for: route, calendar: current.calendar)
            retained[version] = value
            return value
        }
        let result = RouteReview(contributions: ordered)
        contributions = retained
        revision = current
        snapshot = result
        return result
    }
}

struct RouteReview {
    static let placeRadius: CLLocationDistance = 100

    let days: [RouteReviewDay]
    let places: [RoutePlace]
    let journeys: [RouteJourney]

    fileprivate struct Contribution {
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        var midnightMovement: [Date: RouteReviewDay.Movement] = [:]
        var visits: [RouteVisit] = []
        var journeys: [RouteJourney] = []
    }

    init(routes: [RecordedRoute], calendar: Calendar) {
        self.init(contributions: routes.map { Self.contribution(for: $0, calendar: calendar) })
    }

    fileprivate init(contributions: [Contribution]) {
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        var midnightMovement: [Date: RouteReviewDay.Movement] = [:]
        for contribution in contributions {
            for (date, entries) in contribution.entriesByDay {
                entriesByDay[date, default: []].append(contentsOf: entries)
            }
            for (date, movement) in contribution.midnightMovement {
                midnightMovement[date, default: .init()].duration += movement.duration
                midnightMovement[date, default: .init()].distance += movement.distance
            }
        }
        days = entriesByDay.keys.sorted(by: >).map { date in
            RouteReviewDay(
                date: date,
                entries: entriesByDay[date, default: []].sorted { $0.startedAt < $1.startedAt },
                midnightMovement: midnightMovement[date, default: .init()]
            )
        }
        places = RoutePlace.group(contributions.flatMap(\.visits), within: Self.placeRadius)
        journeys = contributions.flatMap(\.journeys)
    }

    fileprivate static func contribution(for route: RecordedRoute, calendar: Calendar) -> Contribution {
        var contribution = Contribution()
        for (index, slices) in SegmentBuilder.build(route.points.map(\.locationPoint)).enumerated() {
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
                    contribution.visits.append(RouteVisit(id: first.id, date: firstDay, startedAt: first.timestamp, endedAt: last.timestamp, coordinate: visit))
                } else {
                    if firstDay != lastDay {
                        for (from, to) in zip(slice.points, slice.points.dropFirst())
                            where from.mode != .stationary && to.mode != .stationary && !to.startsNewSegment {
                            Self.allocateMidnightEdge(from: from, to: to, calendar: calendar, totals: &contribution.midnightMovement)
                        }
                    }
                    if let from = leading, first.mode != .stationary {
                        Self.allocateMidnightEdge(from: from, to: first, calendar: calendar, totals: &contribution.midnightMovement)
                    }
                    if let to = trailing, last.mode != .stationary {
                        Self.allocateMidnightEdge(from: last, to: to, calendar: calendar, totals: &contribution.midnightMovement)
                    }
                }
                var completeSegments: [RouteActivitySegment]?
                for (day, points) in pointsByDay {
                    let followsGap = index > 0 && sliceIndex == 0 && day == firstDay
                    let previousVisit = day == firstDay ? previousCoordinate : nil
                    let nextVisit = day == lastDay ? nextCoordinate : nil
                    let sameDayLeading = leading.flatMap { calendar.isDate($0.timestamp, inSameDayAs: day) ? $0 : nil }
                    let sameDayTrailing = trailing.flatMap { calendar.isDate($0.timestamp, inSameDayAs: day) ? $0 : nil }
                    let segments = SegmentBuilder.group(
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
                            visitID: first.id,
                            coordinate: coordinate,
                            startedAt: max(day, first.timestamp),
                            endedAt: min(dayEnd, last.timestamp)
                        )
                    }
                    contribution.entriesByDay[day, default: []].append(RouteReviewEntry(
                        kind: kind,
                        followsGap: followsGap,
                        segments: segments,
                        endpoints: endpoints,
                        stay: stay
                    ))
                }

                if slice.visitCoordinate == nil {
                    let segments = completeSegments ?? SegmentBuilder.group(
                        sortedPoints: Array(slice.points), inferModes: true,
                        leadingStayPoint: leading, trailingStayPoint: trailing
                    )
                    let arrival = trailing.flatMap { point in
                        nextCoordinate.map { RouteJourney.StayConnection(coordinate: $0, time: point.timestamp) }
                    }
                    if let journey = Self.journey(in: segments, departure: previousCoordinate, arrival: arrival) {
                        contribution.journeys.append(journey)
                    }
                }
            }
        }
        return contribution
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
        from first: LocationPoint<PersistentIdentifier>,
        to second: LocationPoint<PersistentIdentifier>,
        calendar: Calendar,
        totals: inout [Date: RouteReviewDay.Movement]
    ) {
        let startDay = calendar.startOfDay(for: first.timestamp)
        let endDay = calendar.startOfDay(for: second.timestamp)
        guard startDay != endDay else { return }
        let distance = SegmentBuilder.measuredDistance(from: first, to: second)
        guard distance > 0 else { return }
        let seconds = second.timestamp.timeIntervalSince(first.timestamp)
        let before = endDay.timeIntervalSince(first.timestamp)
        totals[startDay, default: .init()].duration += before
        totals[startDay, default: .init()].distance += distance * before / seconds
        totals[endDay, default: .init()].duration += seconds - before
        totals[endDay, default: .init()].distance += distance * (seconds - before) / seconds
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
