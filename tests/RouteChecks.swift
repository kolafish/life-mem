import CoreLocation
import Foundation
import SwiftData

@main
struct RouteChecks {
    @MainActor
    static func main() throws {
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3_600)
        let first = location(longitude: 0, at: start)
        let nearby = location(longitude: 0.00012, at: start.addingTimeInterval(10))
        let farther = location(longitude: 0.00060, at: start.addingTimeInterval(20))
        let stayStart = location(longitude: 0.00061, at: start.addingTimeInterval(50))
        let stayEnd = location(longitude: 0.00062, at: start.addingTimeInterval(80))
        let afterGap = location(longitude: 0.03000, at: start.addingTimeInterval(120))
        let walking = LocationSampling(mode: .walking)
        let driving = LocationSampling(mode: .automotive)
        let stationary = LocationSampling(mode: .stationary)

        precondition(walking.assess(first, after: nil, mode: .walking)?.startsNewSegment == true)
        precondition((walking.assess(nearby, after: first, mode: .walking)?.distance ?? 0) > 10)
        precondition(driving.assess(nearby, after: first, mode: .automotive) == nil)
        precondition((driving.assess(farther, after: first, mode: .automotive)?.distance ?? 0) > 60)
        precondition(stationary.assess(farther, after: first, mode: .stationary, previousMode: .walking)?.startsNewSegment == true)
        precondition(stationary.assess(farther, after: first, mode: .stationary, previousMode: .stationary) == nil)
        let stayStep = stationary.assess(stayEnd, after: stayStart, mode: .stationary, previousMode: .stationary)
        precondition(stayStep?.startsNewSegment == false && stayStep?.distance == 0)
        precondition(walking.assess(stayEnd, after: stayStart, mode: .walking, previousMode: .stationary)?.startsNewSegment == true)
        precondition(walking.assess(farther, after: farther, mode: .walking) == nil)
        precondition(driving.assess(afterGap, after: first, mode: .automotive)?.startsNewSegment == true)
        precondition(driving.assess(afterGap, after: nil, mode: .automotive)?.distance == 0)

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([RecordedRoute.self, RoutePoint.self])
        let configuration = ModelConfiguration(schema: schema, url: root.appending(path: "routes.store"), cloudKitDatabase: .none)
        try writeRoute(points: [first, nearby, afterGap], schema: schema, configuration: configuration)

        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let routes = try context.fetch(FetchDescriptor<RecordedRoute>())
        precondition(routes.count == 1)
        let route = routes[0]
        let points = route.points.sorted { $0.timestamp < $1.timestamp }
        precondition(route.pointCount == 3 && !route.isFinished)
        precondition(points.map(\.mode) == [.walking, .walking, .automotive])
        precondition(points.map(\.startsNewSegment) == [true, false, true])
        precondition(abs(route.distanceMeters - nearby.distance(from: first)) < 0.01)
        let savedSegments = RouteActivitySegment.group(sortedPoints: points)
        precondition(savedSegments.map(\.mode) == [.walking, .automotive])
        precondition(savedSegments.map(\.startedAt) == [first.timestamp, afterGap.timestamp])
        precondition(savedSegments.map(\.endedAt) == [nearby.timestamp, afterGap.timestamp])
        precondition(savedSegments.map { $0.coordinates.count } == [2, 1])
        let savedReview = RouteReview(routes: routes, calendar: .current)
        precondition(savedReview.days.flatMap(\.entries).count == 2)
        precondition(savedReview.days.flatMap(\.entries).filter(\.followsGap).count == 1)
        context.delete(route)
        try context.save()
        let remainingPoints = try context.fetchCount(FetchDescriptor<RoutePoint>())
        precondition(remainingPoints == 0)

        let newRoute = RecordedRoute(startedAt: start)
        context.insert(newRoute)
        context.insert(RoutePoint(location: first, mode: .unknown, startsNewSegment: true, route: newRoute))
        newRoute.pointCount += 1
        try context.save()

        context.insert(RoutePoint(location: farther, mode: .cycling, startsNewSegment: false, route: newRoute))
        newRoute.pointCount += 1
        try context.save()

