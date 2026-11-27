import CoreLocation
import Foundation

struct RouteInsights {
    struct FrequentRoute: Identifiable {
        let pattern: RouteBehavior.RoutePattern
        let count: Int
        let average: TimeInterval
        let fastest: TimeInterval
        let slowest: TimeInterval

        var id: RouteBehavior.RoutePattern.ID { pattern.id }
    }

    struct CommuteChange {
        let pattern: RouteBehavior.RoutePattern
        let average: TimeInterval
        let previousAverage: TimeInterval
        let sampleCount: Int
        let previousSampleCount: Int
        let fastestSample: RouteBehavior.TravelSample
    }

    struct HomeShare {
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
        now: Date = .now, patterns: [RouteBehavior.RoutePattern], hasHome: Bool,
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
                let origin = category(pattern.start)
                let destination = category(pattern.end)
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
            let prior = calendar.date(byAdding: .day, value: -30, to: start).flatMap { priorStart in
                calendar.date(byAdding: .day, value: -1, to: start).flatMap { priorEnd in
                    Self.recordedHomeShare(RouteAnalytics(
                        summary: summary, range: priorStart...priorEnd, calendar: calendar, now: start, category: category
                    ))
                }
            }
            home = HomeShare(share: share, trackedDuration: analytics.trackedDuration,
                             elapsedDuration: analytics.elapsedDuration, previousShare: prior)
        } else {
            home = nil
        }
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
