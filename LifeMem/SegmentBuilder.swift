import CoreLocation
import Foundation

struct ActivitySegment<ID: Hashable>: Identifiable {
    let id: ID
    var mode: TravelMode
    let startedAt: Date
    let movementStartedAt: Date
    var endedAt: Date
    let startCoordinate: CLLocationCoordinate2D
    var coordinates: [CLLocationCoordinate2D]
    var distanceMeters: CLLocationDistance
}

enum SegmentBuilder {
    private static let minimumVisitDuration: TimeInterval = 8 * 60
    private static let stayRadius: CLLocationDistance = 60

    enum Slice<ID: Hashable> {
        case stay(ArraySlice<LocationPoint<ID>>, center: CLLocationCoordinate2D)
        case move(ArraySlice<LocationPoint<ID>>)

        var points: ArraySlice<LocationPoint<ID>> {
            switch self {
            case let .stay(points, _), let .move(points): points
            }
        }

        var visitCoordinate: CLLocationCoordinate2D? {
            if case let .stay(_, center) = self { return center }
            return nil
        }
    }

    static func build<ID: Hashable>(_ points: [LocationPoint<ID>]) -> [[Slice<ID>]] {
        cleanRuns(points.sorted { $0.timestamp < $1.timestamp }).map(timelineSlices)
    }

    static func group<ID: Hashable>(
        sortedPoints: [LocationPoint<ID>],
        inferModes: Bool = false,
        leadingStayPoint: LocationPoint<ID>? = nil,
        trailingStayPoint: LocationPoint<ID>? = nil
    ) -> [ActivitySegment<ID>] {
        var segments: [ActivitySegment<ID>] = []
        var previousPoint = leadingStayPoint
        var previousMode: TravelMode?
        for point in sortedPoints {
            let distance = previousPoint.map { measuredDistance(from: $0, to: point) } ?? 0
            let startsDrawingSegment = point.startsNewSegment && (leadingStayPoint == nil || !segments.isEmpty)
            let mode: TravelMode
            if inferModes, point.mode == .unknown, distance > 0, let previousPoint, !startsDrawingSegment {
                mode = TravelMode.estimated(metersPerSecond: distance / point.timestamp.timeIntervalSince(previousPoint.timestamp))
            } else {
                mode = point.mode
            }
            let bridgesPrevious = !startsDrawingSegment && mode != .stationary && previousMode != .stationary &&
                (!segments.isEmpty || distance > 0)
            if previousMode == mode, !startsDrawingSegment {
                let index = segments.count - 1
                segments[index].endedAt = point.timestamp
                if mode != .stationary {
                    segments[index].coordinates.append(point.coordinate)
                    segments[index].distanceMeters += distance
                }
            } else {
                // Keep the map line continuous across a change in travel mode.
                var coordinates: [CLLocationCoordinate2D] = []
                if let previousPoint, bridgesPrevious {
                    coordinates.append(previousPoint.coordinate)
                }
                coordinates.append(point.coordinate)
                segments.append(ActivitySegment(
                    id: point.id,
                    mode: mode,
                    startedAt: point.timestamp,
                    movementStartedAt: bridgesPrevious ? previousPoint?.timestamp ?? point.timestamp : point.timestamp,
                    endedAt: point.timestamp,
                    startCoordinate: point.coordinate,
                    coordinates: coordinates,
                    distanceMeters: bridgesPrevious ? distance : 0
                ))
            }
            previousPoint = point
            previousMode = mode
        }
        if let trailingStayPoint, let previousPoint, let last = segments.indices.last, segments[last].mode != .stationary {
            let distance = measuredDistance(from: previousPoint, to: trailingStayPoint)
            if distance > 0 {
                if inferModes, segments[last].mode == .unknown {
                    let seconds = trailingStayPoint.timestamp.timeIntervalSince(previousPoint.timestamp)
                    segments[last].mode = TravelMode.estimated(metersPerSecond: distance / seconds)
                }
                segments[last].endedAt = trailingStayPoint.timestamp
                segments[last].coordinates.append(trailingStayPoint.coordinate)
                segments[last].distanceMeters += distance
            }
        }
        return segments
    }