        context.insert(RoutePoint(location: stayStart, mode: .stationary, startsNewSegment: true, route: newRoute))
        context.insert(RoutePoint(location: stayEnd, mode: .stationary, startsNewSegment: false, route: newRoute))
        newRoute.pointCount += 2
        try context.save()
        let segments = RouteActivitySegment.group(sortedPoints: newRoute.points.sorted { $0.timestamp < $1.timestamp })
        precondition(segments.map(\.mode) == [.unknown, .cycling, .stationary])
        precondition(segments[1].startedAt == farther.timestamp && segments[1].startCoordinate.longitude == farther.coordinate.longitude)
        precondition(segments[1].coordinates.count == 2)
        precondition(segments[2].startedAt == stayStart.timestamp && segments[2].endedAt == stayEnd.timestamp)
        precondition(segments[2].coordinates.count == 1)
        try checkReview(context: context)
        print("Passed sampling, persistence, deletion, activity segments, daily review, and visit grouping checks.")
    }

    @MainActor
    private static func checkReview(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let previousDay = day.addingTimeInterval(-86_400)
        let nextDay = day.addingTimeInterval(86_400)
        let morning = day.addingTimeInterval(8 * 3_600)
        let destination = 0.0100

        let outing = insertRoute(
            context: context,
            start: morning,
            samples: [
                (0, 0.0, .walking, true),
                (15, 0.0003, .walking, false),
                (30, 0.0030, .automotive, false),
                (45, 0.0040, .unknown, false),
                (60, 0.0040, .stationary, true),
                (90, 0.0040, .stationary, false),
                (110, 0.0042, .automotive, true),
                (130, 0.0099, .automotive, false)
            ] + stop(start: 150, longitude: destination) + [
                (475, 0.0099, .walking, true),
                (490, 0.0096, .walking, false),
                (510, 0.0003, .automotive, false),
                (525, 0.0, .walking, false),
                (550, 0.03, .walking, true),
                (565, 0.0302, .walking, false),
                (700, 0.04, .walking, false),
                (715, 0.0402, .walking, false)
            ]
        )
        let repeatedVisit = insertRoute(
            context: context,
            start: morning.addingTimeInterval(-86_400),
            samples: [(0, 0.0, .walking, true), (20, destination, .walking, false)]
                + stop(start: 35, longitude: destination + 0.0002)
        )
        let drift = insertRoute(
            context: context,
            start: morning.addingTimeInterval(3_600),
            samples: stride(from: 0, through: 300, by: 30).map {
                (TimeInterval($0), 0.02 + Double($0) * 0.0001, .stationary, $0 == 0)
            }
        )
        try context.save()

        let review = RouteReview(routes: [outing, repeatedVisit, drift], calendar: calendar)
        precondition(review.days.map(\.date) == [day, previousDay])
        let today = review.days[0].entries
        precondition(today.map(\.kind) == [.trip, .visit, .trip, .trip, .trip, .fragment])
        precondition(today[0].segments.map(\.mode) == [.walking, .automotive, .unknown, .stationary, .automotive])
        precondition(today[1].endedAt.timeIntervalSince(today[1].startedAt) == 300)
        precondition(today[2].segments.last?.coordinates.last?.longitude == 0)
        precondition(today[0].segments.first?.coordinates.first?.longitude == 0)
        precondition(today.filter(\.followsGap).map(\.startedAt) == [morning.addingTimeInterval(550), morning.addingTimeInterval(700)])
        precondition(today[4].segments[0].coordinates.map(\.longitude) == [0.04, 0.0402])
        precondition(review.places.map { $0.visits.count } == [2])
        precondition(review.places[0].visits.map(\.date) == [previousDay, day])
        precondition(review.places[0].mostRecentVisit.id == today[1].id)

        let crossMidnight = insertRoute(
            context: context,
            start: nextDay.addingTimeInterval(-30),
            samples: [
                (0, 0.0, .walking, true),
                (20, 0.0002, .walking, false),
                (40, 0.0004, .walking, false),
                (60, 0.0006, .walking, false)
            ]
        )
        let overnightVisit = insertRoute(
            context: context,
            start: nextDay.addingTimeInterval(-120),
            samples: stop(start: 0, longitude: 0.05)
        )
        try context.save()

        let midnightReview = RouteReview(routes: [crossMidnight, overnightVisit], calendar: calendar)
        precondition(midnightReview.days.map(\.date) == [nextDay, day])
        precondition(midnightReview.places.map { $0.visits.count } == [1])
        let afterMidnight = midnightReview.days[0].entries
        let beforeMidnight = midnightReview.days[1].entries
        precondition(afterMidnight.map(\.kind) == [.visit, .trip])
        precondition(beforeMidnight.map(\.kind) == [.visit, .trip])
        precondition(beforeMidnight[1].segments[0].coordinates.map(\.longitude) == [0.0, 0.0002])
        precondition(afterMidnight[1].segments[0].coordinates.map(\.longitude) == [0.0004, 0.0006])
        precondition(afterMidnight[0].startedAt == nextDay)
        precondition(beforeMidnight[0].endedAt < nextDay)
        precondition(midnightReview.places[0].mostRecentVisit.id == beforeMidnight[0].id)
    }

    private typealias Sample = (seconds: TimeInterval, longitude: Double, mode: TravelMode, newSegment: Bool)

    private static func stop(start: TimeInterval, longitude: Double) -> [Sample] {
        stride(from: 0, through: 300, by: 30).map {
            (start + TimeInterval($0), longitude, .stationary, $0 == 0)
        }
    }

    @MainActor
    private static func insertRoute(context: ModelContext, start: Date, samples: [Sample]) -> RecordedRoute {
        let route = RecordedRoute(startedAt: start)
        context.insert(route)
        for sample in samples {
            context.insert(RoutePoint(
                location: location(longitude: sample.longitude, at: start.addingTimeInterval(sample.seconds)),
                mode: sample.mode,
                startsNewSegment: sample.newSegment,
                route: route
            ))
        }
        route.pointCount = samples.count
        return route
    }

    @MainActor
    private static func writeRoute(points: [CLLocation], schema: Schema, configuration: ModelConfiguration) throws {
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let route = RecordedRoute(startedAt: points[0].timestamp)
        context.insert(route)
        try context.save()
        var lastPoint: CLLocation?
        for (index, location) in points.enumerated() {
            let mode: TravelMode = index < 2 ? .walking : .automotive
            let step = LocationSampling(mode: mode).assess(location, after: lastPoint, mode: mode)!
            context.insert(RoutePoint(location: location, mode: mode, startsNewSegment: step.startsNewSegment, route: route))
            route.pointCount += 1
            route.distanceMeters += step.distance
            try context.save()
            lastPoint = location
        }
    }

    private static func location(longitude: Double, at timestamp: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            timestamp: timestamp
        )
    }
}
