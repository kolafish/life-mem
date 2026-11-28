import CoreLocation
import Foundation
import SwiftData

typealias RouteActivitySegment = ActivitySegment<PersistentIdentifier>

struct RouteReviewEntry: Identifiable {
    enum Kind { case trip, visit, fragment }

    struct Endpoints: Codable, Sendable {
        private let origin: StoredCoordinate
        private let destination: StoredCoordinate

        var start: CLLocationCoordinate2D { origin.coordinate }
        var end: CLLocationCoordinate2D { destination.coordinate }

        init(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) {
            origin = StoredCoordinate(start)
            destination = StoredCoordinate(end)
        }
    }

    var id: PersistentIdentifier { stay?.id ?? segments[0].id }
    var startedAt: Date { stay?.startedAt ?? segments[0].movementStartedAt }
    var endedAt: Date { stay?.endedAt ?? segments[segments.count - 1].endedAt }

    let kind: Kind
    let followsGap: Bool
    let segments: [RouteActivitySegment]
    let endpoints: Endpoints?
    let stay: StayEvent?

    var visitCoordinate: CLLocationCoordinate2D? { stay?.coordinate }

    var timeline: [TimelineSegment] {
        if let stay { return [.stay(stay)] }
        return moves.map(TimelineSegment.move)
    }
    var moves: [MoveEvent] {
        guard stay == nil else { return [] }
        return segments.filter { $0.distanceMeters > 0 }.map(MoveEvent.init)
    }

}

struct RouteReviewDay: Identifiable {
    var id: Date { date }

    let date: Date
    let entries: [RouteReviewEntry]

    var timeline: [TimelineSegment] { entries.flatMap(\.timeline) }
    var stays: [StayEvent] { entries.compactMap(\.stay).filter { $0.isCandidate != true } }
    var moves: [MoveEvent] { entries.flatMap(\.moves) }
    var movingDistanceMeters: CLLocationDistance { moves.reduce(0) { $0 + $1.distanceMeters } }
    var movingDuration: TimeInterval { moves.reduce(0) { $0 + $1.duration } }
    var movementIntervals: [DateInterval] {
        moves.map { DateInterval(start: $0.startedAt, end: $0.endedAt) }
    }
}

enum TimelineSegment: Identifiable {
    case stay(StayEvent)
    case move(MoveEvent)

    var id: PersistentIdentifier {
        switch self {
        case let .stay(event): event.id
        case let .move(event): event.id
        }
    }
}

struct StayEvent: Identifiable, Codable, Sendable {
    let id: PersistentIdentifier
    var isCandidate: Bool? = nil
    let visitID: PersistentIdentifier
    private let position: StoredCoordinate
    let startedAt: Date
    let endedAt: Date

    var coordinate: CLLocationCoordinate2D { position.coordinate }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    init(id: PersistentIdentifier, visitID: PersistentIdentifier, coordinate: CLLocationCoordinate2D, startedAt: Date, endedAt: Date) {
        self.id = id
        self.visitID = visitID
        position = StoredCoordinate(coordinate)
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

struct MoveEvent: Identifiable {
    let activity: RouteActivitySegment

    var id: PersistentIdentifier { activity.id }
    var startedAt: Date { activity.movementStartedAt }
    var endedAt: Date { activity.endedAt }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var distanceMeters: CLLocationDistance { activity.distanceMeters }
    var averageKilometersPerHour: Double { duration > 0 ? distanceMeters / duration * 3.6 : 0 }
    var mode: TravelMode { activity.mode }
    var coordinates: [CLLocationCoordinate2D] { activity.coordinates }
}

struct RouteJourney: Identifiable, Codable, Sendable {
    struct StayConnection: Codable, Sendable {
        private let position: StoredCoordinate
        let time: Date

        var coordinate: CLLocationCoordinate2D { position.coordinate }

        init(coordinate: CLLocationCoordinate2D, time: Date) {
            position = StoredCoordinate(coordinate)
            self.time = time
        }
    }

    let id: PersistentIdentifier
    let endpoints: RouteReviewEntry.Endpoints
    let departedAt: Date
    let duration: TimeInterval
    let mode: TravelMode
    let departureStay: StayConnection?
    let arrivalStay: StayConnection?
}

struct RouteVisit: Identifiable, Codable, Sendable {
    let id: PersistentIdentifier
    let date: Date
    let startedAt: Date
    let endedAt: Date
    private let position: StoredCoordinate

    var coordinate: CLLocationCoordinate2D { position.coordinate }

    init(id: PersistentIdentifier, date: Date, startedAt: Date, endedAt: Date, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.date = date
        self.startedAt = startedAt
        self.endedAt = endedAt
        position = StoredCoordinate(coordinate)
    }
}

struct RoutePlace: Identifiable, Sendable {
    var id: RouteVisit.ID { visits[0].id }
    var coordinate: CLLocationCoordinate2D { visits[0].coordinate }
    var mostRecentVisit: RouteVisit { visits[visits.count - 1] }

    private(set) var visits: [RouteVisit]

    static func group(_ visits: [RouteVisit], within radius: CLLocationDistance) -> [RoutePlace] {
        var places: [RoutePlace] = []
        for visit in visits.sorted(by: { $0.startedAt < $1.startedAt }) {
            let location = visit.coordinate.location
            let nearest = places.indices.lazy
                .map { (index: $0, distance: places[$0].coordinate.location.distance(from: location)) }
                .min { $0.distance < $1.distance }
            if let nearest, nearest.distance <= radius {
                places[nearest.index].visits.append(visit)
            } else {
                places.append(RoutePlace(visits: [visit]))
            }
        }
        return places.sorted { $0.mostRecentVisit.startedAt > $1.mostRecentVisit.startedAt }
    }
}
