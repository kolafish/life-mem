import Foundation

struct DailySummary: Codable, Sendable {
    let date: Date
    let movement: [DateInterval]
    let stays: [StayEvent]

    var movingDuration: TimeInterval { movement.reduce(0) { $0 + $1.duration } }

    init(day: RouteReviewDay) {
        date = day.date
        movement = day.movementIntervals
        stays = day.stays
    }

    init(date: Date, combining summaries: [DailySummary]) {
        self.date = date
        movement = summaries.flatMap(\.movement)
        stays = summaries.flatMap(\.stays)
    }
}

struct RouteSummaryRecord: Codable, Sendable {
    let days: [DailySummary]
    let visits: [RouteVisit]
    let journeys: [RouteJourney]
}

struct RouteSummary {
    let days: [DailySummary]
    let places: [RoutePlace]
    let journeys: [RouteJourney]

    init(review: RouteReview) {
        days = review.days.map(DailySummary.init(day:))
        places = review.places
        journeys = review.journeys
    }

    init(records: [RouteSummaryRecord]) {
        let byDate = Dictionary(grouping: records.flatMap(\.days), by: \.date)
        days = byDate.keys.sorted(by: >).map { DailySummary(date: $0, combining: byDate[$0, default: []]) }
        places = RoutePlace.group(records.flatMap(\.visits), within: RouteReview.placeRadius)
        journeys = records.flatMap(\.journeys)
    }
}

actor RouteSummaryIndex {
    // Increment when the stored fields or the segmentation and projection rules change.
    private static let version = 1

    private struct Index: Codable {
        let version: Int
        let calendar: Calendar
        let records: [RouteReviewRevision.RouteVersion: RouteSummaryRecord]
    }

    private let file: URL
    private lazy var index = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) }

    init(file: URL) {
        self.file = file
    }

    func records(for revision: RouteReviewRevision) -> [RouteReviewRevision.RouteVersion: RouteSummaryRecord] {
        guard let index, index.version == Self.version, index.calendar == revision.calendar else { return [:] }
        return revision.routes.reduce(into: [:]) { $0[$1] = index.records[$1] }
    }

    func save(_ records: [RouteReviewRevision.RouteVersion: RouteSummaryRecord], for revision: RouteReviewRevision) {
        guard !Task.isCancelled else { return }
        if let index, index.version == Self.version, index.calendar == revision.calendar,
           index.records.keys == records.keys { return }
        let updated = Index(version: Self.version, calendar: revision.calendar, records: records)
        guard let data = try? JSONEncoder().encode(updated), !Task.isCancelled else { return }
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            index = updated
        } catch {
            // The cache is optional and a later load can reconstruct a failed write.
        }
    }
}
