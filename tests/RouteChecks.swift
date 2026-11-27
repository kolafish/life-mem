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
        precondition(driving.assess(location(longitude: 0, at: start, accuracy: 51), after: nil, mode: .automotive) == nil)
        let flyaway = location(longitude: 0.03, at: start.addingTimeInterval(5))
        precondition(driving.assess(flyaway, after: first, mode: .automotive, previousMode: .stationary) == nil)
        let heartbeat = LocationSampling(mode: .unknown).assess(stayEnd, after: stayStart, mode: .unknown)
        precondition(heartbeat?.distance == 0 && heartbeat?.startsNewSegment == false)

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
        try checkSemanticTimeline(context: context)
        try checkPlaceNames(in: root)
        print("Passed sampling, persistence, deletion, daily review, visit grouping, and place name checks.")
    }

    @MainActor
    private static func checkSemanticTimeline(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let homeEnd = 8 * 3_600
        let walkEnd = homeEnd + 600
        let driveEnd = walkEnd + 1_200
        let workStart = driveEnd + 30
        let route = RecordedRoute(startedAt: day)
        context.insert(route)

        func add(_ seconds: Int, longitude: Double, mode: TravelMode, accuracy: Double = 5, boundary: Bool = false) {
            context.insert(RoutePoint(
                location: location(longitude: longitude, at: day.addingTimeInterval(Double(seconds)), accuracy: accuracy),
                mode: mode,
                startsNewSegment: boundary || seconds == homeEnd,
                startsRecordingRun: boundary,
                route: route
            ))
        }

        for seconds in stride(from: 0, to: homeEnd, by: 30) {
            let drift = seconds == homeEnd - 30 ? 0 : Double((seconds / 30) % 5 - 2) * 0.0001
            if seconds == 4 * 3_600 {
                add(seconds, longitude: 0.00072, mode: .stationary, accuracy: 45)
            } else {
                add(seconds, longitude: drift, mode: seconds % 60 == 0 ? .unknown : .stationary)
            }
        }
        add(301, longitude: 0.04, mode: .unknown, accuracy: 70)
        add(601, longitude: 0.04, mode: .unknown)
        for seconds in stride(from: homeEnd, through: walkEnd, by: 30) {
            add(seconds, longitude: Double(seconds - homeEnd) * 0.00001, mode: seconds == homeEnd ? .walking : .unknown)
        }
        for seconds in stride(from: walkEnd + 30, through: driveEnd, by: 30) {
            add(seconds, longitude: 0.006 + Double(seconds - walkEnd) * 0.00012, mode: .automotive)
        }
        for seconds in stride(from: workStart, through: workStart + 4 * 3_600, by: 30) {
            add(seconds, longitude: 0.15, mode: .stationary)
        }
        // Resuming in a different motion state still starts a new observation run.
        add(workStart + 4 * 3_600 + 20, longitude: 0.151, mode: .walking, boundary: true)
        try context.save()

        let review = RouteReview(routes: [route], calendar: calendar)
        let entries = review.days[0].entries
        let events = review.days[0].timeline
        guard events.count == 4,
              case let .stay(home) = events[0],
              case let .move(walk) = events[1],
              case let .move(drive) = events[2],
              case let .stay(work) = events[3] else {
            preconditionFailure("Expected home, walk, drive, work.")
        }
        precondition(abs(home.coordinate.longitude) < 0.00001)
        precondition(home.duration == Double(homeEnd - 30) && work.duration == 4 * 3_600)
        precondition(walk.mode == .walking && walk.duration == 600)
        precondition(drive.mode == .automotive && drive.duration == 1_200)
        let expected = location(longitude: 0, at: day).distance(from: location(longitude: 0.15, at: day))
        precondition(abs(walk.distanceMeters + drive.distanceMeters - expected) < 5)
        precondition(entries.last?.kind == .fragment && entries.last?.followsGap == true)

        let shortTrip = insertRoute(context: context, start: day, samples: stop(start: 0, longitude: 0) + [
            (510, 0.002, .automotive, true)
        ] + stop(start: 540, longitude: 0.004))
        let shortTimeline = RouteReview(routes: [shortTrip], calendar: calendar).days[0].timeline
        guard shortTimeline.count == 3, case let .move(move) = shortTimeline[1] else {
            preconditionFailure("A single moving sample should retain both observed edges.")
        }
        precondition(move.mode == .automotive && move.duration == 60 && move.distanceMeters > 440)
        precondition(move.coordinates.first?.longitude == 0 && move.coordinates.last?.longitude == 0.004)
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
                (655, 0.0099, .walking, true),
                (670, 0.0096, .walking, false),
                (690, 0.0003, .automotive, false),
                (705, 0.0, .walking, false),
                (730, 0.03, .walking, true),
                (745, 0.0302, .walking, false),
                (880, 0.04, .walking, false),
                (895, 0.0402, .walking, false)
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
        precondition(today[0].segments.map(\.mode) == [.walking, .automotive, .stationary, .automotive])
        precondition(today[1].endedAt.timeIntervalSince(today[1].startedAt) == 480)
        precondition(today[0].endpoints?.start.longitude == 0)
        precondition(today[0].endpoints?.end.longitude == destination)
        precondition(today[1].visitCoordinate?.longitude == destination)
        precondition(today[2].endpoints?.start.longitude == destination)
        precondition(today[2].endpoints?.end.longitude == 0)
        precondition(today[3].endpoints?.start.longitude == 0.03)
        precondition(today[2].segments.last?.coordinates.last?.longitude == 0)
        precondition(today[0].segments.first?.coordinates.first?.longitude == 0)
        precondition(today.filter(\.followsGap).map(\.startedAt) == [morning.addingTimeInterval(730), morning.addingTimeInterval(880)])
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
        precondition(beforeMidnight[1].endpoints?.end.longitude == 0.0002)
        precondition(afterMidnight[1].endpoints?.start.longitude == 0.0004)
        precondition(afterMidnight[0].startedAt == nextDay)
        precondition(beforeMidnight[0].endedAt == nextDay)
        precondition(afterMidnight[0].stay?.visitID == beforeMidnight[0].stay?.visitID)
        precondition((afterMidnight[0].stay?.duration ?? 0) + (beforeMidnight[0].stay?.duration ?? 0) == 480)
        precondition(midnightReview.places[0].mostRecentVisit.id == beforeMidnight[0].id)
    }

    @MainActor
    private static func checkPlaceNames(in directory: URL) throws {
        let file = directory.appending(path: "place-names.json")
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let nearby = CLLocationCoordinate2D(latitude: 0, longitude: 0.0002)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 0.0100)
        let names = RoutePlaceNames(file: file)
        precondition(names.name(for: start) == nil)
        try names.save(" 河滨公园 ", for: start)
        try names.save("市图书馆", for: end)
        precondition(names.name(for: nearby) == "河滨公园")

        let reopened = RoutePlaceNames(file: file)
        precondition(reopened.name(for: end) == "市图书馆")
        try reopened.save("公园入口", for: nearby)
        precondition(reopened.name(for: start) == "公园入口")
        try reopened.save(nil, for: start)
        let afterRemoval = RoutePlaceNames(file: file)
        precondition(afterRemoval.name(for: nearby) == nil)
        precondition(afterRemoval.name(for: end) == "市图书馆")

        let invalidFile = directory.appending(path: "invalid-place-names.json")
        let invalid = Data("incomplete".utf8)
        try invalid.write(to: invalidFile)
        let invalidStore = RoutePlaceNames(file: invalidFile)
        do {
            try invalidStore.save("测试名称", for: start)
            preconditionFailure("Saving must not replace a place-name file that could not be loaded.")
        } catch {
            let persisted = try Data(contentsOf: invalidFile)
            precondition(persisted == invalid)
        }
    }

    private typealias Sample = (seconds: TimeInterval, longitude: Double, mode: TravelMode, newSegment: Bool)

    private static func stop(start: TimeInterval, longitude: Double) -> [Sample] {
        stride(from: 0, through: 480, by: 30).map {
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

    private static func location(longitude: Double, at timestamp: Date, accuracy: Double = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            timestamp: timestamp
        )
    }
}