    static func measuredDistance<ID: Hashable>(from first: LocationPoint<ID>, to second: LocationPoint<ID>) -> CLLocationDistance {
        let meters = first.coordinate.location.distance(from: second.coordinate.location)
        let noise = (first.accuracy + second.accuracy) * 0.35
        return meters >= noise ? meters : 0
    }

    private static func cleanRuns<ID: Hashable>(_ points: [LocationPoint<ID>]) -> [[LocationPoint<ID>]] {
        var runs: [[LocationPoint<ID>]] = []
        var run: [LocationPoint<ID>] = []
        var previousObserved: LocationPoint<ID>?
        for point in points {
            if let previousObserved {
                let changesStationary = (point.mode == .stationary) != (previousObserved.mode == .stationary)
                // Early versions also used the drawing flag for changes to and from stationary.
                let boundary = point.startsRecordingRun ?? (point.startsNewSegment && !changesStationary)
                if boundary, !run.isEmpty {
                    runs.append(run)
                    run = []
                }
            }
            previousObserved = point
            guard CLLocationCoordinate2DIsValid(point.coordinate),
                  (0...LocationSampling.accuracyLimit).contains(point.accuracy) else { continue }
            if let previous = run.last {
                let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
                guard seconds > 0 else { continue }
                if seconds > LocationSampling.maximumGap {
                    runs.append(run)
                    run = []
                } else if point.coordinate.location.distance(from: previous.coordinate.location) / seconds > LocationSampling.speedLimit {
                    continue
                }
            }
            run.append(point)
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    private static func timelineSlices<ID: Hashable>(_ run: [LocationPoint<ID>]) -> [Slice<ID>] {
        var slices: [Slice<ID>] = []
        var start = run.startIndex
        var candidate = start
        while candidate < run.endIndex {
            let first = run[candidate]
            guard isStayCandidate(first) else {
                candidate += 1
                continue
            }
            let anchor = first.coordinate.location
            var end = candidate + 1
            while end < run.endIndex {
                let point = run[end]
                guard isStayCandidate(point) else { break }
                let distance = point.coordinate.location.distance(from: anchor)
                if distance > stayRadius {
                    let next = end + 1
                    guard distance <= stayRadius + point.accuracy, next < run.endIndex,
                          isStayCandidate(run[next]),
                          run[next].timestamp.timeIntervalSince(run[end - 1].timestamp) <= LocationSampling.maximumGap,
                          run[next].coordinate.location.distance(from: anchor) <= stayRadius else { break }
                }
                end += 1
            }
            guard run[end - 1].timestamp.timeIntervalSince(first.timestamp) >= minimumVisitDuration else {
                candidate += 1
                continue
            }
            if start < candidate { slices.append(.move(run[start..<candidate])) }
            let points = run[candidate..<end]
            slices.append(.stay(points, center: center(of: points, near: first.coordinate)))
            start = end
            candidate = end
        }
        if start < run.endIndex { slices.append(.move(run[start...])) }
        return slices
    }

    private static func isStayCandidate<ID: Hashable>(_ point: LocationPoint<ID>) -> Bool {
        point.mode == .stationary || point.mode == .unknown
    }

    private static func center<ID: Hashable>(of points: ArraySlice<LocationPoint<ID>>, near anchor: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let anchorLocation = anchor.location
        var latitude = 0.0
        var longitudeOffset = 0.0
        var weight = 0.0
        for point in points where point.coordinate.location.distance(from: anchorLocation) <= stayRadius {
            let confidence = 1 / max(point.accuracy, 5)
            let delta = (point.coordinate.longitude - anchor.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            latitude += point.coordinate.latitude * confidence
            longitudeOffset += delta * confidence
            weight += confidence
        }
        let longitude = anchor.longitude + longitudeOffset / weight
        if (-180...180).contains(longitude) {
            return CLLocationCoordinate2D(latitude: latitude / weight, longitude: longitude)
        }
        let wrapped = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: latitude / weight, longitude: wrapped)
    }
}
