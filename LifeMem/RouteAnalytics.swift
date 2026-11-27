import CoreLocation
import Foundation

enum RouteTimeUse: String, CaseIterable, Identifiable {
    case home, work, moving, leisure, exercise, other, untracked

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "居家"
        case .work: "工作／学习"
        case .moving: "出行"
        case .leisure: "餐饮休闲"
        case .exercise: "运动"
        case .other: "其他停留"
        case .untracked: "未记录"
        }
    }

    init(category: PlaceCategory?) {
        switch category {
        case .home: self = .home
        case .work: self = .work
        case .dining, .shopping, .leisure: self = .leisure
        case .exercise: self = .exercise
        case .other, nil: self = .other
        }
    }
}

struct RouteAnalytics {
    enum PlaceRanking: String, CaseIterable, Identifiable {
        case visits = "到访次数"
        case duration = "停留时长"

        var id: Self { self }
    }

    struct TimeBucket: Identifiable {
        let use: RouteTimeUse
        let seconds: TimeInterval

        var id: RouteTimeUse { use }
    }

    struct Day: Identifiable {
        let date: Date
        let time: [TimeBucket]

        var id: Date { date }
    }

    struct PlaceRank: Identifiable {
        let place: RoutePlace
        let visits: Int
        let seconds: TimeInterval

        var id: RoutePlace.ID { place.id }
    }

    let days: [Day]
    let time: [TimeBucket]
    let places: [PlaceRank]

    var trackedDuration: TimeInterval {
        time.filter { $0.use != .untracked }.reduce(0) { $0 + $1.seconds }
    }

    var elapsedDuration: TimeInterval { time.reduce(0) { $0 + $1.seconds } }

    init(
        review: RouteReview, range: ClosedRange<Date>, calendar: Calendar,
        now: Date = .now, category: (CLLocationCoordinate2D) -> PlaceCategory?
    ) {
        self.init(summary: RouteSummary(review: review), range: range, calendar: calendar, now: now, category: category)
    }

    init(
        summary: RouteSummary, range: ClosedRange<Date>, calendar: Calendar,
        now: Date = .now, category: (CLLocationCoordinate2D) -> PlaceCategory?
    ) {
        let summariesByDate = Dictionary(uniqueKeysWithValues: summary.days.map { ($0.date, $0) })
        var totals: [RouteTimeUse: TimeInterval] = [:]
        var durationByVisit: [RouteVisit.ID: TimeInterval] = [:]
        var days: [Day] = []
        var day = calendar.startOfDay(for: range.lowerBound)
        let lastDay = min(calendar.startOfDay(for: range.upperBound), calendar.startOfDay(for: now))
        while day <= lastDay, day < now, let interval = calendar.dateInterval(of: .day, for: day) {
            let elapsed = DateInterval(start: day, end: min(interval.end, now))
            let summary = summariesByDate[day]
            var observations = (summary?.movement ?? []).compactMap { item in
                Self.clip(item, to: elapsed).map { Observation(use: .moving, interval: $0) }
            }
            for stay in (summary?.stays ?? []).sorted(by: { $0.startedAt < $1.startedAt }) where stay.duration > 0 {
                let span = DateInterval(start: stay.startedAt, end: stay.endedAt)
                guard let observed = Self.clip(span, to: elapsed) else { continue }
                observations.append(Observation(use: RouteTimeUse(category: category(stay.coordinate)), interval: observed))
                durationByVisit[stay.visitID, default: 0] += observed.duration
            }
            var seconds = Self.observedTime(observations)
            seconds[.untracked] = max(0, elapsed.duration - seconds.values.reduce(0, +))
            for (use, duration) in seconds { totals[use, default: 0] += duration }
            days.append(Day(date: day, time: Self.buckets(seconds)))
            day = interval.end
        }
        self.days = days
        time = Self.buckets(totals)
        places = summary.places.compactMap { place in
            let visitDurations = place.visits.compactMap { durationByVisit[$0.id] }
            guard !visitDurations.isEmpty else { return nil }
            return PlaceRank(place: place, visits: visitDurations.count, seconds: visitDurations.reduce(0, +))
        }
    }

    func topPlaces(by ranking: PlaceRanking) -> [PlaceRank] {
        let sorted = places.sorted { first, second in
            switch ranking {
            case .visits:
                return first.visits != second.visits ? first.visits > second.visits : first.seconds > second.seconds
            case .duration:
                return first.seconds != second.seconds ? first.seconds > second.seconds : first.visits > second.visits
            }
        }
        return Array(sorted.prefix(10))
    }

    private struct Observation {
        let use: RouteTimeUse
        let interval: DateInterval
    }

    private struct Boundary {
        let time: Date
        let observation: Int
        let starts: Bool
    }

    private static func clip(_ interval: DateInterval, to window: DateInterval) -> DateInterval? {
        let start = max(interval.start, window.start)
        let end = min(interval.end, window.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func observedTime(_ observations: [Observation]) -> [RouteTimeUse: TimeInterval] {
        let boundaries = observations.enumerated().flatMap { index, item in
            [Boundary(time: item.interval.start, observation: index, starts: true),
             Boundary(time: item.interval.end, observation: index, starts: false)]
        }.sorted { $0.time < $1.time }
        var active: Set<Int> = []
        var totals: [RouteTimeUse: TimeInterval] = [:]
        var previous = boundaries.first?.time
        for boundary in boundaries {
            // Movement precedes stays. Overlapping stays prefer the first observation.
            if let previous, let assigned = active.min() {
                totals[observations[assigned].use, default: 0] += boundary.time.timeIntervalSince(previous)
            }
            if boundary.starts {
                active.insert(boundary.observation)
            } else {
                active.remove(boundary.observation)
            }
            previous = boundary.time
        }
        return totals
    }

    private static func buckets(_ seconds: [RouteTimeUse: TimeInterval]) -> [TimeBucket] {
        RouteTimeUse.allCases.compactMap { use in
            guard let count = seconds[use], count > 0 else { return nil }
            return TimeBucket(use: use, seconds: count)
        }
    }
}
