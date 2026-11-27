import CoreLocation
import Foundation
import SwiftData

@main
struct RouteChecks {
    @MainActor
    static func main() async throws {
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
        let savedSegments = SegmentBuilder.group(sortedPoints: points.map(\.locationPoint))
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
        let segments = SegmentBuilder.group(sortedPoints: newRoute.points.sorted { $0.timestamp < $1.timestamp }.map(\.locationPoint))
        precondition(segments.map(\.mode) == [.unknown, .cycling, .stationary])
        precondition(segments[1].startedAt == farther.timestamp && segments[1].startCoordinate.longitude == farther.coordinate.longitude)
        precondition(segments[1].coordinates.count == 2)
        precondition(segments[2].startedAt == stayStart.timestamp && segments[2].endedAt == stayEnd.timestamp)
        precondition(segments[2].coordinates.count == 1)
        checkPureSegmentBuilder(at: start)
        try checkReview(context: context)
        checkCoverageDates()
        try checkRouteReviewCache(context: context)
        try checkSemanticTimeline(context: context)
        try checkBehavior(context: context)
        try checkPlaceSuggestions(context: context)
        try checkPlaceNames(in: root)
        try await checkSummaryIndex(context: context, directory: root)
        try await checkPlaceResolver(in: root)
        print("Passed sampling, persistence, deletion, daily review, visit grouping, and place name checks.")
    }

    private static func checkPureSegmentBuilder(at start: Date) {
        let points = (0...16).map { index in
            LocationPoint(id: index, timestamp: start.addingTimeInterval(Double(index) * 30),
                          coordinate: .init(latitude: 0, longitude: 0), accuracy: 5,
                          mode: .unknown, startsNewSegment: index == 0, startsRecordingRun: index == 0)
        }
        let split = LocationPoint(id: 17, timestamp: start.addingTimeInterval(540),
                                  coordinate: .init(latitude: 0, longitude: 0.001), accuracy: 5,
                                  mode: .walking, startsNewSegment: true, startsRecordingRun: true)
        let runs = SegmentBuilder.build([split] + points.reversed())
        precondition(runs.count == 2 && runs.allSatisfy { $0.count == 1 })
        precondition(runs[0][0].visitCoordinate?.longitude == 0)
        precondition(runs[0][0].points.first?.id == 0 && runs[0][0].points.last?.id == 16)
        precondition(runs[1][0].visitCoordinate == nil && runs[1][0].points.first?.id == 17)
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
        precondition(abs(review.days[0].movingDistanceMeters - expected) < 5)
        precondition(review.days[0].movingDuration == 1_800 && review.days[0].stays.count == 2)
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

        let bothDays = RouteAnalytics(review: midnightReview, range: day...nextDay, calendar: calendar, now: nextDay.addingTimeInterval(86_400)) { _ in .home }
        precondition(bothDays.days.map(\.date) == [day, nextDay])
        precondition(bothDays.time.first { $0.use == .home }?.seconds == 420)
        precondition(bothDays.time.first { $0.use == .moving }?.seconds == 60)
        precondition(bothDays.elapsedDuration == 2 * 86_400 && bothDays.trackedDuration == 480)
        precondition(bothDays.time.first { $0.use == .untracked }?.seconds == 2 * 86_400 - 480)
        precondition(midnightReview.days.allSatisfy { $0.movingDuration == 30 })
        precondition(bothDays.places.count == 1 && bothDays.places[0].visits == 1 && bothDays.places[0].seconds == 480)
        let onlyNextDay = RouteAnalytics(review: midnightReview, range: nextDay...nextDay, calendar: calendar, now: nextDay.addingTimeInterval(86_400)) { _ in nil }
        precondition(onlyNextDay.time.first { $0.use == .other }?.seconds == 330)
        precondition(onlyNextDay.places[0].visits == 1 && onlyNextDay.places[0].seconds == 360)

        let midnightEdge = insertRoute(context: context, start: nextDay.addingTimeInterval(-10), samples: [
            (0, 0, .walking, true), (20, 0.0002, .walking, false)
        ])
        let midnightOnly = RouteReview(routes: [midnightEdge], calendar: calendar)
        precondition(midnightOnly.days.allSatisfy { $0.movingDuration == 10 && $0.movingDistanceMeters > 10 })

        let longVisit = insertRoute(context: context, start: morning, samples: stride(from: 0, through: 1_200, by: 30).map {
            (Double($0), 0.05, .stationary, $0 == 0)
        })
        let rankedReview = RouteReview(routes: [outing, repeatedVisit, longVisit], calendar: calendar)
        let ranked = RouteAnalytics(review: rankedReview, range: previousDay...day, calendar: calendar, now: nextDay) { _ in nil }
        precondition(ranked.topPlaces(by: .visits).first?.visits == 2)
        precondition(ranked.topPlaces(by: .duration).first?.seconds == 1_200)
    }

