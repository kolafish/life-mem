import CoreLocation
import Foundation
import SwiftData

struct RouteReviewRevision: Hashable, Sendable {
    struct RouteVersion: Hashable, Codable, Sendable {
        let id: UUID
        let pointCount: Int
        var visitRevision: UUID?
        var endedAtRest: Bool?
        var isAutomatic: Bool?
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
        self.routes = routes.map { RouteVersion(id: $0.id, pointCount: $0.pointCount, visitRevision: $0.visitRevision, endedAtRest: $0.endedAtRest, isAutomatic: $0.isAutomatic) }
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
        let result = RouteReview(contributions: ordered, calendar: current.calendar)
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

    func visits(
        for routes: [RecordedRoute],
        revision: RouteReviewRevision,
        indexed: [RouteReviewRevision.RouteVersion: RouteSummaryRecord]
    ) -> [RouteVisit] {
        selectCalendar(revision.calendar)
        return zip(routes, revision.routes).flatMap { route, version in
            if let indexed = indexed[version] { return indexed.visits }
            let contribution = contributions[version] ?? RouteReview.contribution(for: route, calendar: revision.calendar)
            contributions[version] = contribution
            return contribution.visits
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
        var boundary: AutomaticVisitBoundary?
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        var visits: [RouteVisit] = []
        var journeys: [RouteJourney] = []

        var summary: RouteSummaryRecord {
            let days = entriesByDay.map { date, entries in
                DailySummary(day: RouteReviewDay(date: date, entries: entries))
            }
            return RouteSummaryRecord(days: days, visits: visits, journeys: journeys, boundary: boundary)
        }
    }

    init(routes: [RecordedRoute], calendar: Calendar) {
        self.init(contributions: routes.map { Self.contribution(for: $0, calendar: calendar) }, calendar: calendar)
    }

    fileprivate init(contributions: [Contribution], calendar: Calendar) {
        var entriesByDay: [Date: [RouteReviewEntry]] = [:]
        let resolved = ResolvedVisitGaps(contributions.compactMap { item in
            item.boundary.map { ($0, item.visits) }
        }, calendar: calendar)
        let inferred = resolved.gaps
        let edges = ConfirmedVisitEdges(visits: inferred)
        for contribution in contributions {
            for (date, entries) in contribution.entriesByDay {
                entriesByDay[date, default: []] += entries.compactMap { entry in
                    if let stay = entry.stay, resolved.incorporated.contains(stay.visitID) { return nil }
                    var entry = entry
                    if let ends = entry.endpoints {
                        entry.endpoints = edges.names(for: contribution.boundary, endpoints: ends,
                                                      start: entry.startedAt, end: entry.endedAt)
                    }
                    return entry
                }
            }
        }
        for visit in inferred {
            for (day, stay) in visit.dailyInferredStays(calendar: calendar) {
                entriesByDay[day, default: []].append(.init(kind: .visit, followsGap: false, segments: [], endpoints: nil, stay: stay))
            }
        }
        days = entriesByDay.keys.sorted(by: >).map { date in
            RouteReviewDay(
                date: date,
                entries: entriesByDay[date, default: []].sorted { $0.startedAt < $1.startedAt }
            )
        }
        places = RoutePlace.group(resolved.placeVisits(contributions.flatMap(\.visits)), within: Self.placeRadius)
        journeys = contributions.flatMap { item in item.journeys.map { edges.applying(to: $0, boundary: item.boundary) } }
    }

    static func summaryRecord(for route: RecordedRoute, calendar: Calendar) -> RouteSummaryRecord {
        contribution(for: route, calendar: calendar).summary
    }

    fileprivate static func contribution(for route: RecordedRoute, calendar: Calendar) -> Contribution {
        var contribution = Contribution()
        let points = route.points
        let edits = Dictionary(uniqueKeysWithValues: points.compactMap { point in
            point.visitName.map { (point.persistentModelID, $0) }
        })
        let runs = SegmentBuilder.build(points.map(\.locationPoint), automatic: route.isAutomatic == true,
                                        namedVisitStarts: Set(edits.keys))
        if route.isAutomatic == true, let session = route.automaticSessionStart,
           let first = runs.first?.first, let last = runs.last?.last,
           let start = first.points.first, let end = last.points.last {
            contribution.boundary = AutomaticVisitBoundary(
                routeID: route.id, id: route.persistentModelID, previous: route.previousAutomaticRouteID,
                session: session, start: start.timestamp, end: end.timestamp,
                origin: StoredCoordinate(start.coordinate), destination: StoredCoordinate(end.coordinate),
                startsWithVisit: first.visitCoordinate != nil, endsWithVisit: last.visitCoordinate != nil,
                endedAtRest: route.endedAtRest == true, decision: route.arrivalDecision, name: route.arrivalName)
        }
        for (index, slices) in runs.enumerated() {
            for (sliceIndex, slice) in slices.enumerated() {
                let first = slice.points[slice.points.startIndex]
                let firstDay = calendar.startOfDay(for: first.timestamp)
                let last = slice.points[slice.points.endIndex - 1]
                let lastDay = calendar.startOfDay(for: last.timestamp)
                if let visit = slice.visitCoordinate {
                    var observation = RouteVisit(id: first.id, date: firstDay, startedAt: first.timestamp, endedAt: last.timestamp, coordinate: visit)
                    observation.visitName = edits[first.id]
                    contribution.visits.append(observation)
                    let pointsByDay = Dictionary(grouping: slice.points) { calendar.startOfDay(for: $0.timestamp) }
                    for (day, points) in pointsByDay {
                        let segments = SegmentBuilder.group(sortedPoints: points)
                        let dayEnd = calendar.dateInterval(of: .day, for: day)?.end ?? last.timestamp
                        var stay = StayEvent(id: segments[0].id, visitID: first.id, coordinate: visit,
                                             startedAt: max(day, first.timestamp), endedAt: min(dayEnd, last.timestamp))
                        stay.visitName = observation.visitName
                        contribution.entriesByDay[day, default: []].append(RouteReviewEntry(
                            kind: .visit, followsGap: index > 0 && sliceIndex == 0 && day == firstDay,
                            segments: segments, endpoints: nil, stay: stay
                        ))
                    }
                    continue
                }

                let previousSlice = sliceIndex > 0 ? slices[sliceIndex - 1] : nil
                let nextSlice = sliceIndex + 1 < slices.count ? slices[sliceIndex + 1] : nil
                let previousCoordinate = previousSlice.flatMap { previous in
                    previous.points.last.flatMap { first.continuesObservation(after: $0) ? previous.visitCoordinate : nil }
                }
                let nextCoordinate = nextSlice.flatMap { next in
                    next.points.first.flatMap { $0.continuesObservation(after: last) ? next.visitCoordinate : nil }
                }
                let leading = previousCoordinate == nil ? nil : previousSlice?.points.last
                let trailing = nextCoordinate == nil ? nil : nextSlice?.points.first
                let completeSegments = SegmentBuilder.group(sortedPoints: Array(slice.points), inferModes: true,
                                                            leadingStayPoint: leading, trailingStayPoint: trailing)
                let departureDay = leading.map { calendar.startOfDay(for: $0.timestamp) }
                let arrivalDay = trailing.map { calendar.startOfDay(for: $0.timestamp) }
                let startName = leading == nil ? nil : previousSlice?.points.first.flatMap { edits[$0.id] }
                let endName = trailing.flatMap { edits[$0.id] }
                for (day, segments) in SegmentBuilder.project(completeSegments, by: calendar) {
                    let hasMovement = segments.contains { $0.distanceMeters > 0 }
                    guard hasMovement || (firstDay...lastDay).contains(day) else { continue }
                    var endpoints = hasMovement ? Self.endpoints(in: segments, previousVisit: day == departureDay ? previousCoordinate : nil,
                                                                nextVisit: day == arrivalDay ? nextCoordinate : nil) : nil
                    endpoints?.startName = day == departureDay ? startName : nil
                    endpoints?.endName = day == arrivalDay ? endName : nil
                    contribution.entriesByDay[day, default: []].append(RouteReviewEntry(
                        kind: hasMovement ? .trip : .fragment, followsGap: index > 0 && sliceIndex == 0 && day == firstDay,
                        segments: segments, endpoints: endpoints, stay: nil
                    ))
                }
                let arrival = trailing.flatMap { point in
                    nextCoordinate.map { RouteJourney.StayConnection(coordinate: $0, time: point.timestamp) }
                }
                if var journey = Self.journey(in: completeSegments, points: slice.points, departure: previousCoordinate, arrival: arrival) {
                    if journey.departureStay != nil { journey.endpoints.startName = startName }
                    if journey.arrivalStay != nil { journey.endpoints.endName = endName }
                    contribution.journeys.append(journey)
                }
            }
        }
        return contribution
    }

    private static func journey(
        in segments: [RouteActivitySegment], points: ArraySlice<LocationPoint<PersistentIdentifier>>,
        departure: CLLocationCoordinate2D?,
        arrival: RouteJourney.StayConnection?
    ) -> RouteJourney? {
        let moving = segments.filter { $0.distanceMeters > 0 }
        guard let first = moving.first, let last = moving.last else { return nil }
        // A zero-distance fix can touch a visit even when the first measured movement is across a signal gap.
        let gaps = points.indices.dropFirst().filter { !points[$0].continuesObservation(after: points[$0 - 1]) }
        let detachedStart = gaps.contains { points[$0].timestamp <= first.movementStartedAt }
        let detachedEnd = gaps.contains { points[$0 - 1].timestamp >= last.endedAt }
        let departure = detachedStart ? nil : departure
        let arrival = detachedEnd ? nil : arrival
        guard let endpoints = endpoints(in: moving, previousVisit: departure, nextVisit: arrival?.coordinate) else { return nil }
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

struct AutomaticVisitBoundary: Codable, Sendable {
    let routeID: UUID
    let id: PersistentIdentifier
    let previous: UUID?
    let session: Date
    let start: Date
    let end: Date
    let origin: StoredCoordinate
    let destination: StoredCoordinate
    let startsWithVisit: Bool
    let endsWithVisit: Bool
    let endedAtRest: Bool

    var decision: String?
    var name: String?

    static func candidates(in boundaries: [Self], calendar: Calendar) -> [RouteVisit] {
        let sources = Dictionary(uniqueKeysWithValues: boundaries.map { ($0.routeID, $0) })
        return boundaries.compactMap { departure in
            guard departure.decision != "ignored", let previous = departure.previous, let arrival = sources[previous],
                  arrival.endedAtRest, arrival.session == departure.session,
                  departure.decision == "confirmed" || (!arrival.endsWithVisit && !departure.startsWithVisit),
                  departure.start.timeIntervalSince(arrival.end) >= 8 * 60,
                  departure.start.timeIntervalSince(arrival.end) <= 24 * 3600,
                  arrival.destination.coordinate.location.distance(from: departure.origin.coordinate.location) <= RouteReview.placeRadius
            else { return nil }
            var visit = RouteVisit(id: departure.id, date: calendar.startOfDay(for: arrival.end), startedAt: arrival.end,
                                   endedAt: departure.start, coordinate: arrival.destination.coordinate)
            visit.isConfirmed = departure.decision == "confirmed"
            visit.visitName = departure.name
            visit.sourceArrivalID = previous
            visit.sourceDepartureID = departure.routeID
            return visit
        }
    }
}

/// A confirmed gap remains editable after a new detector recognizes additional dwell on either edge.
struct ResolvedVisitGaps {
    private(set) var incorporated = Set<PersistentIdentifier>()
    private(set) var gaps: [RouteVisit] = []

    init(_ routes: [(AutomaticVisitBoundary, [RouteVisit])], calendar: Calendar) {
        let byRoute = Dictionary(uniqueKeysWithValues: routes.map { ($0.0.routeID, $0.1) })
        let candidates = AutomaticVisitBoundary.candidates(in: routes.map { $0.0 }, calendar: calendar)
        for candidate in candidates.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard candidate.isConfirmed else { gaps.append(candidate); continue }
            let before = candidate.sourceArrivalID.flatMap { byRoute[$0]?.last }
            let after = candidate.sourceDepartureID.flatMap { byRoute[$0]?.first }
            var start = candidate.startedAt
            var end = candidate.endedAt
            // Independently named observations retain their own edit owner.
            for edge in [before, after].compactMap({ $0 }) where edge.visitName == nil {
                guard edge.coordinate.location.distance(from: candidate.coordinate.location) <= RouteReview.placeRadius,
                      edge.endedAt == candidate.startedAt || edge.startedAt == candidate.endedAt,
                      incorporated.insert(edge.id).inserted else { continue }
                start = min(start, edge.startedAt)
                end = max(end, edge.endedAt)
            }
            var visit = RouteVisit(id: candidate.id, date: calendar.startOfDay(for: start), startedAt: start,
                                   endedAt: end, coordinate: candidate.coordinate)
            visit.isConfirmed = true
            visit.visitName = candidate.visitName
            visit.sourceArrivalID = candidate.sourceArrivalID
            visit.sourceDepartureID = candidate.sourceDepartureID
            gaps.append(visit)
        }
    }

    func placeVisits(_ observations: [RouteVisit]) -> [RouteVisit] {
        observations.filter { !incorporated.contains($0.id) } + gaps.filter(\.isConfirmed)
    }
}

extension RouteVisit {
    func dailyInferredStays(calendar: Calendar) -> [(Date, StayEvent)] {
        var result: [(Date, StayEvent)] = []
        var day = calendar.startOfDay(for: startedAt)
        while day < endedAt, let end = calendar.dateInterval(of: .day, for: day)?.end {
            var stay = StayEvent(id: id, visitID: id, coordinate: coordinate,
                                 startedAt: max(day, startedAt), endedAt: min(end, endedAt))
            stay.isInferred = true
            stay.isCandidate = !isConfirmed
            stay.sourceArrivalID = sourceArrivalID
            stay.visitName = visitName
            result.append((day, stay))
            day = end
        }
        return result
    }
}

struct ConfirmedVisitEdges {
    private let starts: [UUID: RouteVisit]
    private let ends: [UUID: RouteVisit]

    init(visits: [RouteVisit]) {
        let confirmed = visits.filter(\.isConfirmed)
        starts = Dictionary(confirmed.compactMap { v in v.sourceDepartureID.map { ($0, v) } }, uniquingKeysWith: { first, _ in first })
        ends = Dictionary(confirmed.compactMap { v in v.sourceArrivalID.map { ($0, v) } }, uniquingKeysWith: { first, _ in first })
    }

    private func matches(_ time: Date, _ position: CLLocationCoordinate2D, _ edge: Date, _ visit: RouteVisit) -> Bool {
        abs(time.timeIntervalSince(edge)) <= LocationSampling.maximumGap &&
            position.location.distance(from: visit.coordinate.location) <= RouteReview.placeRadius
    }

    func names(for boundary: AutomaticVisitBoundary?, endpoints: RouteReviewEntry.Endpoints,
               start: Date, end: Date) -> RouteReviewEntry.Endpoints {
        guard let boundary else { return endpoints }
        var updated = endpoints
        if let visit = starts[boundary.routeID], matches(start, endpoints.start, visit.endedAt, visit) {
            updated.startName = visit.visitName
        }
        if let visit = ends[boundary.routeID], matches(end, endpoints.end, visit.startedAt, visit) {
            updated.endName = visit.visitName
        }
        return updated
    }

    func applying(to journey: RouteJourney, boundary: AutomaticVisitBoundary?) -> RouteJourney {
        guard let boundary else { return journey }
        var updated = journey
        let end = journey.departedAt.addingTimeInterval(journey.duration)
        updated.endpoints = names(for: boundary, endpoints: journey.endpoints, start: journey.departedAt, end: end)
        if let visit = starts[boundary.routeID], matches(journey.departedAt, journey.endpoints.start, visit.endedAt, visit) {
            updated.departureStay = .init(coordinate: visit.coordinate, time: visit.endedAt)
        }
        if let visit = ends[boundary.routeID], matches(end, journey.endpoints.end, visit.startedAt, visit) {
            updated.arrivalStay = .init(coordinate: visit.coordinate, time: visit.startedAt)
        }
        return updated
    }
}
