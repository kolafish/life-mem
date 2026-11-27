import CoreLocation
import Foundation
import SwiftData

struct RouteBehavior {
    enum RoutineKind: String, CaseIterable, Identifiable {
        case departure = "首次离家"
        case arrival = "末次回家"

        var id: Self { self }
    }

    struct RoutinePoint: Identifiable {
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

    struct TravelSample {
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

    struct RoutePattern: Identifiable {
        let id: PersistentIdentifier
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let mode: TravelMode
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

    init(review: RouteReview, range: ClosedRange<Date>, calendar: Calendar, category: (CLLocationCoordinate2D) -> PlaceCategory?) {
        self.init(summary: RouteSummary(review: review), range: range, calendar: calendar, category: category)
    }

    init(summary: RouteSummary, range: ClosedRange<Date>, calendar: Calendar, category: (CLLocationCoordinate2D) -> PlaceCategory?) {
        var trips: [RoutePattern] = []
        var homeTimes: [RoutinePoint.ID: Date] = [:]
        for journey in summary.journeys.sorted(by: { $0.departedAt < $1.departedAt }) {
            for (kind, connection) in [(RoutineKind.departure, journey.departureStay), (.arrival, journey.arrivalStay)] {
                guard let connection, category(connection.coordinate) == .home else { continue }
                let date = calendar.startOfDay(for: connection.time)
                guard range.contains(date) else { continue }
                let key = RoutinePoint.ID(day: date, kind: kind)
                let previous = homeTimes[key] ?? connection.time
                homeTimes[key] = kind == .departure ? min(previous, connection.time) : max(previous, connection.time)
            }

            let departureDay = calendar.startOfDay(for: journey.departedAt)
            guard range.contains(departureDay) else { continue }
            let startLocation = Self.location(journey.endpoints.start)
            let endLocation = Self.location(journey.endpoints.end)
            guard startLocation.distance(from: endLocation) > RouteReview.placeRadius else { continue }
            let sample = TravelSample(startingHour: calendar.component(.hour, from: journey.departedAt), duration: journey.duration)
            let nearest = trips.indices.lazy.compactMap { index -> (index: Int, distance: CLLocationDistance)? in
                guard trips[index].mode == journey.mode else { return nil }
                let a = startLocation.distance(from: Self.location(trips[index].start))
                let b = endLocation.distance(from: Self.location(trips[index].end))
                guard max(a, b) <= RouteReview.placeRadius else { return nil }
                return (index, a + b)
            }.min { $0.distance < $1.distance }
            if let nearest {
                trips[nearest.index].samples.append(sample)
            } else {
                trips.append(RoutePattern(
                    id: journey.id, start: journey.endpoints.start, end: journey.endpoints.end,
                    mode: journey.mode, samples: [sample]
                ))
            }
        }
        patterns = trips.filter { $0.samples.count > 1 }.sorted {
            $0.samples.count > $1.samples.count
        }
        routine = homeTimes.map { key, time in
            let hour = Double(calendar.component(.hour, from: time)) + Double(calendar.component(.minute, from: time)) / 60
            return RoutinePoint(day: key.day, kind: key.kind, time: time, clockHour: hour)
        }.sorted { $0.time < $1.time }
    }

    private static func location(_ coordinate: CLLocationCoordinate2D) -> CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
