import CoreLocation
import Foundation

private struct TrackSample {
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let distanceFromPrevious: CLLocationDistance

    func withDistance(_ distance: CLLocationDistance) -> Self {
        Self(timestamp: timestamp, coordinate: coordinate, distanceFromPrevious: distance)
    }
}

struct ActivitySegment<ID: Hashable>: Identifiable {
    let id: ID
    var mode: TravelMode
    let startedAt: Date
    let startCoordinate: CLLocationCoordinate2D
    var distanceMeters: CLLocationDistance
    fileprivate var samples: [TrackSample]

    var movementStartedAt: Date { samples[0].timestamp }
    var endedAt: Date { samples[samples.count - 1].timestamp }
    var firstCoordinate: CLLocationCoordinate2D { samples[0].coordinate }
    var lastCoordinate: CLLocationCoordinate2D { samples[samples.count - 1].coordinate }
    var coordinates: [CLLocationCoordinate2D] { mode == .stationary ? [startCoordinate] : samples.map(\.coordinate) }

    fileprivate func projected(_ samples: [TrackSample]) -> Self {
        let first = samples[0]
        let last = samples[samples.count - 1]
        let containsStart = first.timestamp <= startedAt && startedAt <= last.timestamp
        return Self(id: id, mode: mode, startedAt: containsStart ? startedAt : first.timestamp,
                    startCoordinate: containsStart ? startCoordinate : first.coordinate,
                    distanceMeters: samples.reduce(0) { $0 + $1.distanceFromPrevious }, samples: samples)
    }
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
            let seconds = previousPoint.map { point.timestamp.timeIntervalSince($0.timestamp) }
            if let seconds, !seconds.isFinite || seconds <= 0 { continue }
            let distance = previousPoint.map { measuredDistance(from: $0, to: point) } ?? 0
            let startsDrawingSegment = point.startsNewSegment && (leadingStayPoint == nil || !segments.isEmpty)
            let mode: TravelMode
            if inferModes, point.mode == .unknown, distance > 0, let seconds, !startsDrawingSegment {
                mode = TravelMode.estimated(metersPerSecond: distance / seconds)
            } else {
                mode = point.mode
            }
            let bridgesPrevious = !startsDrawingSegment && mode != .stationary && previousMode != .stationary &&
                (!segments.isEmpty || distance > 0)
            if previousMode == mode, !startsDrawingSegment {
                let index = segments.count - 1
                let step = mode == .stationary ? 0 : distance
                segments[index].samples.append(TrackSample(timestamp: point.timestamp, coordinate: point.coordinate, distanceFromPrevious: step))
                segments[index].distanceMeters += step
            } else {
                // Keep the map line continuous across a change in travel mode.
                var samples: [TrackSample] = []
                if let previousPoint, bridgesPrevious {
                    samples.append(TrackSample(timestamp: previousPoint.timestamp, coordinate: previousPoint.coordinate, distanceFromPrevious: 0))
                }
                let step = bridgesPrevious ? distance : 0
                samples.append(TrackSample(timestamp: point.timestamp, coordinate: point.coordinate, distanceFromPrevious: step))
                segments.append(ActivitySegment(
                    id: point.id,
                    mode: mode,
                    startedAt: point.timestamp,
                    startCoordinate: point.coordinate,
                    distanceMeters: step,
                    samples: samples
                ))
            }
            previousPoint = point
            previousMode = mode
        }
        if let trailingStayPoint, let previousPoint, let last = segments.indices.last, segments[last].mode != .stationary {
            let seconds = trailingStayPoint.timestamp.timeIntervalSince(previousPoint.timestamp)
            let distance = measuredDistance(from: previousPoint, to: trailingStayPoint)
            if seconds.isFinite, seconds > 0, distance > 0 {
                if inferModes, segments[last].mode == .unknown {
                    segments[last].mode = TravelMode.estimated(metersPerSecond: distance / seconds)
                }
                segments[last].samples.append(TrackSample(timestamp: trailingStayPoint.timestamp,
                                                          coordinate: trailingStayPoint.coordinate, distanceFromPrevious: distance))
                segments[last].distanceMeters += distance
            }
        }
        return segments
    }

    static func project<ID: Hashable>(_ segments: [ActivitySegment<ID>], by calendar: Calendar) -> [Date: [ActivitySegment<ID>]] {
        var days: [Date: [ActivitySegment<ID>]] = [:]
        for segment in segments {
            var day = calendar.startOfDay(for: segment.movementStartedAt)
            if calendar.isDate(segment.endedAt, inSameDayAs: day) {
                days[day, default: []].append(segment)
                continue
            }

            var samples = [segment.samples[0]]
            for (from, to) in zip(segment.samples, segment.samples.dropFirst()) {
                let nextDay = calendar.startOfDay(for: to.timestamp)
                if nextDay == day {
                    samples.append(to)
                    continue
                }

                if to.distanceFromPrevious > 0 {
                    let boundary = midnightSample(from: from, to: to, at: nextDay)
                    samples.append(boundary)
                    days[day, default: []].append(segment.projected(samples))
                    samples = [boundary.withDistance(0)]
                    if to.timestamp > nextDay {
                        samples.append(to.withDistance(to.distanceFromPrevious - boundary.distanceFromPrevious))
                    }
                } else {
                    days[day, default: []].append(segment.projected(samples))
                    samples = [to]
                }
                day = nextDay
            }
            days[day, default: []].append(segment.projected(samples))
        }
        return days
    }

    private static func midnightSample(from: TrackSample, to: TrackSample, at midnight: Date) -> TrackSample {
        if midnight == to.timestamp { return to }
        let share = midnight.timeIntervalSince(from.timestamp) / to.timestamp.timeIntervalSince(from.timestamp)
        let delta = (to.coordinate.longitude - from.coordinate.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        let longitude = (from.coordinate.longitude + delta * share + 540).truncatingRemainder(dividingBy: 360) - 180
        let latitude = from.coordinate.latitude + (to.coordinate.latitude - from.coordinate.latitude) * share
        return TrackSample(timestamp: midnight, coordinate: .init(latitude: latitude, longitude: longitude),
                           distanceFromPrevious: to.distanceFromPrevious * share)
    }

    private static func measuredDistance<ID: Hashable>(from first: LocationPoint<ID>, to second: LocationPoint<ID>) -> CLLocationDistance {
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