    private static func checkCoverageDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let empty = RouteSummary(records: [])
        for (month, day, length) in [(3, 8, 23), (11, 1, 25)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let next = calendar.date(byAdding: .day, value: 1, to: date)!
            let analytics = RouteAnalytics(summary: empty, range: date...date, calendar: calendar, now: next) { _ in nil }
            precondition(analytics.days.count == 1 && analytics.elapsedDuration == Double(length * 3_600))
            precondition(analytics.time.count == 1 && analytics.time[0].use == .untracked)
        }
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let now = today.addingTimeInterval(4_321)
        let analytics = RouteAnalytics(summary: empty, range: today...tomorrow, calendar: calendar, now: now) { _ in nil }
        precondition(analytics.days.map(\.date) == [today] && analytics.elapsedDuration == 4_321)
        let future = RouteAnalytics(summary: empty, range: tomorrow...tomorrow, calendar: calendar, now: now) { _ in nil }
        precondition(future.days.isEmpty && future.elapsedDuration == 0)
    }

    @MainActor
    private static func checkRouteReviewCache(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_006_400))
        let nextDate = calendar.date(byAdding: .day, value: 1, to: date)!
        let walk = insertRoute(context: context, start: date.addingTimeInterval(23 * 3_600), samples: [
            (0, 0, .walking, true), (30, 0.0003, .walking, false)
        ])
        let stay = insertRoute(context: context, start: nextDate.addingTimeInterval(3_600), samples: stop(start: 0, longitude: 0.01))
        try context.save()

        let cache = RouteReviewCache()
        let original = cache.review(routes: [walk, stay], calendar: calendar)
        precondition(original.days.map(\.date) == [nextDate, date] && original.days[1].movingDuration == 30)
        let secondReader = cache.review(routes: [walk, stay], calendar: calendar)
        precondition(secondReader.days.flatMap(\.entries).map(\.id) == original.days.flatMap(\.entries).map(\.id))

        let fix = location(longitude: 0.0006, at: walk.startedAt.addingTimeInterval(60))
        context.insert(RoutePoint(location: fix, mode: .walking, startsNewSegment: false, startsRecordingRun: false, route: walk))
        walk.pointCount += 1
        try context.save()
        let afterAppend = cache.review(routes: [walk, stay], calendar: calendar)
        precondition(afterAppend.days[1].movingDuration == 60)
        precondition(afterAppend.places[0].visits[0].id == original.places[0].visits[0].id)

        context.delete(walk)
        try context.save()
        let afterDeletion = cache.review(routes: [stay], calendar: calendar)
        precondition(afterDeletion.days.map(\.date) == [nextDate] && afterDeletion.journeys.isEmpty)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3_600)!
        let shifted = cache.review(routes: [stay], calendar: calendar)
        precondition(shifted.days[0].date == calendar.startOfDay(for: stay.startedAt) && shifted.days[0].date != nextDate)

        let previousDefault = NSTimeZone.default
        defer { NSTimeZone.default = previousDefault }
        let automatic = Calendar.autoupdatingCurrent
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        let beforeChange = cache.review(routes: [stay], calendar: automatic)
        NSTimeZone.default = TimeZone(identifier: "Pacific/Honolulu")!
        let afterChange = cache.review(routes: [stay], calendar: automatic)
        precondition(afterChange.days[0].date == automatic.startOfDay(for: stay.startedAt))
        precondition(beforeChange.days[0].date != afterChange.days[0].date)
    }

    @MainActor
    private static func checkSummaryIndex(context: ModelContext, directory: URL) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_006_400))
        let next = calendar.date(byAdding: .day, value: 1, to: start)!
        let walk = insertRoute(context: context, start: next.addingTimeInterval(-30), samples: [
            (0, 0, .walking, true), (20, 0.0003, .walking, false),
            (40, 0.0006, .walking, false), (60, 0.0009, .walking, false)
        ])
        let stay = insertRoute(context: context, start: next.addingTimeInterval(-120), samples: stop(start: 0, longitude: 0.01))
        try context.save()
        let routes = [walk, stay]
        let original = RouteReview(routes: routes, calendar: calendar)
        let cache = RouteReviewCache()
        let revision = RouteReviewRevision(calendar: calendar, routes: routes)
        let file = directory.appending(path: "daily-summary.json")
        let index = RouteSummaryIndex(file: file)
        let records = cache.summaries(for: routes, revision: revision, indexed: [:])
        await index.save(records, for: revision)

        let reopened = RouteSummaryIndex(file: file)
        let loaded = await reopened.records(for: revision)
        let summary = RouteSummary(records: revision.routes.compactMap { loaded[$0] })
        precondition(loaded.count == 2 && summary.days.map(\.movingDuration) == original.days.map(\.movingDuration))
        precondition(summary.places.map(\.id) == original.places.map(\.id))
        precondition(summary.journeys.map(\.duration) == original.journeys.map(\.duration))
        precondition(summary.days.flatMap(\.stays).map(\.visitID) == original.days.flatMap(\.stays).map(\.visitID))

        let fix = location(longitude: 0.0012, at: walk.startedAt.addingTimeInterval(80))
        context.insert(RoutePoint(location: fix, mode: .walking, startsNewSegment: false, route: walk))
        walk.pointCount += 1
        try context.save()
        let changed = RouteReviewRevision(calendar: calendar, routes: routes)
        let retained = await reopened.records(for: changed)
        precondition(retained.count == 1 && retained[changed.routes[1]] != nil)
        let updated = RouteReviewCache().summaries(for: routes, revision: changed, indexed: retained)
        let afterAppend = RouteSummary(records: changed.routes.compactMap { updated[$0] })
        precondition(afterAppend.days.map(\.movingDuration) == [50, 30])

        let afterDeletion = RouteReviewRevision(calendar: calendar, routes: [stay])
        try await reopened.prepareToDelete(routeID: walk.id)
        await reopened.save(records, for: revision)
        let surviving = await reopened.records(for: afterDeletion)
        await reopened.save(surviving, for: afterDeletion)
        let pruned = await RouteSummaryIndex(file: file).records(for: revision)
        precondition(pruned.count == 1 && pruned[revision.routes[0]] == nil)

        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let shifted = await reopened.records(for: RouteReviewRevision(calendar: calendar, routes: [stay]))
        precondition(shifted.isEmpty)
        try Data("invalid".utf8).write(to: file)
        let corrupt = await RouteSummaryIndex(file: file).records(for: revision)
        precondition(corrupt.isEmpty)
    }

    @MainActor
    private static func checkBehavior(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        var routes: [RecordedRoute] = []
        for index in 0..<4 {
            let hour = index < 2 ? 8 : 9
            let day = calendar.date(byAdding: .day, value: index, to: firstDay)!
            let start = calendar.date(byAdding: .hour, value: hour, to: day)!
            let transit = index < 2 ? 120 : 240
            let outbound: [Sample] = stride(from: 30, to: transit, by: 30).map { offset in
                (480 + Double(offset), (offset == 30 ? 0.0002 : 0.01 * Double(offset) / Double(transit)), offset == 30 ? .walking : .automotive, offset == 30)
            }
            let arrive = 480 + Double(transit)
            var samples = stop(start: 0, longitude: 0) + outbound + stop(start: arrive, longitude: 0.01)
            if index == 0 {
                samples += [(arrive + 510, 0.005, .automotive, true)]
                    + stop(start: arrive + 540, longitude: 0)
            }
            routes.append(insertRoute(context: context, start: start, samples: samples))
        }
        let lastDay = calendar.date(byAdding: .day, value: 4, to: firstDay)!
        let disconnected = stop(start: 0, longitude: 0) + [
            (510, 0.001, .walking, true), (540, 0.002, .walking, false)
        ]
        let pausedRoute = insertRoute(context: context, start: lastDay, samples: disconnected)
        for point in pausedRoute.points where point.timestamp == lastDay.addingTimeInterval(510) {
            point.startsRecordingRun = true
        }
        routes.append(pausedRoute)
        let walkingDay = calendar.date(byAdding: .day, value: 1, to: lastDay)!
        var walking: [Sample] = []
        for offset in stride(from: 510, to: 1_080, by: 30) {
            let longitude = Double(offset - 480) / 60_000
            walking.append((Double(offset), longitude, .walking, offset == 510))
        }
        routes.append(insertRoute(context: context, start: walkingDay,
                                  samples: stop(start: 0, longitude: 0) + walking + stop(start: 1_080, longitude: 0.01)))
        try context.save()

        let review = RouteReview(routes: routes, calendar: calendar)
        let behavior = RouteBehavior(review: review, range: firstDay...walkingDay, calendar: calendar) { coordinate in
            abs(coordinate.longitude) < 0.0005 ? .home : .work
        }
        precondition(behavior.patterns.count == 1 && behavior.patterns[0].samples.count == 4)
        let commute = behavior.patterns[0]
        precondition(commute.byHour.map(\.hour) == [8, 9])
        precondition(commute.byHour.map(\.median) == [120, 240])
        precondition(commute.mode == .automotive && commute.shorterDepartureWindow?.hour == 8)
        precondition(behavior.routine.filter { $0.kind == .departure }.count == 5)
        precondition(behavior.routine.filter { $0.kind == .arrival }.count == 1)
        precondition(behavior.routine.allSatisfy { $0.day != lastDay })

        let sparse = RouteBehavior(review: review, range: firstDay...firstDay, calendar: calendar) { _ in nil }
        precondition(sparse.patterns.isEmpty && sparse.routine.isEmpty)

        let midnight = firstDay.addingTimeInterval(86_400)
        let otherMidnight = midnight.addingTimeInterval(86_400)
        let acrossMidnight: [Sample] = [
            (0, 0.03, .automotive, true), (40, 0.031, .automotive, false),
            (60, 0.032, .automotive, false), (100, 0.033, .automotive, false)
        ]
        let repeatedOvernight = [midnight, otherMidnight].map {
            insertRoute(context: context, start: $0.addingTimeInterval(-50), samples: acrossMidnight)
        }
        let midnightDeparture = insertRoute(
            context: context, start: midnight.addingTimeInterval(-490),
            samples: stop(start: 0, longitude: 0) + [(500, 0.0004, .walking, true), (520, 0.0006, .walking, false)]
        )
        let midnightArrival = insertRoute(
            context: context, start: midnight.addingTimeInterval(-40),
            samples: [(0, 0.001, .walking, true), (30, 0.0004, .walking, false)] + stop(start: 50, longitude: 0)
        )
        try context.save()
        let overnightReview = RouteReview(routes: repeatedOvernight + [midnightDeparture, midnightArrival], calendar: calendar)
        let overnightEfficiency = RouteBehavior(review: overnightReview, range: firstDay...otherMidnight, calendar: calendar) { _ in nil }
        precondition(overnightEfficiency.patterns.count == 1)
        precondition(overnightEfficiency.patterns[0].samples.map(\.duration) == [100, 100])
        let overnightRoutine = RouteBehavior(review: overnightReview, range: midnight...midnight, calendar: calendar) {
            abs($0.longitude) < 0.0001 ? .home : nil
        }
        precondition(Set(overnightRoutine.routine.map(\.kind)) == [.departure, .arrival])
        precondition(overnightRoutine.routine.allSatisfy { $0.day == midnight && $0.time == midnight.addingTimeInterval(10) })
    }

    @MainActor
    private static func checkPlaceSuggestions(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let weekday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        let route = insertRoute(context: context, start: weekday,
                                samples: (0..<8).map { (Double($0 * 10), 0, .unknown, $0 == 0) })
        try context.save()
        let ids = route.points.map(\.persistentModelID)
        var visits: [RouteVisit] = []
        for index in 0..<4 {
            let day = calendar.date(byAdding: .day, value: index, to: weekday)!
            let midnight = day.addingTimeInterval(-3_600)
            visits.append(RouteVisit(id: ids[index], date: calendar.startOfDay(for: midnight),
                                     startedAt: midnight, endedAt: day.addingTimeInterval(7 * 3_600),
                                     coordinate: .init(latitude: 0, longitude: 0)))
            let work = day.addingTimeInterval(11 * 3_600)
            visits.append(RouteVisit(id: ids[index + 4], date: day, startedAt: work,
                                     endedAt: work.addingTimeInterval(3_600), coordinate: .init(latitude: 0, longitude: 0.02)))
        }
        let places = RoutePlace.group(visits, within: RouteReview.placeRadius)
        let now = calendar.date(byAdding: .day, value: 5, to: weekday)!
        let suggestions = PlaceSuggestions.candidates(in: places, calendar: calendar, now: now) { _ in nil }
        precondition(suggestions.map(\.category) == [.home, .work] && suggestions.allSatisfy { $0.observedDays == 4 })
        let confirmed = PlaceSuggestions.candidates(in: places, calendar: calendar, now: now) {
            $0.longitude == 0 ? .home : nil
        }
        precondition(confirmed.map(\.category) == [.work])
        let sparse = PlaceSuggestions.candidates(in: places, calendar: calendar, now: weekday.addingTimeInterval(3_600)) { _ in nil }
        precondition(sparse.isEmpty)

        let weekend = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 11))!
        let weekends = [0, 7, 14].enumerated().map { index, offset in
            let time = calendar.date(byAdding: .day, value: offset, to: weekend)!
            return RouteVisit(id: ids[index], date: calendar.startOfDay(for: time),
                              startedAt: time, endedAt: time.addingTimeInterval(3_600),
                              coordinate: .init(latitude: 0, longitude: 0.04))
        }
        let weekendPlaces = RoutePlace.group(weekends, within: RouteReview.placeRadius)
        let weekendOnly = PlaceSuggestions.candidates(in: weekendPlaces, calendar: calendar, now: now) { _ in nil }
        precondition(weekendOnly.isEmpty)
    }

    @MainActor
    private static func checkPlaceNames(in directory: URL) throws {
        let file = directory.appending(path: "place-names.json")
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let nearby = CLLocationCoordinate2D(latitude: 0, longitude: 0.0002)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 0.0100)
        let legacy = Data(#"[{"name":"旧版地点","latitude":0,"longitude":0}]"#.utf8)
        try legacy.write(to: file)
        let names = RoutePlaceNames(file: file)
        precondition(names.name(for: start) == "旧版地点" && names.category(for: start) == nil)
        try names.save(" 河滨公园 ", category: .leisure, for: start)
        try names.save("市图书馆", for: end)
        precondition(names.name(for: nearby) == "河滨公园")

        let reopened = RoutePlaceNames(file: file)
        precondition(reopened.name(for: end) == "市图书馆")
        precondition(reopened.category(for: nearby) == .leisure)
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

    @MainActor
    private static func checkPlaceResolver(in directory: URL) async throws {
        let suite = "LifeMemTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = directory.appending(path: "place-suggestions.json")
        let names = RoutePlaceNames(file: directory.appending(path: "test-aliases.json"))
        let place = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let neighbor = CLLocationCoordinate2D(latitude: 0, longitude: 0.00012)
        let anotherPlace = CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
        var requests = 0
        let resolver = PlaceResolver(file: file, defaults: defaults) { _, _ in
            requests += 1
            return .init(MapPlaceSuggestion(pointOfInterestNames: ["市图书馆"], streetOrArea: "书院路", district: nil, city: nil))
        }
        await resolver.resolveAutomatically(near: place, names: names)
        precondition(requests == 0)
        resolver.setAutomaticEnabled(true)
        await resolver.resolveAutomatically(near: place, names: names)
        await resolver.resolveAutomatically(near: neighbor, names: names)
        precondition(requests == 1)
        precondition(resolver.label(near: neighbor, names: names) == "市图书馆附近")
        try names.save("最喜欢的图书馆", category: .leisure, for: place)
        try names.save("家", category: .home, for: anotherPlace)
        await resolver.resolveAutomatically(near: anotherPlace, names: names)
        precondition(requests == 1)
        precondition(resolver.label(near: neighbor, names: names) == "最喜欢的图书馆")
        resolver.setAutomaticEnabled(false)
        let reopened = PlaceResolver(file: file, defaults: defaults) { _, _ in .init(nil) }
        precondition(!reopened.isAutomaticEnabled)
        precondition(reopened.cached(near: neighbor)?.candidates == ["市图书馆", "书院路附近"])
        try reopened.clearCache()
        let cleared = PlaceResolver(file: file, defaults: defaults) { _, _ in .init(nil) }
        precondition(cleared.cached(near: neighbor) == nil)
        precondition(cleared.label(near: neighbor, names: names) == "最喜欢的图书馆")

        let clock = ContinuousClock()
        var starts: [ContinuousClock.Instant] = []
        let coordinated = PlaceResolver(file: file, defaults: defaults, minimumInterval: .milliseconds(40)) { _, _ in
            starts.append(clock.now)
            try await Task.sleep(for: .milliseconds(20))
            return .init(MapPlaceSuggestion(pointOfInterestNames: ["合成地名"], streetOrArea: nil, district: nil, city: nil))
        }
        coordinated.setAutomaticEnabled(true)
        async let automatic = coordinated.resolve(near: place, automatic: true)
        async let manual = coordinated.resolve(near: neighbor, automatic: false)
        async let distinct = coordinated.resolve(near: anotherPlace, automatic: false)
        for result in await [automatic, manual, distinct] {
            precondition(result?.displayName == "合成地名附近")
        }
        precondition(starts.count == 2 && starts[0].duration(to: starts[1]) >= .milliseconds(40))

        enum LookupFailure: Error { case unavailable }
        var attempts = 0
        let failed = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero, initialBackoff: .milliseconds(200)) { _, _ in
            attempts += 1
            if attempts == 1 { throw LookupFailure.unavailable }
            return .init(nil)
        }
        let uncached = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let anotherUncached = CLLocationCoordinate2D(latitude: 0, longitude: 2)
        _ = await failed.resolve(near: uncached, automatic: false)
        _ = await failed.resolve(near: anotherUncached, automatic: false)
        precondition(attempts == 1)
        let cachedOffline = await failed.resolve(near: place, automatic: false)
        precondition(cachedOffline?.displayName == "合成地名附近")
        try await Task.sleep(for: .milliseconds(220))
        _ = await failed.resolve(near: uncached, automatic: false)
        _ = await failed.resolve(near: anotherUncached, automatic: false)
        precondition(attempts == 3, "A completed lookup with no match must not trigger network backoff.")

        var partialAttempts = 0
        let partial = PlaceResolver(file: directory.appending(path: "partial-suggestions.json"), defaults: defaults) { _, _ in
            partialAttempts += 1
            let suggestion = MapPlaceSuggestion(pointOfInterestNames: ["附近地名"], streetOrArea: nil, district: nil, city: nil)
            return .init(suggestion, shouldBackOff: true)
        }
        let partialResult = await partial.resolve(near: uncached, automatic: false)
        _ = await partial.resolve(near: anotherUncached, automatic: false)
        precondition(partialResult != nil && partialAttempts == 1)
        precondition(partial.cached(near: uncached) != nil)

        var finish: CheckedContinuation<Void, Never>?
        var furtherRequests = 0
        let clearing = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero) { _, checkDemand in
            await withCheckedContinuation { finish = $0 }
            try checkDemand()
            furtherRequests += 1
            return .init(MapPlaceSuggestion(pointOfInterestNames: ["过期结果"], streetOrArea: nil, district: nil, city: nil))
        }
        let pending = Task { await clearing.resolve(near: uncached, automatic: false) }
        while finish == nil { await Task.yield() }
        try clearing.clearCache()
        finish?.resume()
        let clearedPending = await pending.value
        precondition(clearedPending == nil && clearing.cached(near: uncached) == nil)

        finish = nil
        let automaticPending = Task { await clearing.resolve(near: anotherUncached, automatic: true) }
        while finish == nil { await Task.yield() }
        clearing.setAutomaticEnabled(false)
        clearing.setAutomaticEnabled(true)
        finish?.resume()
        let revokedPending = await automaticPending.value
        precondition(revokedPending == nil && clearing.cached(near: anotherUncached) == nil)

        finish = nil
        let cancelled = Task { await clearing.resolve(near: uncached, automatic: false) }
        while finish == nil { await Task.yield() }
        finish?.resume()
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil && clearing.cached(near: uncached) == nil)
        precondition(furtherRequests == 0, "Revoked demand must not start a fallback network request.")
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
