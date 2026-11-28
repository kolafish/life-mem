import CoreLocation
import Foundation

enum RouteTimeUse: String, CaseIterable, Identifiable, Sendable {
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

struct RouteAnalysisRequest: Hashable, Sendable {
    struct Scope: Hashable, Sendable {
        let summaryID: UUID
        let placesRevision: UUID
        let calendar: Calendar
        let range: ClosedRange<Date>
    }

    let scope: Scope
    let now: Date
}

struct RouteAnalysisReport: Sendable {
    let scope: RouteAnalysisRequest.Scope
    let analytics: RouteAnalytics
    let behavior: RouteBehavior?
    let insights: RouteInsights?
    let placesByVisits: [RouteAnalytics.PlaceRank]
    let placesByDuration: [RouteAnalytics.PlaceRank]
    let placeNumbers: [RouteVisit.ID: Int]
}

actor RouteAnalysisWorker {
    private struct History {
        let summaryID: UUID
        let calendar: Calendar
        let patterns: [RouteBehavior.RoutePattern]
    }

    private struct Period {
        let scope: RouteAnalysisRequest.Scope
        let behavior: RouteBehavior
        let priorHomeShare: Double?
    }

    private var history: History?
    private var period: Period?
    private var previous: (request: RouteAnalysisRequest, report: RouteAnalysisReport)?

    func report(for request: RouteAnalysisRequest, summary: RouteSummary, places: RoutePlaceSnapshot) -> RouteAnalysisReport? {
        guard !Task.isCancelled else { return nil }
        if let previous, previous.request == request { return previous.report }

        let scope = request.scope
        let data = RouteAnalytics(summary: summary, range: scope.range, calendar: scope.calendar, now: request.now, category: places.category(for:))
        var behavior: RouteBehavior?
        var insights: RouteInsights?
        if data.trackedDuration > 0 {
            guard !Task.isCancelled else { return nil }
            let hasHome = places.hasCategory(.home)
            let period: Period
            if let cached = self.period, cached.scope == scope {
                period = cached
            } else {
                let behavior = RouteBehavior(summary: summary, range: scope.range, calendar: scope.calendar, category: places.category(for:))
                let priorShare = hasHome ? RouteInsights.homeShareBefore(scope.range.lowerBound, summary: summary,
                                                                        calendar: scope.calendar, category: places.category(for:)) : nil
                guard !Task.isCancelled else { return nil }
                period = Period(scope: scope, behavior: behavior, priorHomeShare: priorShare)
                self.period = period
            }

            let patterns: [RouteBehavior.RoutePattern]
            if let history, history.summaryID == scope.summaryID, history.calendar == scope.calendar {
                patterns = history.patterns
            } else {
                patterns = RouteInsights.routePatterns(in: summary.journeys, calendar: scope.calendar)
                guard !Task.isCancelled else { return nil }
                history = History(summaryID: scope.summaryID, calendar: scope.calendar, patterns: patterns)
            }
            behavior = period.behavior
            insights = RouteInsights(summary: summary, analytics: data, range: scope.range, calendar: scope.calendar, now: request.now,
                                     patterns: patterns, hasHome: hasHome, priorHomeShare: period.priorHomeShare, category: places.category(for:))
        }

        guard !Task.isCancelled else { return nil }
        let result = RouteAnalysisReport(
            scope: scope, analytics: data, behavior: behavior, insights: insights,
            placesByVisits: data.topPlaces(by: .visits), placesByDuration: data.topPlaces(by: .duration),
            placeNumbers: Dictionary(uniqueKeysWithValues: data.places.enumerated().map { ($0.element.id, $0.offset + 1) })
        )
        previous = (request, result)
        return result
    }
}

struct RouteAnalytics: Sendable {
    enum PlaceRanking: String, CaseIterable, Identifiable {
        case visits = "到访次数"
        case duration = "停留时长"

        var id: Self { self }
    }

    struct TimeBucket: Identifiable, Sendable {
        let use: RouteTimeUse
        let seconds: TimeInterval

        var id: RouteTimeUse { use }
    }

    struct Day: Identifiable, Sendable {
        let date: Date
        let time: [TimeBucket]

        var id: Date { date }
    }

    struct PlaceRank: Identifiable, Sendable {
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
            var seconds = Self.coverage(summariesByDate[day], during: elapsed, category: category) { visit, duration in
                durationByVisit[visit.visitID, default: 0] += duration
            }
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

    static func homeShare(in summary: RouteSummary, range: ClosedRange<Date>, calendar: Calendar,
                          category: (CLLocationCoordinate2D) -> PlaceCategory?) -> Double? {
        var tracked: TimeInterval = 0
        var home: TimeInterval = 0
        for day in summary.days where range.contains(day.date) {
            guard let interval = calendar.dateInterval(of: .day, for: day.date) else { continue }
            let seconds = coverage(day, during: interval, category: category) { _, _ in }
            home += seconds[.home, default: 0]
            tracked += seconds.values.reduce(0, +)
        }
        return tracked > 0 ? home / tracked : nil
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

    private static func coverage(_ summary: DailySummary?, during elapsed: DateInterval,
                                 category: (CLLocationCoordinate2D) -> PlaceCategory?,
                                 onStay: (StayEvent, TimeInterval) -> Void) -> [RouteTimeUse: TimeInterval] {
        guard let summary else { return [:] }
        var observations = summary.movement.compactMap { item in
            clip(item, to: elapsed).map { Observation(use: .moving, interval: $0) }
        }
        for stay in summary.stays.sorted(by: { $0.startedAt < $1.startedAt }) where stay.duration > 0 {
            let span = DateInterval(start: stay.startedAt, end: stay.endedAt)
            guard let observed = clip(span, to: elapsed) else { continue }
            observations.append(Observation(use: RouteTimeUse(category: stay.visitName == nil ? category(stay.coordinate) : nil), interval: observed))
            onStay(stay, observed.duration)
        }
        return observedTime(observations)
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
