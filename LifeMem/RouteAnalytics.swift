import CoreLocation
import Foundation

enum RouteTimeUse: String, CaseIterable, Identifiable {
    case home, work, moving, leisure, exercise, other

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "居家"
        case .work: "工作／学习"
        case .moving: "出行"
        case .leisure: "餐饮休闲"
        case .exercise: "运动"
        case .other: "其他停留"
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

    init(review: RouteReview, range: ClosedRange<Date>, category: (CLLocationCoordinate2D) -> PlaceCategory?) {
        self.init(summary: RouteSummary(review: review), range: range, category: category)
    }

    init(summary: RouteSummary, range: ClosedRange<Date>, category: (CLLocationCoordinate2D) -> PlaceCategory?) {
        var totals: [RouteTimeUse: TimeInterval] = [:]
        var durationByVisit: [RouteVisit.ID: TimeInterval] = [:]
        days = summary.days.reversed().filter { range.contains($0.date) }.map { day in
            var recorded: [RouteTimeUse: TimeInterval] = [.moving: day.movingDuration]
            for stay in day.stays where stay.duration > 0 {
                recorded[RouteTimeUse(category: category(stay.coordinate)), default: 0] += stay.duration
                durationByVisit[stay.visitID, default: 0] += stay.duration
            }
            for (use, seconds) in recorded { totals[use, default: 0] += seconds }
            return Day(date: day.date, time: Self.buckets(recorded))
        }
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

    private static func buckets(_ seconds: [RouteTimeUse: TimeInterval]) -> [TimeBucket] {
        RouteTimeUse.allCases.compactMap { use in
            guard let count = seconds[use], count > 0 else { return nil }
            return TimeBucket(use: use, seconds: count)
        }
    }
}
