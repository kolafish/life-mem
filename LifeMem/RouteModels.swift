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
    var visitRevision: UUID?
    var arrivalDecision: String?
    var arrivalName: String?
    var isFinished: Bool
    var pointCount: Int
    var distanceMeters: Double

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.route)
    var points: [RoutePoint]

    @Relationship(deleteRule: .cascade, inverse: \RouteMemory.owner)
    var memories: [RouteMemory]?
    @Relationship(deleteRule: .cascade, inverse: \RouteMemory.previous)
    var arrivalMemories: [RouteMemory]?

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
    var visitName: String?
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

@MainActor
enum VisitCorrection {
    enum Failure: Error { case sourceUnavailable }

    static func save(_ stay: StayEvent, name: String?, ignore: Bool = false, in context: ModelContext) throws {
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedName = label?.isEmpty == false ? label : nil
        let route: RecordedRoute
        if stay.isInferred == true {
            let id = stay.visitID
            guard let owner = try context.fetch(FetchDescriptor<RecordedRoute>(
                predicate: #Predicate { $0.persistentModelID == id })).first, owner.isAutomatic == true,
                  owner.previousAutomaticRouteID == stay.sourceArrivalID,
                  let previous = stay.sourceArrivalID,
                  try context.fetchCount(FetchDescriptor<RecordedRoute>(predicate: #Predicate { $0.id == previous })) == 1
            else { throw Failure.sourceUnavailable }
            owner.arrivalDecision = ignore ? "ignored" : "confirmed"
            owner.arrivalName = ignore ? nil : savedName
            route = owner
        } else {
            let id = stay.visitID
            guard !ignore, let point = try context.fetch(FetchDescriptor<RoutePoint>(
                predicate: #Predicate { $0.persistentModelID == id })).first, let owner = point.route
            else { throw Failure.sourceUnavailable }
            point.visitName = savedName
            route = owner
        }
        route.visitRevision = UUID()
        do { try context.save() } catch { context.rollback(); throw error }
    }
}

/// Identifies the original observation, even when midnight splits its presentation.
struct RouteMemoryKey: Hashable {
    let owner: UUID
    let value: String
    var previous: UUID?

    init(owner: UUID, start: Date, visit: Bool) {
        self.owner = owner
        value = "\(owner.uuidString)/\(visit ? "stay" : "move")/\(start.timeIntervalSinceReferenceDate.bitPattern)"
    }

    init(arrival: UUID, departure: UUID) {
        owner = departure
        previous = arrival
        value = "\(arrival.uuidString)/arrival/\(departure.uuidString)"
    }

    @MainActor func memory(in context: ModelContext) throws -> RouteMemory {
        let value = value
        if let existing = try context.fetch(FetchDescriptor<RouteMemory>(predicate: #Predicate { $0.key == value })).first {
            return existing
        }
        func route(_ id: UUID) throws -> RecordedRoute {
            guard let result = try context.fetch(FetchDescriptor<RecordedRoute>(predicate: #Predicate { $0.id == id })).first
            else { throw VisitCorrection.Failure.sourceUnavailable }
            return result
        }
        let owner = try route(self.owner)
        let previous = try previous.map(route)
        let memory = RouteMemory(key: value, owner: owner, previous: previous)
        context.insert(memory)
        return memory
    }
}

@Model
final class RouteMemory {
    @Attribute(.unique) var key: String
    var text: String
    var draft: String?
    var owner: RecordedRoute?
    var previous: RecordedRoute?

    init(key: String, owner: RecordedRoute, previous: RecordedRoute?) {
        self.key = key
        self.owner = owner
        self.previous = previous
        text = ""
    }
}
