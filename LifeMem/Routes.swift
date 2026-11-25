import CoreLocation
import Foundation
import SwiftData

@Model
final class RecordedRoute {
    var id: UUID
    var startedAt: Date
    var isFinished: Bool
    var pointCount: Int
    var distanceMeters: Double

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.route)
    var points: [RoutePoint]

    init(startedAt: Date) {
        id = UUID()
        self.startedAt = startedAt
        isFinished = false
        pointCount = 0
        distanceMeters = 0
        points = []
    }

    func matches(travelMode mode: TravelMode) -> Bool {
        guard pointCount > 0 else { return false }
        if mode == .unknown {
            return points.allSatisfy { $0.mode == .unknown }
        }
        return points.contains { $0.mode == mode }
    }

    var activitySegments: [RouteActivitySegment] {
        guard pointCount > 0 else { return [] }
        var segments: [RouteActivitySegment] = []
        var previousPoint: RoutePoint?
        for point in points.sorted(by: { $0.timestamp < $1.timestamp }) {
            let mode = point.mode
            if let previousPoint, previousPoint.mode == mode, !point.startsNewSegment {
                let index = segments.count - 1
                segments[index].endedAt = point.timestamp
                if mode != .stationary { segments[index].coordinates.append(point.coordinate) }
            } else {
                // Keep the map line continuous across a change in travel mode.
                var coordinates: [CLLocationCoordinate2D] = []
                if let previousPoint, !point.startsNewSegment, mode != .stationary, previousPoint.mode != .stationary {
                    coordinates.append(previousPoint.coordinate)
                }
                coordinates.append(point.coordinate)
                segments.append(RouteActivitySegment(
                    id: point.persistentModelID,
                    mode: mode,
                    startedAt: point.timestamp,
                    endedAt: point.timestamp,
                    startCoordinate: point.coordinate,
                    coordinates: coordinates
                ))
            }
            previousPoint = point
        }
        return segments
    }
}

struct RouteActivitySegment: Identifiable {
    let id: PersistentIdentifier
    let mode: TravelMode
    let startedAt: Date
    var endedAt: Date
    let startCoordinate: CLLocationCoordinate2D
    var coordinates: [CLLocationCoordinate2D]
}

struct RoutePlace: Identifiable {
    struct ID: Hashable {
        let anchor: RouteActivitySegment.ID
    }

    let id: ID
    let number: Int
    let location: CLLocation
    var segments: [RouteActivitySegment]

    static func group(_ segments: [RouteActivitySegment]) -> [RoutePlace] {
        var places: [RoutePlace] = []
        for segment in segments.sorted(by: { $0.startedAt < $1.startedAt }) {
            let coordinate = segment.startCoordinate
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let index = places.firstIndex(where: { $0.location.distance(from: location) <= 200 }) {
                places[index].segments.append(segment)
            } else {
                places.append(RoutePlace(id: ID(anchor: segment.id), number: places.count + 1, location: location, segments: [segment]))
            }
        }
        return places
    }
}

@Model
final class RoutePoint {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var travelMode: String
    var startsNewSegment: Bool
    var route: RecordedRoute?

    init(location: CLLocation, mode: TravelMode, startsNewSegment: Bool, route: RecordedRoute) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        travelMode = mode.rawValue
        self.startsNewSegment = startsNewSegment
        self.route = route
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mode: TravelMode { TravelMode(rawValue: travelMode) ?? .unknown }
}

enum TravelMode: String, CaseIterable {
    case unknown, walking, automotive, cycling, stationary

    var title: String {
        switch self {
        case .unknown: "识别中"
        case .walking: "步行"
        case .automotive: "乘车"
        case .cycling: "骑行"
        case .stationary: "静止"
        }
    }

    static let historyOrder: [TravelMode] = [.walking, .cycling, .automotive, .stationary, .unknown]

    var recordedTitle: String {
        switch self {
        case .unknown: "未分类"
        case .stationary: "停留"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "location"
        case .walking: "figure.walk"
        case .automotive: "car"
        case .cycling: "bicycle"
        case .stationary: "pause.circle"
        }
    }
}

struct LocationSampling {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    let maximumAccuracy: CLLocationAccuracy
    let maximumTravelSpeed: CLLocationSpeed

    init(mode: TravelMode) {
        switch mode {
        case .walking:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 8
            maximumAccuracy = 35
            maximumTravelSpeed = 12
        case .automotive:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 30
            maximumAccuracy = 55
            maximumTravelSpeed = 80
        case .cycling:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 15
            maximumAccuracy = 40
            maximumTravelSpeed = 30
        case .stationary:
            desiredAccuracy = kCLLocationAccuracyHundredMeters
            distanceFilter = kCLDistanceFilterNone
            maximumAccuracy = 50
            maximumTravelSpeed = 80
        case .unknown:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 10
            maximumAccuracy = 45
            maximumTravelSpeed = 80
        }
    }

    func assess(_ location: CLLocation, after previous: CLLocation?, mode: TravelMode, previousMode: TravelMode? = nil) -> RouteStep? {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              (0...maximumAccuracy).contains(location.horizontalAccuracy) else { return nil }
        guard let previous else { return .newSegment }
        let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
        guard seconds > 0 else { return nil }
        if seconds > 90 { return .newSegment }
        if mode == .stationary {
            if previousMode != .stationary { return .newSegment }
            return seconds >= 30 ? .continuation(distance: 0) : nil
        }
        if previousMode == .stationary { return .newSegment }
        let meters = location.distance(from: previous)
        let noiseAllowance = (location.horizontalAccuracy + previous.horizontalAccuracy) * 0.35
        guard meters >= max(distanceFilter, noiseAllowance),
              meters / seconds <= maximumTravelSpeed else { return nil }
        return .continuation(distance: meters)
    }
}

enum RouteStep {
    case newSegment
    case continuation(distance: CLLocationDistance)

    var distance: CLLocationDistance {
        switch self {
        case .newSegment: 0
        case let .continuation(distance): distance
        }
    }

    var startsNewSegment: Bool {
        if case .newSegment = self { return true }
        return false
    }
}
