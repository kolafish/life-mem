import CoreLocation
import Foundation

struct RouteInsights: Sendable {
    struct FrequentRoute: Identifiable, Sendable {
        let pattern: RouteBehavior.RoutePattern
        let count: Int
        let average: TimeInterval
        let fastest: TimeInterval
        let slowest: TimeInterval

        var id: RouteBehavior.RoutePattern.ID { pattern.id }
    }

    struct CommuteChange: Sendable {
        let pattern: RouteBehavior.RoutePattern
        let average: TimeInterval
        let previousAverage: TimeInterval
        let sampleCount: Int
        let previousSampleCount: Int
        let fastestSample: RouteBehavior.TravelSample
    }

    struct HomeShare: Sendable {
        let share: Double
        let trackedDuration: TimeInterval
        let elapsedDuration: TimeInterval
        let previousShare: Double?
    }

    let newPlaceCount: Int
    let home: HomeShare?
    let commute: CommuteChange?
    let routes: [FrequentRoute]

    init(
        summary: RouteSummary, analytics: RouteAnalytics, range: ClosedRange<Date>, calendar: Calendar,
        now: Date = .now, patterns: [RouteBehavior.RoutePattern], hasHome: Bool, priorHomeShare: Double?,
        category: (CLLocationCoordinate2D) -> PlaceCategory?
    ) {
        let start = calendar.startOfDay(for: range.lowerBound)
        let fullEnd = calendar.dateInterval(of: .day, for: range.upperBound)?.end ?? range.upperBound
        let end = min(fullEnd, now)
        guard end > start else {
            newPlaceCount = 0
            home = nil
            commute = nil
            routes = []
            return
        }
        let current = DateInterval(start: start, end: end)
        let dayCount = calendar.dateComponents([.day], from: start, to: fullEnd).day ?? 0
        let previous = calendar.date(byAdding: .day, value: -dayCount, to: start).flatMap { previousStart in
            calendar.date(byAdding: .day, value: -dayCount, to: end).flatMap { previousEnd -> DateInterval? in
                guard previousStart < previousEnd else { return nil }
                return DateInterval(start: previousStart, end: min(start, previousEnd))
            }
        }
        let compared = patterns.compactMap { pattern -> (RouteBehavior.RoutePattern, [RouteBehavior.TravelSample])? in
            let samples = Self.completedSamples(pattern.samples, departingIn: current, asOf: now)
            return samples.count >= 2 ? (pattern, samples) : nil
        }.sorted { $0.1.count > $1.1.count }

        routes = compared.prefix(5).compactMap { pattern, samples in
            let history = pattern.samples.compactMap { sample in
                sample.arrivedAt.map { $0 <= now } == true ? sample.duration : nil
            }
            guard let fastest = history.min(), let slowest = history.max() else { return nil }
            return FrequentRoute(pattern: pattern, count: samples.count, average: Self.average(samples),
                                 fastest: fastest, slowest: slowest)
        }

        commute = previous.flatMap { interval in
            compared.compactMap { pattern, samples -> CommuteChange? in
                let origin = pattern.startName == nil ? category(pattern.start) : nil
                let destination = pattern.endName == nil ? category(pattern.end) : nil
                guard (origin == .home && destination == .work) || (origin == .work && destination == .home) else { return nil }
                let earlier = Self.completedSamples(pattern.samples, departingIn: interval, asOf: now)
                guard earlier.count >= 2, let fastest = samples.min(by: { $0.duration < $1.duration }) else { return nil }
                return CommuteChange(pattern: pattern, average: Self.average(samples), previousAverage: Self.average(earlier),
                                     sampleCount: samples.count, previousSampleCount: earlier.count, fastestSample: fastest)
            }.first
        }

        newPlaceCount = summary.places.filter { place in
            guard let visit = place.visits.first else { return false }
            return visit.startedAt >= current.start && visit.startedAt < current.end
        }.count

        if hasHome, let share = Self.recordedHomeShare(analytics) {
            home = HomeShare(share: share, trackedDuration: analytics.trackedDuration,
                             elapsedDuration: analytics.elapsedDuration, previousShare: priorHomeShare)
        } else {
            home = nil
        }
    }

    static func homeShareBefore(_ start: Date, summary: RouteSummary, calendar: Calendar,
                                category: (CLLocationCoordinate2D) -> PlaceCategory?) -> Double? {
        guard let priorStart = calendar.date(byAdding: .day, value: -30, to: start),
              let priorEnd = calendar.date(byAdding: .day, value: -1, to: start) else { return nil }
        return RouteAnalytics.homeShare(in: summary, range: priorStart...priorEnd, calendar: calendar, category: category)
    }

    static func routePatterns(in journeys: [RouteJourney], calendar: Calendar) -> [RouteBehavior.RoutePattern] {
        let complete = journeys.filter { $0.departureStay != nil && $0.arrivalStay != nil }
        return RouteBehavior.routePatterns(in: complete, calendar: calendar)
    }

    private static func completedSamples(
        _ samples: [RouteBehavior.TravelSample], departingIn interval: DateInterval, asOf now: Date
    ) -> [RouteBehavior.TravelSample] {
        samples.filter { sample in
            guard let arrivedAt = sample.arrivedAt else { return false }
            return sample.departedAt >= interval.start && sample.departedAt < interval.end && arrivedAt <= now
        }
    }

