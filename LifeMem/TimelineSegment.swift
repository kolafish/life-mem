import CoreLocation
import Foundation
import SwiftData

typealias RouteActivitySegment = ActivitySegment<PersistentIdentifier>

struct RouteReviewEntry: Identifiable {
    enum Kind { case trip, visit, fragment }

    struct Endpoints {
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
    }

    var id: PersistentIdentifier { segments[0].id }
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
    struct Movement {
        var duration: TimeInterval = 0
        var distance: CLLocationDistance = 0
    }

    var id: Date { date }

    let date: Date
    let entries: [RouteReviewEntry]
    private(set) var midnightMovement = Movement()

    var timeline: [TimelineSegment] { entries.flatMap(\.timeline) }
    var stays: [StayEvent] { entries.compactMap(\.stay) }
    var moves: [MoveEvent] { entries.flatMap(\.moves) }
    var movingDistanceMeters: CLLocationDistance { moves.reduce(midnightMovement.distance) { $0 + $1.distanceMeters } }
    var movingDuration: TimeInterval { moves.reduce(midnightMovement.duration) { $0 + $1.duration } }
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

struct StayEvent: Identifiable {
    let id: PersistentIdentifier
    let visitID: PersistentIdentifier
    let coordinate: CLLocationCoordinate2D
    let startedAt: Date
    let endedAt: Date

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
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

struct RouteJourney: Identifiable {
    struct StayConnection {
        let coordinate: CLLocationCoordinate2D
        let time: Date
    }

    let id: PersistentIdentifier
    let endpoints: RouteReviewEntry.Endpoints
    let departedAt: Date
    let duration: TimeInterval
    let mode: TravelMode
    let departureStay: StayConnection?
    let arrivalStay: StayConnection?
}

struct RouteVisit: Identifiable {
    let id: PersistentIdentifier
    let date: Date
    let startedAt: Date
    let endedAt: Date
    let coordinate: CLLocationCoordinate2D
}

struct RoutePlace: Identifiable {
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
