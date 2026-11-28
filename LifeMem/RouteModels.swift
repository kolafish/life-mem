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

    // A relationship already faulted in the recorder may omit notes saved by a different context on iOS 17.
    @MainActor func deleteWithMemories(in context: ModelContext) throws {
        let routeID = id
        let descriptor = FetchDescriptor<RouteMemory>(predicate: #Predicate {
            $0.owner?.id == routeID || $0.previous?.id == routeID
        })
        for memory in try context.fetch(descriptor) {
            let key = memory.key
            let photos = FetchDescriptor<MemoryPhoto>(predicate: #Predicate { $0.memory?.key == key })
            for photo in try context.fetch(photos) { context.delete(photo) }
            context.delete(memory)
        }
        let points = FetchDescriptor<RoutePoint>(predicate: #Predicate { $0.route?.id == routeID })
        for point in try context.fetch(points) { context.delete(point) }
        context.delete(self)
    }

    func annotatedObservations() -> Set<String> {
        guard let container = modelContext?.container else { return [] }
        let reader = ModelContext(container)
        let routeID = id
        let descriptor = FetchDescriptor<RouteMemory>(predicate: #Predicate { $0.owner?.id == routeID })
        let records = (try? reader.fetch(descriptor)) ?? memories ?? []
        return Set(records.filter(\.isAnnotated).map(\.key))
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

    init(owner: UUID, start: Date) {
        self.owner = owner
        value = "\(owner.uuidString)/observation/\(start.timeIntervalSinceReferenceDate.bitPattern)"
    }

    init(arrival: UUID, departure: UUID) {
        owner = departure
        previous = arrival
        value = "\(arrival.uuidString)/arrival/\(departure.uuidString)"
    }

    @MainActor func update(in container: ModelContainer, _ edit: (RouteMemory, ModelContext) throws -> Void) throws {
        // An unsuccessful insert must never roll back the recorder's context.
        let writer = ModelContext(container)
        writer.autosaveEnabled = false
        let memory = try memory(in: writer)
        let wasAnnotated = memory.isAnnotated
        try edit(memory, writer)
        if wasAnnotated != memory.isAnnotated { memory.owner?.visitRevision = UUID() }
        try writer.save()
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
    @Relationship(deleteRule: .cascade, inverse: \MemoryPhoto.memory)
    var photos: [MemoryPhoto]?
    var owner: RecordedRoute?
    var previous: RecordedRoute?

    var isAnnotated: Bool {
        !text.isEmpty || draft != nil || photos?.contains { !$0.hidden && $0.memory?.key == key } == true
    }

    func attachment(for assetID: String?, in writer: ModelContext) throws -> MemoryPhoto {
        if let assetID, let photo = try attachedPhoto(for: assetID, in: writer) { return photo }
        let photo = MemoryPhoto(memory: self, assetID: assetID)
        writer.insert(photo)
        return photo
    }

    fileprivate func attachedPhoto(for assetID: String, in writer: ModelContext) throws -> MemoryPhoto? {
        let ownerKey = key
        var descriptor = FetchDescriptor<MemoryPhoto>(predicate: #Predicate {
            $0.assetID == assetID && $0.memory?.key == ownerKey
        })
        descriptor.fetchLimit = 1
        return try writer.fetch(descriptor).first
    }

    init(key: String, owner: RecordedRoute, previous: RecordedRoute?) {
        self.key = key
        self.owner = owner
        self.previous = previous
        text = ""
    }
}

@Model
final class MemoryPhoto {
    var id: UUID
    var added: Date
    var taken: Date?
    var latitude: Double?
    var longitude: Double?
    var assetID: String?
    var hidden: Bool
    @Attribute(.externalStorage) var image: Data?
    @Attribute(.externalStorage) var thumbnail: Data?
    var memory: RouteMemory?

    init(memory: RouteMemory, assetID: String?) {
        id = UUID()
        added = .now
        hidden = false
        self.memory = memory
        self.assetID = assetID
    }

    func hide(in writer: ModelContext) {
        hidden = true
        image = nil
        thumbnail = nil
        if assetID == nil { writer.delete(self) }
    }

    func move(to destination: RouteMemory, in writer: ModelContext) throws {
        guard let origin = memory, origin.key != destination.key else { return }
        if let assetID, let existing = try destination.attachedPhoto(for: assetID, in: writer) {
            if let image {
                existing.image = image
                existing.thumbnail = thumbnail
                existing.taken = taken
                existing.latitude = latitude
                existing.longitude = longitude
            }
            existing.hidden = false
            hidden = true
            writer.delete(self)
        } else {
            memory = destination
        }
        if !origin.isAnnotated { origin.owner?.visitRevision = UUID() }
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(point) ? point : nil
    }
}
