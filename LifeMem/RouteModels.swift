import CoreLocation
import Foundation
import SwiftData

@Model
final class RecordedRoute {
    var id: UUID
    var startedAt: Date
    var isAutomatic: Bool?
    var automaticPauseAt: Date?
    var automaticSessionStart: Date?
    var previousAutomaticRouteID: UUID?
    var endedAtRest: Bool?
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
}

@Model
final class RoutePoint {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var travelMode: String
    var startsNewSegment: Bool
    var startsRecordingRun: Bool?
    var route: RecordedRoute?

    init(location: CLLocation, mode: TravelMode, startsNewSegment: Bool, startsRecordingRun: Bool? = nil, route: RecordedRoute) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        travelMode = mode.rawValue
        self.startsNewSegment = startsNewSegment
        self.startsRecordingRun = startsRecordingRun
        self.route = route
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mode: TravelMode { TravelMode(rawValue: travelMode) ?? .unknown }

    var locationPoint: LocationPoint<PersistentIdentifier> {
        LocationPoint(
            id: persistentModelID,
            timestamp: timestamp,
            coordinate: coordinate,
            accuracy: accuracy,
            mode: mode,
            startsNewSegment: startsNewSegment,
            startsRecordingRun: startsRecordingRun
        )
    }
}
