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

    fileprivate var hasValidTimes: Bool {
        days.allSatisfy { day in
            day.movement.allSatisfy { $0.duration.isFinite && $0.duration >= 0 } &&
                day.stays.allSatisfy { $0.duration.isFinite && $0.duration >= 0 }
        } && visits.allSatisfy { $0.startedAt <= $0.endedAt } &&
            journeys.allSatisfy { $0.duration.isFinite && $0.duration > 0 }
    }
}

struct RouteSummary {
    let id = UUID()
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
    private static let version = 2

    private struct Index: Codable {
        let version: Int
        let calendar: Calendar
        let records: [RouteReviewRevision.RouteVersion: RouteSummaryRecord]
    }

    private let file: URL
    private var excludedRoutes: Set<UUID> = []
    private lazy var index: Index? = {
        guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Index.self, from: data),
              decoded.version == Self.version else { return nil }
        return Index(version: decoded.version, calendar: decoded.calendar, records: decoded.records.filter { $0.value.hasValidTimes })
    }()

    init(file: URL) {
        self.file = file
    }

    func records(for revision: RouteReviewRevision) -> [RouteReviewRevision.RouteVersion: RouteSummaryRecord] {
        guard let index, index.version == Self.version, index.calendar == revision.calendar else { return [:] }
        return revision.routes.filter { !excludedRoutes.contains($0.id) }.reduce(into: [:]) { $0[$1] = index.records[$1] }
    }

    func save(
        _ records: [RouteReviewRevision.RouteVersion: RouteSummaryRecord],
        for revision: RouteReviewRevision, after delay: Duration = .zero
    ) async {
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let records = records.filter { !excludedRoutes.contains($0.key.id) }
        if let index, index.version == Self.version, index.calendar == revision.calendar,
           index.records.keys == records.keys { return }
        let updated = Index(version: Self.version, calendar: revision.calendar, records: records)
        do {
            try write(updated)
        } catch {
            // The cache is optional and a later load can reconstruct a failed write.
        }
    }

    func prepareToDelete(routeID: UUID) throws {
        excludedRoutes.insert(routeID)
        do {
            if let current = index {
                let retained = current.records.filter { !excludedRoutes.contains($0.key.id) }
                try write(Index(version: current.version, calendar: current.calendar, records: retained))
            } else {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                }
            }
        } catch {
            excludedRoutes.remove(routeID)
            throw error
        }
    }

    func cancelDeletion(routeID: UUID) {
        excludedRoutes.remove(routeID)
    }

    private func write(_ updated: Index) throws {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        index = updated
    }
}
