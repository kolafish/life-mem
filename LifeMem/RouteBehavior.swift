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
        var trips: [RoutePattern] = []
        var routinePoints: [RoutinePoint] = []
        for day in review.days.reversed() where range.contains(day.date) {
            var departure: Date?
            var arrival: Date?
            for entry in day.entries where entry.kind == .trip {
                let moves = entry.moves
                guard let first = moves.first, let last = moves.last, let endpoints = entry.endpoints else { continue }
                let start = first.startedAt
                let end = last.endedAt
                let seconds = end.timeIntervalSince(start)
                guard seconds > 0 else { continue }

                if let place = entry.departureStay, category(place) == .home {
                    departure = min(departure ?? start, start)
                }
                if let place = entry.arrivalStay, category(place) == .home {
                    arrival = max(arrival ?? end, end)
                }
                let startLocation = Self.location(endpoints.start)
                let endLocation = Self.location(endpoints.end)
                guard startLocation.distance(from: endLocation) > RouteReview.placeRadius else { continue }
                let sample = TravelSample(startingHour: calendar.component(.hour, from: start), duration: seconds)
                let durations = moves.reduce(into: [TravelMode: TimeInterval]()) { $0[$1.mode, default: 0] += $1.duration }
                let mode = TravelMode.allCases.max { durations[$0, default: 0] < durations[$1, default: 0] } ?? .unknown
                let nearest = trips.indices.lazy.compactMap { index -> (index: Int, distance: CLLocationDistance)? in
                    guard trips[index].mode == mode else { return nil }
                    let a = startLocation.distance(from: Self.location(trips[index].start))
                    let b = endLocation.distance(from: Self.location(trips[index].end))
                    guard max(a, b) <= RouteReview.placeRadius else { return nil }
                    return (index, a + b)
                }.min { $0.distance < $1.distance }
                if let nearest {
                    trips[nearest.index].samples.append(sample)
                } else {
                    trips.append(RoutePattern(id: entry.id, start: endpoints.start, end: endpoints.end, mode: mode, samples: [sample]))
                }
            }

            for (kind, time) in [(RoutineKind.departure, departure), (.arrival, arrival)] {
                guard let time else { continue }
                let hour = Double(calendar.component(.hour, from: time)) + Double(calendar.component(.minute, from: time)) / 60
                routinePoints.append(RoutinePoint(day: day.date, kind: kind, time: time, clockHour: hour))
            }
        }
        patterns = trips.filter { $0.samples.count > 1 }.sorted {
            $0.samples.count > $1.samples.count
        }
        routine = routinePoints
    }

    private static func location(_ coordinate: CLLocationCoordinate2D) -> CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
