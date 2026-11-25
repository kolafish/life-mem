import CoreLocation
import Foundation
import SwiftData

@main
struct RouteChecks {
    @MainActor
    static func main() throws {
        let start = Date.now
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
        precondition(TravelMode.allCases.filter { route.matches(travelMode: $0) } == [.walking, .automotive])
        let savedSegments = route.activitySegments
        precondition(savedSegments.map(\.mode) == [.walking, .automotive])
        precondition(savedSegments.map(\.startedAt) == [first.timestamp, afterGap.timestamp])
        precondition(savedSegments.map(\.endedAt) == [nearby.timestamp, afterGap.timestamp])
        precondition(savedSegments.map { $0.coordinates.count } == [2, 1])
        context.delete(route)
        try context.save()
        let remainingPoints = try context.fetchCount(FetchDescriptor<RoutePoint>())
        precondition(remainingPoints == 0)

        let newRoute = RecordedRoute(startedAt: start)
        context.insert(newRoute)
        precondition(!newRoute.matches(travelMode: .unknown))
        context.insert(RoutePoint(location: first, mode: .unknown, startsNewSegment: true, route: newRoute))
        newRoute.pointCount += 1
        try context.save()
        precondition(TravelMode.allCases.filter { newRoute.matches(travelMode: $0) } == [.unknown])

        context.insert(RoutePoint(location: farther, mode: .cycling, startsNewSegment: false, route: newRoute))
        newRoute.pointCount += 1
        try context.save()
        precondition(TravelMode.allCases.filter { newRoute.matches(travelMode: $0) } == [.cycling])

        context.insert(RoutePoint(location: stayStart, mode: .stationary, startsNewSegment: true, route: newRoute))
        context.insert(RoutePoint(location: stayEnd, mode: .stationary, startsNewSegment: false, route: newRoute))
        newRoute.pointCount += 2
        try context.save()
        let segments = newRoute.activitySegments
        precondition(segments.map(\.mode) == [.unknown, .cycling, .stationary])
        precondition(segments[1].startedAt == farther.timestamp && segments[1].startCoordinate.longitude == farther.coordinate.longitude)
        precondition(segments[1].coordinates.count == 2)
        precondition(segments[2].startedAt == stayStart.timestamp && segments[2].endedAt == stayEnd.timestamp)
        precondition(segments[2].coordinates.count == 1)
        let places = RoutePlace.group(segments + savedSegments)
        precondition(places.map { $0.segments.count } == [4, 1])
        precondition(places[1].segments[0].mode == .automotive)
        print("Passed adaptive sampling, route persistence and deletion, activity times, and place grouping checks.")
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
