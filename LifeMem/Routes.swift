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
    private var keepsTodaySlices = false
    private var revision: RouteReviewRevision?
    private var contributionCalendar: Calendar?
    private var contributions: [RouteReviewRevision.RouteVersion: RouteReview.Contribution] = [:]
    private var snapshot: RouteReview?
    private var overnight: (date: Date, revision: RouteReviewRevision, owners: Set<UUID>)?

    func review(routes: [RecordedRoute], calendar: Calendar) -> RouteReview {
        let current = RouteReviewRevision(calendar: calendar, routes: routes)
        if revision == current, let snapshot { return snapshot }
        selectCalendar(current.calendar)

        var retained: [RouteReviewRevision.RouteVersion: RouteReview.Contribution] = [:]
        let ordered = zip(routes, current.routes).map { route, version in
            let value = contributions[version] ?? RouteReview.contribution(for: route, calendar: current.calendar, keepsTodaySlices: keepsTodaySlices)
            retained[version] = value
            return value
        }
        let result = RouteReview(contributions: ordered, calendar: current.calendar)
        contributions = retained
        revision = current
        snapshot = result
        return result
    }

    func day(routes: [RecordedRoute], containing date: Date, calendar: Calendar) -> RouteReview {
        let midnight = calendar.startOfDay(for: date)
        let end = calendar.dateInterval(of: .day, for: midnight)?.end ?? midnight
        let future = routes.prefix { $0.startedAt >= end }
        let earlier = routes.dropFirst(future.count)
        let sameDay = earlier.prefix { $0.startedAt >= midnight }
        let prior = earlier.dropFirst(sameDay.count)
        var subset = Array(future.suffix(1)) + sameDay + prior.prefix(1)
        if prior.count > 1 {
            let previous = RouteReviewRevision(calendar: calendar, routes: Array(prior))
            if overnight?.date != midnight || overnight?.revision != previous {
                let points = FetchDescriptor<RoutePoint>(predicate: #Predicate {
                    $0.timestamp >= midnight && $0.timestamp < end
                })
                let owners: Set<UUID>
                if let context = prior.first?.modelContext, let found = try? context.fetch(points) {
                    owners = Set(found.compactMap { $0.route?.id })
                } else {
                    owners = Set(prior.filter { route in
                        route.points.contains { $0.timestamp >= midnight && $0.timestamp < end }
                    }.map(\.id))
                }
                overnight = (midnight, previous, owners)
            }
            let linked = Set(subset.compactMap(\.previousAutomaticRouteID))
            subset += prior.dropFirst().filter { overnight?.owners.contains($0.id) == true || linked.contains($0.id) }
        }
        return review(routes: includingPredecessors(of: subset, in: routes, calendar: calendar), calendar: calendar)
    }

    func today(routes: [RecordedRoute], now: Date, calendar: Calendar, places: RoutePlaceSnapshot,
               activeSession: Date?) -> (review: RouteReview, stays: [TodayPlaceStay]) {
        if !keepsTodaySlices {
            keepsTodaySlices = true
            contributions.removeAll()
            revision = nil
        }
        let review = day(routes: routes, containing: now, calendar: calendar)
        var slices = Dictionary(uniqueKeysWithValues: contributions.map { ($0.key.id, $0.value.todaySlices) })
        let stays = TodayPlaceStay.project(routes: routes, now: now, calendar: calendar, places: places,
                                           activeSession: activeSession) { route in
            if let cached = slices[route.id] { return cached }
            let earlier = RouteReview.contribution(for: route, calendar: calendar, keepsTodaySlices: true).todaySlices
            slices[route.id] = earlier
            return earlier
        }
        return (review, stays)
    }

    func detail(for route: RecordedRoute, among routes: [RecordedRoute], calendar: Calendar) -> RouteReview {
        let source = RouteReview.contribution(for: route, calendar: calendar)
        guard route.previousAutomaticRouteID != nil else {
            return RouteReview(contributions: [source], calendar: calendar)
        }
        let related = includingPredecessors(of: [route], in: routes, calendar: calendar)
        let context = related.map { $0.id == route.id ? source : RouteReview.contribution(for: $0, calendar: calendar) }
        return RouteReview(contributions: [source], calendar: calendar, keyContext: context)
    }

    private func includingPredecessors(of subset: [RecordedRoute], in routes: [RecordedRoute], calendar: Calendar) -> [RecordedRoute] {
        var included = subset
        let known = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        var ids = Set(included.map(\.id))
        selectCalendar(calendar)
        func boundary(_ route: RecordedRoute) -> AutomaticVisitBoundary? {
            let version = RouteReviewRevision.RouteVersion(id: route.id, pointCount: route.pointCount, visitRevision: route.visitRevision,
                                                         endedAtRest: route.endedAtRest, isAutomatic: route.isAutomatic)
            if let existing = contributions[version] { return existing.boundary }
            let result = RouteReview.contribution(for: route, calendar: calendar, keepsTodaySlices: keepsTodaySlices)
            contributions[version] = result
            return result.boundary
        }
        var index = included.startIndex
        while index < included.endIndex {
            let next = included[index]
            index += 1
            guard let id = next.previousAutomaticRouteID, !ids.contains(id), let previous = known[id],
                  next.arrivalDecision != "confirmed", previous.endedAtRest == true,
                  let head = boundary(next), let tail = boundary(previous), head.continuesDrive(from: tail) else { continue }
            ids.insert(id)
            included.append(previous)
        }
        return included
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
            let contribution = contributions[version] ?? RouteReview.contribution(for: route, calendar: revision.calendar, keepsTodaySlices: keepsTodaySlices)
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
            let contribution = contributions[version] ?? RouteReview.contribution(for: route, calendar: revision.calendar, keepsTodaySlices: keepsTodaySlices)
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
        var todaySlices: [SegmentBuilder.Slice<PersistentIdentifier>] = []
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

    fileprivate init(contributions: [Contribution], calendar: Calendar, keyContext: [Contribution]? = nil) {
        var entriesByDay: [Date: [(UUID?, RouteReviewEntry)]] = [:]
        let resolved = ResolvedVisitGaps(contributions.compactMap { item in
            item.boundary.map { ($0, item.visits) }
        }, calendar: calendar)
        // Link the source trip keys before projecting joined drives into individual days.
        let keyResolver = keyContext.map { sources in
            ResolvedVisitGaps(sources.compactMap { item in item.boundary.map { ($0, item.visits) } }, calendar: calendar)
        } ?? resolved
        let routes = (keyContext ?? contributions).compactMap { item -> (UUID, [RouteReviewEntry])? in
            guard let id = item.boundary?.routeID else { return nil }
            return (id, item.entriesByDay.values.flatMap { $0 }.filter { $0.kind == .trip })
        }
        let sharedKeys = keyResolver.sharedTripKeys(routes)
        let inferred = resolved.gaps
        let edges = ConfirmedVisitEdges(visits: inferred)
        for contribution in contributions {
            for (date, entries) in contribution.entriesByDay {
                entriesByDay[date, default: []] += entries.compactMap { entry in
                    if let stay = entry.stay, resolved.incorporated.contains(stay.visitID) { return nil }
                    var entry = entry
                    if let key = entry.memoryKey, let shared = sharedKeys[key] { entry.memoryKey = shared }
                    if let ends = entry.endpoints {
                        entry.endpoints = edges.names(for: contribution.boundary, endpoints: ends,
                                                      start: entry.startedAt, end: entry.endedAt)
                    }
                    return (contribution.boundary?.routeID, entry)
                }
            }
        }
        for visit in inferred {
            for (day, stay) in visit.dailyInferredStays(calendar: calendar) {
                let key = visit.sourceDepartureID.flatMap { departure in
                    visit.sourceArrivalID.map { RouteMemoryKey(arrival: $0, departure: departure) }
                }
                entriesByDay[day, default: []].append((nil, .init(memoryKey: visit.isConfirmed ? key : nil, observedVisits: resolved.observedEdges[visit.id] ?? [], kind: .visit, followsGap: false, segments: [], endpoints: nil, stay: stay)))
            }
        }
        days = entriesByDay.keys.sorted(by: >).map { date in
            RouteReviewDay(
                date: date,
                entries: resolved.joinDriveLegs(entriesByDay[date, default: []], start: \.startedAt) { first, next in
                    guard let from = first.endpoints, let to = next.endpoints else { return nil }
                    return .init(memoryKey: first.memoryKey, kind: .trip, followsGap: first.followsGap, segments: first.segments + next.segments,
                                 endpoints: from.continuing(to: to), stay: nil)
                }
            )
        }
        places = RoutePlace.group(resolved.placeVisits(contributions.flatMap(\.visits)), within: Self.placeRadius)
        journeys = resolved.journeys(contributions.flatMap { item in
            item.journeys.map { (item.boundary?.routeID, edges.applying(to: $0, boundary: item.boundary)) }
        })
    }

    static func summaryRecord(for route: RecordedRoute, calendar: Calendar) -> RouteSummaryRecord {
        contribution(for: route, calendar: calendar).summary
    }

    fileprivate static func contribution(for route: RecordedRoute, calendar: Calendar,
                                         keepsTodaySlices: Bool = false) -> Contribution {
        var contribution = Contribution()
        lazy var annotated = route.annotatedObservations()
        let points = route.points
        let edits = Dictionary(uniqueKeysWithValues: points.compactMap { point in
            point.visitName.map { (point.persistentModelID, $0) }
        })
        let runs = SegmentBuilder.build(points.map(\.locationPoint), automatic: route.isAutomatic == true,
                                        namedVisitStarts: Set(edits.keys))
        if keepsTodaySlices, route.isAutomatic == true { contribution.todaySlices = runs.flatMap { $0 } }
        if route.isAutomatic == true, let session = route.automaticSessionStart,
           let first = runs.first?.first, let last = runs.last?.last,
           let start = first.points.first, let end = last.points.last {
            contribution.boundary = AutomaticVisitBoundary(
                routeID: route.id, id: route.persistentModelID, previous: route.previousAutomaticRouteID,
                session: session, start: start.timestamp, end: end.timestamp,
                origin: StoredCoordinate(start.coordinate), destination: StoredCoordinate(end.coordinate),
                startsWithVisit: first.visitCoordinate != nil, endsWithVisit: last.visitCoordinate != nil,
                endedAtRest: route.endedAtRest == true,
                decision: route.arrivalDecision, name: route.arrivalName)
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
                    observation.hasMemory = annotated.contains(RouteMemoryKey(owner: route.id, start: first.timestamp).value)
                    contribution.visits.append(observation)
                    let pointsByDay = Dictionary(grouping: slice.points) { calendar.startOfDay(for: $0.timestamp) }
                    for (day, points) in pointsByDay {
                        let segments = SegmentBuilder.group(sortedPoints: points)
                        let dayEnd = calendar.dateInterval(of: .day, for: day)?.end ?? last.timestamp
                        var stay = StayEvent(id: segments[0].id, visitID: first.id, coordinate: visit,
                                             startedAt: max(day, first.timestamp), endedAt: min(dayEnd, last.timestamp))
                        stay.visitName = observation.visitName
                        contribution.entriesByDay[day, default: []].append(RouteReviewEntry(
                            memoryKey: .init(owner: route.id, start: first.timestamp),
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
                        memoryKey: hasMovement ? .init(owner: route.id, start: first.timestamp) : nil,
                        kind: hasMovement ? .trip : .fragment, followsGap: index > 0 && sliceIndex == 0 && day == firstDay,
                        segments: segments, endpoints: endpoints, stay: nil
                    ))
                }
                let arrival = trailing.flatMap { point in
                    nextCoordinate.map { RouteJourney.StayConnection(coordinate: $0, time: point.timestamp) }
                }
                if let result = Self.journey(in: completeSegments, points: slice.points, departure: previousCoordinate, arrival: arrival) {
                    var journey = result.journey
                    if journey.departureStay != nil { journey.endpoints.startName = startName }
                    if journey.arrivalStay != nil { journey.endpoints.endName = endName }
                    if index == 0, sliceIndex == 0, result.connectedStart {
                        contribution.boundary?.startsDriving = ArrivalMotion.adjacent(in: slice.points, from: first).mode == .automotive
                    }
                    if index == runs.count - 1, sliceIndex == slices.count - 1, result.connectedEnd {
                        contribution.boundary?.endsDriving = ArrivalMotion.adjacent(in: slice.points.reversed(), from: last).mode == .automotive
                    }
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
    ) -> (journey: RouteJourney, connectedStart: Bool, connectedEnd: Bool)? {
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
        let mode = RouteJourney.dominantMode(in: durations)
        let journey = RouteJourney(
            id: first.id, endpoints: endpoints, departedAt: first.startedAt, duration: seconds, mode: mode,
            departureStay: departure.map { RouteJourney.StayConnection(coordinate: $0, time: first.startedAt) },
            arrivalStay: arrival, modeDurations: durations
        )
        return (journey, !detachedStart, !detachedEnd)
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

    var startsDriving = false
    var endsDriving = false

    var decision: String?
    var name: String?

    func continuesDrive(from previous: Self) -> Bool {
        self.previous == previous.routeID && session == previous.session && previous.endedAtRest &&
            previous.endsDriving && startsDriving && !previous.endsWithVisit && !startsWithVisit &&
            decision != "confirmed" && (0...ArrivalMotion.maximumResumption).contains(start.timeIntervalSince(previous.end)) &&
            previous.destination.coordinate.location.distance(from: origin.coordinate.location) <= RouteReview.placeRadius
    }

    static func candidates(in sources: [UUID: Self], continuing: [UUID: UUID], calendar: Calendar) -> [RouteVisit] {
        return sources.values.compactMap { departure in
            guard continuing[departure.routeID] == nil, departure.decision != "ignored", let previous = departure.previous, let arrival = sources[previous],
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
    private let continuing: [UUID: UUID]
    private(set) var incorporated = Set<PersistentIdentifier>()
    private(set) var observedEdges: [PersistentIdentifier: [RouteVisit]] = [:]
    private(set) var gaps: [RouteVisit] = []

    init(_ routes: [(AutomaticVisitBoundary, [RouteVisit])], calendar: Calendar) {
        let byRoute = Dictionary(uniqueKeysWithValues: routes.map { ($0.0.routeID, $0.1) })
        let sources = Dictionary(uniqueKeysWithValues: routes.map { ($0.0.routeID, $0.0) })
        continuing = Dictionary(uniqueKeysWithValues: sources.values.compactMap { next -> (UUID, UUID)? in
            guard let id = next.previous, let previous = sources[id], next.continuesDrive(from: previous) else { return nil }
            return (next.routeID, id)
        })
        let candidates = AutomaticVisitBoundary.candidates(in: sources, continuing: continuing, calendar: calendar)
        for candidate in candidates.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard candidate.isConfirmed else { gaps.append(candidate); continue }
            let before = candidate.sourceArrivalID.flatMap { byRoute[$0]?.last }
            let after = candidate.sourceDepartureID.flatMap { byRoute[$0]?.first }
            var start = candidate.startedAt
            var end = candidate.endedAt
            // Independently named observations retain their own edit owner.
            for edge in [before, after].compactMap({ $0 }) where edge.visitName == nil && edge.hasMemory != true {
                guard edge.coordinate.location.distance(from: candidate.coordinate.location) <= RouteReview.placeRadius,
                      edge.endedAt == candidate.startedAt || edge.startedAt == candidate.endedAt,
                      incorporated.insert(edge.id).inserted else { continue }
                observedEdges[candidate.id, default: []].append(edge)
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

    func sharedTripKeys(_ routes: [(UUID, [RouteReviewEntry])]) -> [RouteMemoryKey: RouteMemoryKey] {
        guard !continuing.isEmpty else { return [:] }
        let trips = Dictionary(uniqueKeysWithValues: routes)
        var links: [RouteMemoryKey: RouteMemoryKey] = [:]
        for (next, previous) in continuing {
            guard let tail = trips[previous]?.max(by: { $0.endedAt < $1.endedAt })?.memoryKey,
                  let head = trips[next]?.min(by: { $0.startedAt < $1.startedAt })?.memoryKey else { continue }
            links[head] = tail
        }
        var resolved: [RouteMemoryKey: RouteMemoryKey] = [:]
        for key in links.keys where resolved[key] == nil {
            var path = Set<RouteMemoryKey>()
            var first = key
            while let previous = links[first], path.insert(first).inserted {
                if let known = resolved[previous] { first = known; break }
                first = previous
            }
            for part in path { resolved[part] = first }
        }
        return resolved
    }

    /// Join only explicitly linked neighbours, keeping every recorded geometry break.
    func joinDriveLegs<T>(_ items: [(UUID?, T)], start: KeyPath<T, Date>, combine: (T, T) -> T?) -> [T] {
        var result: [T] = []
        var previousOwner: UUID?
        for (owner, item) in items.sorted(by: { $0.1[keyPath: start] < $1.1[keyPath: start] }) {
            if let owner, let previousOwner, continuing[owner] == previousOwner,
               let index = result.indices.last, let joined = combine(result[index], item) {
                result[index] = joined
            } else {
                result.append(item)
            }
            previousOwner = owner
        }
        return result
    }

    func journeys(_ items: [(UUID?, RouteJourney)]) -> [RouteJourney] {
        joinDriveLegs(items, start: \.departedAt) { first, next in
            let durations = first.modeDurations.merging(next.modeDurations, uniquingKeysWith: +)
            return RouteJourney(id: first.id, endpoints: first.endpoints.continuing(to: next.endpoints), departedAt: first.departedAt,
                                duration: next.departedAt.addingTimeInterval(next.duration).timeIntervalSince(first.departedAt),
                                mode: RouteJourney.dominantMode(in: durations), departureStay: first.departureStay,
                                arrivalStay: next.arrivalStay, modeDurations: durations)
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

/// A Today-only inference. The archive continues to own every observation and editable entry.
struct TodayPlaceStay: Identifiable {
    var id: Date { startedAt }
    private(set) var startedAt: Date
    let name: String?
    var end: Date?
    private let center: CLLocationCoordinate2D
    private var lastSeen: Date
    private let session: Date?

    private func contains(_ point: LocationPoint<PersistentIdentifier>, places: RoutePlaceSnapshot) -> Bool {
        guard center.location.distance(from: point.fix) <= RouteReview.placeRadius else { return false }
        if let other = places.savedPlace(near: point.coordinate) {
            return other.center.latitude == center.latitude && other.center.longitude == center.longitude
        }
        return name == nil
    }

    private mutating func observe(_ run: ArraySlice<LocationPoint<PersistentIdentifier>>,
                                  places: RoutePlaceSnapshot) -> Bool {
        let nearby = run.prefix { contains($0, places: places) }
        if let last = nearby.last { lastSeen = last.timestamp }
        return nearby.endIndex == run.endIndex
    }

    private init?(run: ArraySlice<LocationPoint<PersistentIdentifier>>, places: RoutePlaceSnapshot,
                  session: Date?, stopped: Bool, legacyEnd: Bool) {
        guard let first = run.first, let last = run.last else { return nil }
        let place = places.savedPlace(near: last.coordinate)
        guard stopped || (legacyEnd && place != nil) else { return nil }
        self.session = session
        name = place?.name
        center = place?.center ?? last.coordinate
        lastSeen = last.timestamp
        startedAt = last.timestamp
        if run.allSatisfy({ contains($0, places: places) }) { startedAt = first.timestamp }
    }

    @MainActor fileprivate static func project(
        routes: [RecordedRoute], now: Date, calendar: Calendar, places: RoutePlaceSnapshot, activeSession: Date?,
        slicesFor: (RecordedRoute) -> [SegmentBuilder.Slice<PersistentIdentifier>]
    ) -> [Self] {
        let midnight = calendar.startOfDay(for: now)
        var result: [Self] = []
        var pending: Self?

        func finish() {
            if var stay = pending, stay.lastSeen >= midnight,
               stay.lastSeen.timeIntervalSince(stay.startedAt) >= AutomaticTrips.shortStop {
                stay.end = stay.lastSeen
                result.append(stay)
            }
            pending = nil
        }

        // Follow same-place recordings back past midnight to find the original arrival.
        let current = routes.prefix { $0.startedAt >= midnight }
        var relevant = Array(current)
        var overnightPlace: Self?
        for route in routes.dropFirst(current.count) {
            guard route.isAutomatic == true else { break }
            let slices = slicesFor(route)
            guard let tail = slices.last?.points.suffix(1) else { break }
            if overnightPlace == nil {
                overnightPlace = Self(run: tail, places: places, session: route.automaticSessionStart,
                                      stopped: true, legacyEnd: false)
            }
            guard let overnightPlace else { break }
            if let session = overnightPlace.session, route.startedAt < session { break }
            relevant.append(route)
            if route.arrivalDecision == "ignored" || !slices.allSatisfy({ slice in
                slice.points.allSatisfy { overnightPlace.contains($0, places: places) }
            }) { break }
        }
        for route in relevant.reversed() {
            guard route.isAutomatic == true else { finish(); continue }
            // Early automatic routes predate the session field. Link only when their time is
            // covered by the same switch-on as the next recording.
            if let previous = pending, let session = route.automaticSessionStart,
               previous.session.map({ $0 != session }) ?? (previous.startedAt < session) {
                finish()
            }
            if route.arrivalDecision == "ignored" { finish() }
            let slices = slicesFor(route)
            for (index, slice) in slices.enumerated() {
                let points = slice.points
                var start = points.startIndex
                while start < points.endIndex {
                    let next = points[(start + 1)...].firstIndex { $0.startsRecordingRun == true } ?? points.endIndex
                    let run = points[start..<next]
                    if pending?.observe(run, places: places) == false { finish() }
                    if pending == nil {
                        let final = index == slices.count - 1 && next == points.endIndex
                        let pausedHere = next < points.endIndex && run.last?.mode == .stationary
                        pending = Self(run: run, places: places, session: route.automaticSessionStart,
                                       stopped: slice.visitCoordinate != nil || pausedHere || (final && route.endedAtRest == true),
                                       legacyEnd: final && route.isFinished && route.endedAtRest == nil)
                    }
                    start = next
                }
            }
        }
        if let stay = pending, let activeSession, stay.startedAt >= activeSession,
           stay.session == nil || stay.session == activeSession, stay.lastSeen <= now {
            result.append(stay)
        } else { finish() }
        return result
    }
}
