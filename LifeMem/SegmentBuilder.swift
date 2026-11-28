import CoreLocation
import Foundation
import HHTCore

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

    static func build<ID: Hashable>(
        _ points: [LocationPoint<ID>], automatic: Bool = false, namedVisitStarts: Set<ID> = []
    ) -> [[Slice<ID>]] {
        cleanRuns(points.sorted { $0.timestamp < $1.timestamp }, automatic: automatic).map {
            timelineSlices($0, automatic: automatic, namedVisitStarts: namedVisitStarts)
        }
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
            let observationGap = seconds.map { $0 > LocationSampling.maximumGap } ?? false
            let startsDrawingSegment = observationGap || point.startsRecordingRun == true ||
                (point.startsNewSegment && (leadingStayPoint == nil || !segments.isEmpty))
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
            if seconds > 0, seconds <= LocationSampling.maximumGap, trailingStayPoint.startsRecordingRun != true, distance > 0 {
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

    private static func cleanRuns<ID: Hashable>(_ points: [LocationPoint<ID>], automatic: Bool) -> [[LocationPoint<ID>]] {
        var runs: [[LocationPoint<ID>]] = []
        var run: [LocationPoint<ID>] = []
        var previousObserved: LocationPoint<ID>?
        for point in points {
            if let previousObserved {
                let changesStationary = (point.mode == .stationary) != (previousObserved.mode == .stationary)
                // Early versions also used the drawing flag for changes to and from stationary.
                let legacyPause = point.startsNewSegment && !changesStationary &&
                    point.timestamp.timeIntervalSince(previousObserved.timestamp) <= LocationSampling.maximumGap
                let boundary = !automatic && (point.startsRecordingRun ?? legacyPause)
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
                if seconds <= LocationSampling.maximumGap,
                   point.coordinate.location.distance(from: previous.coordinate.location) / seconds > LocationSampling.speedLimit {
                    continue
                }
            }
            run.append(point)
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    private static func timelineSlices<ID: Hashable>(
        _ run: [LocationPoint<ID>], automatic: Bool, namedVisitStarts: Set<ID>
    ) -> [Slice<ID>] {
        var candidates: [(Range<Int>, CLLocationCoordinate2D)] = []
        var next = run.startIndex
        while next < run.endIndex {
            let start = next
            next += 1
            guard canBeAtPlace(run[start]) else { continue }
            // Only uninterrupted observations establish dwell time. A saved visit edit owns its first sample.
            while next < run.endIndex, canBeAtPlace(run[next]), !namedVisitStarts.contains(run[next].id),
                  run[next].continuesObservation(after: run[next - 1]) {
                next += 1
            }
            let window = run[start..<next]
            guard run[next - 1].timestamp.timeIntervalSince(run[start].timestamp) >= minimumVisitDuration else { continue }
            candidates += observedStays(in: window, preserveNamedStart: namedVisitStarts.contains(run[start].id))
        }

        var slices: [Slice<ID>] = []
        var movementStart = run.startIndex
        for (i, candidate) in candidates.enumerated() {
            let (range, center) = candidate
            if automatic, range != run.indices, !namedVisitStarts.contains(run[range.lowerBound].id) {
                // Inspect only the travel immediately adjacent to this stop. Evidence
                // from another possible visit must not be borrowed across its dwell.
                let before = i == 0 ? run.startIndex : candidates[i - 1].0.upperBound
                let after = i + 1 == candidates.count ? run.endIndex : candidates[i + 1].0.lowerBound
                let arriving = ArrivalMotion.adjacent(in: run[before..<range.lowerBound].reversed(), from: run[range.lowerBound], acrossResumption: true)
                let leaving = ArrivalMotion.adjacent(in: run[range.upperBound..<after], from: run[range.upperBound - 1], acrossResumption: true)
                guard ArrivalMotion.supportsVisit(arriving: arriving, leaving: leaving, at: run[range.lowerBound].fix) else { continue }
            }
            if movementStart < range.lowerBound { slices.append(.move(run[movementStart..<range.lowerBound])) }
            slices.append(.stay(run[range], center: center))
            movementStart = range.upperBound
        }
        if movementStart < run.endIndex { slices.append(.move(run[movementStart...])) }
        return slices
    }

    private static func canBeAtPlace<ID>(_ point: LocationPoint<ID>) -> Bool {
        point.mode == .stationary || point.mode == .unknown
    }

    private static func observedStays<ID>(
        in points: ArraySlice<LocationPoint<ID>>, preserveNamedStart: Bool
    ) -> [(Range<Int>, CLLocationCoordinate2D)] {
        let first = points[points.startIndex]
        let last = points[points.endIndex - 1]
        let meridian = first.coordinate.longitude
        // HHTCore uses a local arithmetic centroid. Centre the longitude axis so a stay can span ±180°.
        func wrapped(_ longitude: Double) -> Double {
            if (-180...180).contains(longitude) { return longitude }
            return (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        }
        let fixes = points.map { point in
            RawPoint(timestamp: point.timestamp,
                     coordinate: Coordinate(point.coordinate.latitude, wrapped(point.coordinate.longitude - meridian)),
                     horizontalAccuracy: point.accuracy, timeZone: nil)
        }
        var config = InferenceConfig.default
        config.stayRadius = stayRadius
        config.minStayDuration = minimumVisitDuration
        config.maxHorizontalAccuracy = LocationSampling.accuracyLimit
        let detector = StayDetector(config: config)
        var stays = detector.detect(fixes, now: last.timestamp)
        var cursor = points.startIndex
        var result: [(Range<Int>, CLLocationCoordinate2D)] = []
        if preserveNamedStart, stays.first?.start != first.timestamp,
           let end = legacyNamedEnd(in: points) {
            // Older edits belong to a specific first fix. Preserve that observed visit even when
            // the newer moving centroid would trim the owner or divide its cluster.
            let count = end - cursor
            let members = fixes.prefix(count).filter { Geo.distance($0.coordinate, fixes[0].coordinate) <= stayRadius }
            let center = Geo.centroid(members.map(\.coordinate), weights: members.map { 1 / max($0.horizontalAccuracy ?? 5, 5) })
                ?? fixes[0].coordinate
            result.append((cursor..<end, CLLocationCoordinate2D(latitude: center.latitude,
                                                                longitude: wrapped(center.longitude + meridian))))
            cursor = end
            stays = detector.detect(Array(fixes.dropFirst(count)), now: last.timestamp)
        }
        for stay in stays {
            while cursor < points.endIndex, points[cursor].timestamp < stay.start { cursor += 1 }
            let start = cursor
            let end = stay.end ?? last.timestamp
            while cursor < points.endIndex, points[cursor].timestamp <= end { cursor += 1 }
            guard start < cursor,
                  points[cursor - 1].timestamp.timeIntervalSince(points[start].timestamp) >= minimumVisitDuration else { continue }
            let center = CLLocationCoordinate2D(latitude: stay.centroid.latitude,
                                                longitude: wrapped(stay.centroid.longitude + meridian))
            result.append((start..<cursor, center))
        }
        return result
    }

    /// Compatibility for a user-named visit written by the original fixed-anchor detector.
    private static func legacyNamedEnd<ID>(in points: ArraySlice<LocationPoint<ID>>) -> Int? {
        let start = points.startIndex
        let anchor = points[start].coordinate.location
        var end = start + 1
        while end < points.endIndex {
            let distance = points[end].coordinate.location.distance(from: anchor)
            if distance > stayRadius {
                let next = end + 1
                guard distance <= stayRadius + points[end].accuracy, next < points.endIndex,
                      points[next].coordinate.location.distance(from: anchor) <= stayRadius else { break }
            }
            end += 1
        }
        return points[end - 1].timestamp.timeIntervalSince(points[start].timestamp) >= minimumVisitDuration ? end : nil
    }
}
