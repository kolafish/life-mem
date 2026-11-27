import CoreLocation
import Foundation
import SwiftData

struct RouteReviewRevision: Hashable, Sendable {
    struct RouteVersion: Hashable, Codable, Sendable {
        let id: UUID
        let pointCount: Int
    }

    let calendar: Calendar
    let routes: [RouteVersion]

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
    private var contributionCalendar: Calendar?
    private var contributions: [RouteReviewRevision.RouteVersion: RouteReview.Contribution] = [:]
    private var snapshot: RouteReview?

    func review(routes: [RecordedRoute], calendar: Calendar) -> RouteReview {
        let current = RouteReviewRevision(calendar: calendar, routes: routes)
        if revision == current, let snapshot { return snapshot }
        selectCalendar(current.calendar)

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

    func summaries(
        for routes: [RecordedRoute],
        revision: RouteReviewRevision,
        indexed: [RouteReviewRevision.RouteVersion: RouteSummaryRecord]
    ) -> [RouteReviewRevision.RouteVersion: RouteSummaryRecord] {
        selectCalendar(revision.calendar)
        let active = Set(revision.routes)
        contributions = contributions.filter { active.contains($0.key) }
        return zip(routes, revision.routes).reduce(into: indexed) { records, pair in
            let (route, version) = pair
            guard records[version] == nil else { return }
            let contribution = contributions[version] ?? RouteReview.contribution(for: route, calendar: revision.calendar)
            contributions[version] = contribution
            records[version] = contribution.summary
        }
    }

    private func selectCalendar(_ calendar: Calendar) {
        if contributionCalendar != calendar {
            contributions.removeAll()
            contributionCalendar = calendar
        }
    }
}

struct RouteReview {
    static let placeRadius: CLLocationDistance = 100

    let days: [RouteReviewDay]
    let places: [RoutePlace]
    let journeys: [RouteJourney]

    fileprivate struct Contribution {
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        var visits: [RouteVisit] = []
        var journeys: [RouteJourney] = []

        var summary: RouteSummaryRecord {
            let days = entriesByDay.map { date, entries in
                DailySummary(day: RouteReviewDay(date: date, entries: entries))
            }
            return RouteSummaryRecord(days: days, visits: visits, journeys: journeys)
        }
    }

    init(routes: [RecordedRoute], calendar: Calendar) {
        self.init(contributions: routes.map { Self.contribution(for: $0, calendar: calendar) })
    }

    fileprivate init(contributions: [Contribution]) {
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        for contribution in contributions {
            for (date, entries) in contribution.entriesByDay {
                entriesByDay[date, default: []].append(contentsOf: entries)
            }
        }
        days = entriesByDay.keys.sorted(by: >).map { date in
            RouteReviewDay(
                date: date,
                entries: entriesByDay[date, default: []].sorted { $0.startedAt < $1.startedAt }
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
                let last = slice.points[slice.points.endIndex - 1]
                let lastDay = calendar.startOfDay(for: last.timestamp)
                let previousSlice = sliceIndex > 0 ? slices[sliceIndex - 1] : nil
                let nextSlice = sliceIndex + 1 < slices.count ? slices[sliceIndex + 1] : nil
                let previousCoordinate = previousSlice?.visitCoordinate
                let nextCoordinate = nextSlice?.visitCoordinate
                if let visit = slice.visitCoordinate {
                    contribution.visits.append(RouteVisit(id: first.id, date: firstDay, startedAt: first.timestamp, endedAt: last.timestamp, coordinate: visit))
                    let pointsByDay = Dictionary(grouping: slice.points) { calendar.startOfDay(for: $0.timestamp) }
                    for (day, points) in pointsByDay {
                        let segments = SegmentBuilder.group(sortedPoints: points)
                        let dayEnd = calendar.dateInterval(of: .day, for: day)?.end ?? last.timestamp
                        let stay = StayEvent(id: segments[0].id, visitID: first.id, coordinate: visit,
                                             startedAt: max(day, first.timestamp), endedAt: min(dayEnd, last.timestamp))
                        contribution.entriesByDay[day, default: []].append(RouteReviewEntry(
                            kind: .visit, followsGap: index > 0 && sliceIndex == 0 && day == firstDay,
                            segments: segments, endpoints: nil, stay: stay
                        ))
                    }
                    continue
                }

                let leading = previousCoordinate == nil ? nil : previousSlice?.points.last
                let trailing = nextCoordinate == nil ? nil : nextSlice?.points.first
                let completeSegments = SegmentBuilder.group(sortedPoints: Array(slice.points), inferModes: true,
                                                            leadingStayPoint: leading, trailingStayPoint: trailing)
                let departureDay = leading.map { calendar.startOfDay(for: $0.timestamp) }
                let arrivalDay = trailing.map { calendar.startOfDay(for: $0.timestamp) }
                for (day, segments) in SegmentBuilder.project(completeSegments, by: calendar) {
                    let hasMovement = segments.contains { $0.distanceMeters > 0 }
                    guard hasMovement || (firstDay...lastDay).contains(day) else { continue }
                    let endpoints = hasMovement ? Self.endpoints(in: segments, previousVisit: day == departureDay ? previousCoordinate : nil,
                                                                nextVisit: day == arrivalDay ? nextCoordinate : nil) : nil
                    contribution.entriesByDay[day, default: []].append(RouteReviewEntry(
                        kind: hasMovement ? .trip : .fragment, followsGap: index > 0 && sliceIndex == 0 && day == firstDay,
                        segments: segments, endpoints: endpoints, stay: nil
                    ))
                }
                let arrival = trailing.flatMap { point in
                    nextCoordinate.map { RouteJourney.StayConnection(coordinate: $0, time: point.timestamp) }
                }
                if let journey = Self.journey(in: completeSegments, departure: previousCoordinate, arrival: arrival) {
                    contribution.journeys.append(journey)
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

    private static func endpoints(
        in segments: [RouteActivitySegment],
        previousVisit: CLLocationCoordinate2D?,
        nextVisit: CLLocationCoordinate2D?
    ) -> RouteReviewEntry.Endpoints? {
        let movement = segments.filter { $0.mode != .stationary }
        guard let start = movement.first?.firstCoordinate, let end = movement.last?.lastCoordinate else { return nil }
        return RouteReviewEntry.Endpoints(start: place(near: start, visit: previousVisit), end: place(near: end, visit: nextVisit))
    }

    private static func place(near endpoint: CLLocationCoordinate2D, visit: CLLocationCoordinate2D?) -> CLLocationCoordinate2D {
        guard let visit, endpoint.location.distance(from: visit.location) <= placeRadius else { return endpoint }
        return visit
    }
}