    private static func average(_ samples: [RouteBehavior.TravelSample]) -> TimeInterval {
        samples.reduce(0) { $0 + $1.duration } / Double(samples.count)
    }

    private static func recordedHomeShare(_ analytics: RouteAnalytics) -> Double? {
        guard analytics.trackedDuration > 0 else { return nil }
        let home = analytics.time.first { $0.use == .home }?.seconds ?? 0
        return home / analytics.trackedDuration
    }
}

struct WeeklyVisits: Sendable {
    struct Week: Identifiable, Sendable {
        let start: Date
        let visits: [RouteVisit] // The first arrival on each distinct local day.
        var id: Date { start }
    }

    struct Place: Identifiable, Sendable {
        let place: RoutePlace
        let ordinal: Int
        let current: Week
        let history: [Week]
        var id: RoutePlace.ID { place.id }

        var usualDays: Double? {
            guard history.count == 4 else { return nil }
            let counts = history.map { $0.visits.count }.sorted()
            return Double(counts[1] + counts[2]) / 2
        }
    }

    let places: [Place]

    init(summary: RouteSummary, calendar: Calendar, now: Date) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now), week.start < now else {
            places = []
            return
        }
        let wallTime: Set<Calendar.Component> = [.hour, .minute, .second]
        let windows = (0...4).compactMap { offset -> DateInterval? in
            guard let end = calendar.date(byAdding: .weekOfYear, value: -offset, to: now),
                  calendar.dateComponents(wallTime, from: end) == calendar.dateComponents(wallTime, from: now),
                  let start = calendar.dateInterval(of: .weekOfYear, for: end)?.start, start < end else { return nil }
            return DateInterval(start: start, end: end)
        }
        guard let current = windows.first else { places = []; return }
        let days = Dictionary(uniqueKeysWithValues: summary.days.map { ($0.date, $0) })
        func dailyCoverage(_ window: DateInterval) -> [[DateInterval]] {
            var result: [[DateInterval]] = []
            var day = window.start
            while day < window.end, let next = calendar.dateInterval(of: .day, for: day)?.end {
                let interval = DateInterval(start: day, end: min(next, window.end))
                result.append(RouteAnalytics.observedIntervals(days[day], during: interval))
                day = next
            }
            return result
        }
        let observed = dailyCoverage(current)
        let comparable = windows.count == 5 && windows.dropFirst().enumerated().allSatisfy { index, window in
            let history = dailyCoverage(window)
            guard history.count == observed.count else { return false }
            return zip(observed, history).allSatisfy { a, b in
                let longest = max(a.reduce(0) { $0 + $1.duration }, b.reduce(0) { $0 + $1.duration })
                let historical = b.compactMap { span -> DateInterval? in
                    guard let begin = calendar.date(byAdding: .weekOfYear, value: index + 1, to: span.start),
                          let end = calendar.date(byAdding: .weekOfYear, value: index + 1, to: span.end), begin < end,
                          calendar.dateComponents(wallTime, from: begin) == calendar.dateComponents(wallTime, from: span.start),
                          calendar.dateComponents(wallTime, from: end) == calendar.dateComponents(wallTime, from: span.end),
                          abs(end.timeIntervalSince(begin) - span.duration) < 1
                    else { return nil }
                    return DateInterval(start: begin, end: end)
                }
                guard historical.count == b.count,
                      zip(historical, historical.dropFirst()).allSatisfy({ $0.end <= $1.start })
                else { return false }
                var overlap = 0.0, i = 0, j = 0
                while i < a.count && j < historical.count {
                    let left = a[i], right = historical[j]
                    overlap += max(0, min(left.end, right.end).timeIntervalSince(max(left.start, right.start)))
                    if left.end <= right.end { i += 1 } else { j += 1 }
                }
                return overlap >= 15 * 60 && overlap >= longest / 2
            }
        }
        func slice(_ place: RoutePlace, in interval: DateInterval) -> Week {
            var seen = Set<Date>()
            let visits = place.visits.filter { visit in
                visit.startedAt >= interval.start && visit.startedAt < interval.end &&
                    seen.insert(calendar.startOfDay(for: visit.startedAt)).inserted
            }
            return Week(start: interval.start, visits: visits)
        }
        places = summary.places.enumerated().compactMap { index, place -> Place? in
            let recent = slice(place, in: current)
            let previous = comparable ? windows.dropFirst().map { slice(place, in: $0) } : []
            let item = Place(place: place, ordinal: index + 1, current: recent, history: previous)
            guard !recent.visits.isEmpty || (item.usualDays ?? 0) > 0 else { return nil }
            return item
        }.sorted {
            let lhs = Double($0.current.visits.count), rhs = Double($1.current.visits.count)
            let changeA = abs(lhs - ($0.usualDays ?? lhs)), changeB = abs(rhs - ($1.usualDays ?? rhs))
            if changeA != changeB { return changeA > changeB }
            if lhs != rhs { return lhs > rhs }
            return $0.place.mostRecentVisit.startedAt > $1.place.mostRecentVisit.startedAt
        }
    }
}
