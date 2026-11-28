import CoreLocation
import Foundation
import SwiftData

struct RouteBehavior: Sendable {
    enum RoutineKind: String, CaseIterable, Identifiable, Sendable {
        case departure = "首次离家"
        case arrival = "末次回家"

        var id: Self { self }
    }

    struct RoutinePoint: Identifiable, Sendable {
        struct ID: Hashable {
            let day: Date
            let kind: RoutineKind
        }

        let day: Date
        let kind: RoutineKind
        let time: Date
        let clockHour: Double

        var id: ID { ID(day: day, kind: kind) }
    }

    struct TravelSample: Sendable {
        let departedAt: Date
        let arrivedAt: Date?
        let startingHour: Int
        let duration: TimeInterval
    }

    struct HourlyTravel: Identifiable {
        let hour: Int
        let count: Int
        let fastest: TimeInterval
        let slowest: TimeInterval
        let median: TimeInterval

        var id: Int { hour }
    }

    struct RoutePattern: Identifiable, Sendable {
        let id: PersistentIdentifier
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let mode: TravelMode
        var startName: String?
        var endName: String?
        fileprivate(set) var samples: [TravelSample]

        var byHour: [HourlyTravel] {
            Dictionary(grouping: samples, by: \.startingHour).map { hour, samples in
                let times = samples.map(\.duration).sorted()
                let median = (times[times.count / 2] + times[(times.count - 1) / 2]) / 2
                return HourlyTravel(hour: hour, count: times.count, fastest: times[0], slowest: times[times.count - 1], median: median)
            }
            .sorted { $0.hour < $1.hour }
        }

        var shorterDepartureWindow: HourlyTravel? {
            let comparable = byHour.filter { $0.count >= 2 }.sorted { $0.median < $1.median }
            guard comparable.count > 1, comparable[0].median < comparable[1].median else { return nil }
            return comparable[0]
        }
    }

    let patterns: [RoutePattern]
    let routine: [RoutinePoint]

    private struct PatternGroup {
        var pattern: RoutePattern
        let start: CLLocation
        let end: CLLocation
    }

    init(review: RouteReview, range: ClosedRange<Date>, calendar: Calendar, category: (CLLocationCoordinate2D) -> PlaceCategory?) {
        self.init(summary: RouteSummary(review: review), range: range, calendar: calendar, category: category)
    }

    init(summary: RouteSummary, range: ClosedRange<Date>, calendar: Calendar, category: (CLLocationCoordinate2D) -> PlaceCategory?) {
        var homeTimes: [RoutinePoint.ID: Date] = [:]
        for journey in summary.journeys {
            for (kind, connection) in [(RoutineKind.departure, journey.departureStay), (.arrival, journey.arrivalStay)] {
                let corrected = kind == .departure ? journey.endpoints.startName : journey.endpoints.endName
                guard corrected == nil, let connection else { continue }
                let date = calendar.startOfDay(for: connection.time)
                guard range.contains(date), category(connection.coordinate) == .home else { continue }
                let key = RoutinePoint.ID(day: date, kind: kind)
                let previous = homeTimes[key] ?? connection.time
                homeTimes[key] = kind == .departure ? min(previous, connection.time) : max(previous, connection.time)
            }
        }
        patterns = Self.routePatterns(
            in: summary.journeys.filter { range.contains(calendar.startOfDay(for: $0.departedAt)) },
            calendar: calendar
        )
        routine = homeTimes.map { key, time in
            let hour = Double(calendar.component(.hour, from: time)) + Double(calendar.component(.minute, from: time)) / 60
            return RoutinePoint(day: key.day, kind: key.kind, time: time, clockHour: hour)
        }.sorted { $0.time < $1.time }
    }

    static func routePatterns(in journeys: [RouteJourney], calendar: Calendar) -> [RoutePattern] {
        var trips: [PatternGroup] = []
        for journey in journeys.sorted(by: { $0.departedAt < $1.departedAt }) {
            guard !Task.isCancelled else { return [] }
            let startLocation = journey.endpoints.start.location
            let endLocation = journey.endpoints.end.location
            guard startLocation.distance(from: endLocation) > RouteReview.placeRadius else { continue }
            let sample = TravelSample(departedAt: journey.departedAt, arrivedAt: journey.arrivalStay?.time,
                                      startingHour: calendar.component(.hour, from: journey.departedAt), duration: journey.duration)
            let nearest = trips.indices.lazy.compactMap { index -> (index: Int, distance: CLLocationDistance)? in
                let group = trips[index]
                guard group.pattern.mode == journey.mode, group.pattern.startName == journey.endpoints.startName,
                      group.pattern.endName == journey.endpoints.endName else { return nil }
                let a = startLocation.distance(from: group.start)
                guard a <= RouteReview.placeRadius else { return nil }
                let b = endLocation.distance(from: group.end)
                guard b <= RouteReview.placeRadius else { return nil }
                return (index, a + b)
            }.min { $0.distance < $1.distance }
            if let nearest {
                trips[nearest.index].pattern.samples.append(sample)
            } else {
                let pattern = RoutePattern(
                    id: journey.id, start: journey.endpoints.start, end: journey.endpoints.end,
                    mode: journey.mode, startName: journey.endpoints.startName, endName: journey.endpoints.endName, samples: [sample]
                )
                trips.append(PatternGroup(pattern: pattern, start: startLocation, end: endLocation))
            }
        }
        return trips.compactMap { $0.pattern.samples.count > 1 ? $0.pattern : nil }
            .sorted { $0.samples.count > $1.samples.count }
    }
}
