import CoreLocation
import Foundation
import SwiftData

@main
struct RouteChecks {
    @MainActor
    static func main() async throws {
        checkNoteTranscripts()
        checkWeeklyVisits()
        try checkVisitCandidates()
        try checkTodayPlaceStays()
        try checkAutomaticTrips()
        try checkDrivingStops()
        try checkLegacyDrivingEdges()
        checkMapProjection()
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3_600)
        let first = location(longitude: 0, at: start)
        let nearby = location(longitude: 0.00012, at: start.addingTimeInterval(10))
        let farther = location(longitude: 0.00060, at: start.addingTimeInterval(20))
        let stayStart = location(longitude: 0.00061, at: start.addingTimeInterval(50))
        let stayEnd = location(longitude: 0.00062, at: start.addingTimeInterval(80))
        let afterGap = location(longitude: 0.03000, at: start.addingTimeInterval(120))
        let walking = LocationSampling(mode: .walking)
        let driving = LocationSampling(mode: .automotive)
        let stationary = LocationSampling(mode: .stationary)

        precondition(walking.assess(first, after: nil, mode: .walking)?.startsNewSegment == true)
        precondition((walking.assess(nearby, after: first, mode: .walking)?.distance ?? 0) > 10)
        precondition(driving.assess(nearby, after: first, mode: .automotive) == nil)
        precondition((driving.assess(farther, after: first, mode: .automotive)?.distance ?? 0) > 60)
        precondition(stationary.assess(farther, after: first, mode: .stationary, previousMode: .walking)?.startsNewSegment == true)
        precondition(stationary.assess(farther, after: first, mode: .stationary, previousMode: .stationary) == nil)
        let stayStep = stationary.assess(stayEnd, after: stayStart, mode: .stationary, previousMode: .stationary)
        precondition(stayStep?.startsNewSegment == false && stayStep?.distance == 0)
        precondition(walking.assess(stayEnd, after: stayStart, mode: .walking, previousMode: .stationary)?.startsNewSegment == true)
        precondition(walking.assess(farther, after: farther, mode: .walking) == nil)
        precondition(driving.assess(afterGap, after: first, mode: .automotive)?.startsNewSegment == true)
        precondition(driving.assess(afterGap, after: nil, mode: .automotive)?.distance == 0)
        precondition(driving.assess(location(longitude: 0, at: start, accuracy: 51), after: nil, mode: .automotive) == nil)
        let flyaway = location(longitude: 0.03, at: start.addingTimeInterval(5))
        precondition(driving.assess(flyaway, after: first, mode: .automotive, previousMode: .stationary) == nil)
        let heartbeat = LocationSampling(mode: .unknown).assess(stayEnd, after: stayStart, mode: .unknown)
        precondition(heartbeat?.distance == 0 && heartbeat?.startsNewSegment == false)
        checkSpeedEstimate(start: start)

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([RecordedRoute.self, RoutePoint.self])
        let configuration = ModelConfiguration(schema: schema, url: root.appending(path: "routes.store"), cloudKitDatabase: .none)
        try writeRoute(points: [first, nearby, afterGap], schema: schema, configuration: configuration)

        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let routes = try context.fetch(FetchDescriptor<RecordedRoute>())
        precondition(routes.count == 1)
        let route = routes[0]
        let points = route.points.sorted { $0.timestamp < $1.timestamp }
        precondition(route.pointCount == 3 && !route.isFinished)
        precondition(points.map(\.mode) == [.walking, .walking, .automotive])
        precondition(points.map(\.startsNewSegment) == [true, false, true])
        precondition(abs(route.distanceMeters - nearby.distance(from: first)) < 0.01)
        let savedSegments = SegmentBuilder.group(sortedPoints: points.map(\.locationPoint))
        precondition(savedSegments.map(\.mode) == [.walking, .automotive])
        precondition(savedSegments.map(\.startedAt) == [first.timestamp, afterGap.timestamp])
        precondition(savedSegments.map(\.endedAt) == [nearby.timestamp, afterGap.timestamp])
        precondition(savedSegments.map { $0.coordinates.count } == [2, 1])
        let savedReview = RouteReview(routes: routes, calendar: .current)
        precondition(savedReview.days.flatMap(\.entries).count == 1)
        precondition(savedReview.days.flatMap(\.moves).count == 1)
        context.delete(route)
        try context.save()
        let remainingPoints = try context.fetchCount(FetchDescriptor<RoutePoint>())
        precondition(remainingPoints == 0)

        let newRoute = RecordedRoute(startedAt: start)
        context.insert(newRoute)
        context.insert(RoutePoint(location: first, mode: .unknown, startsNewSegment: true, route: newRoute))
        newRoute.pointCount += 1
        try context.save()

        context.insert(RoutePoint(location: farther, mode: .cycling, startsNewSegment: false, route: newRoute))
        newRoute.pointCount += 1
        try context.save()

        context.insert(RoutePoint(location: stayStart, mode: .stationary, startsNewSegment: true, route: newRoute))
        context.insert(RoutePoint(location: stayEnd, mode: .stationary, startsNewSegment: false, route: newRoute))
        newRoute.pointCount += 2
        try context.save()
        let segments = SegmentBuilder.group(sortedPoints: newRoute.points.sorted { $0.timestamp < $1.timestamp }.map(\.locationPoint))
        precondition(segments.map(\.mode) == [.unknown, .cycling, .stationary])
        precondition(segments[1].startedAt == farther.timestamp && segments[1].startCoordinate.longitude == farther.coordinate.longitude)
        precondition(segments[1].coordinates.count == 2)
        precondition(segments[2].startedAt == stayStart.timestamp && segments[2].endedAt == stayEnd.timestamp)
        precondition(segments[2].coordinates.count == 1)
        checkPureSegmentBuilder(at: start)
        try checkPhotoMatching(context: context, start: start)
        try checkReview(context: context)
        try checkTripBoundaries(context: context, start: start)
        checkCoverageDates()
        try checkRouteReviewCache(context: context)
        try checkSemanticTimeline(context: context)
        try checkBehavior(context: context)
        try await checkInsights(context: context, directory: root)
        try checkPlaceSuggestions(context: context)
        try checkPlaceNames(in: root)
        try checkRankedPlaceNames()
        try await checkSummaryIndex(context: context, directory: root)
        try await checkPlaceResolver(in: root)
        try await checkMainlandPlaceLookup(in: root)
        await checkSharedPlaceCancellation(in: root)
        try await checkPlacePrefetch(in: root)
        let protected = insertRoute(context: context, start: start, samples: [(0, 0, .walking, true), (30, 0.0003, .walking, false)])
        try context.save()
        let key = RouteReview(routes: [protected], calendar: .current).days[0].entries[0].memoryKey!
        _ = protected.memories?.count
        do {
            try key.update(in: container) { memory, _ in
                memory.draft = "unwritten"
                throw CocoaError(.fileWriteOutOfSpace)
            }
            preconditionFailure("Expected the injected write failure")
        } catch let failure as CocoaError { precondition(failure.code == .fileWriteOutOfSpace) }
        try key.update(in: container) { memory, _ in memory.draft = "retried" }
        context.insert(RecordedRoute(startedAt: start))
        try context.save()
        let fresh = ModelContext(container)
        let retainedOwner = try fresh.fetch(FetchDescriptor<RecordedRoute>()).first { $0.id == protected.id }
        let retainedNote = try key.memory(in: fresh)
        precondition(retainedOwner?.points.count == 2 && retainedNote.draft == "retried")
        _ = retainedNote.photos?.count
        try key.update(in: container) { memory, writer in
            let photo = MemoryPhoto(memory: memory, assetID: "cross-context-photo")
            photo.image = Data(repeating: 7, count: 200_000)
            writer.insert(photo)
        }
        let originalPointIDs = Set(protected.points.map(\.persistentModelID))
        try protected.deleteWithMemories(in: context)
        try context.save()
        let afterRemoval = ModelContext(container)
        let keyValue = key.value
        let orphanCount = try afterRemoval.fetchCount(FetchDescriptor<RouteMemory>(predicate: #Predicate { $0.key == keyValue }))
        let pointsAfterRemoval = try afterRemoval.fetch(FetchDescriptor<RoutePoint>())
        let orphanPhotos = try afterRemoval.fetchCount(FetchDescriptor<MemoryPhoto>(predicate: #Predicate { $0.assetID == "cross-context-photo" }))
        precondition(orphanPhotos == 0)
        precondition(orphanCount == 0 && pointsAfterRemoval.allSatisfy { !originalPointIDs.contains($0.persistentModelID) })
        try checkPhotoAttachments(context: context, start: start)
        print("Passed map projection, sampling, persistence, deletion, daily review, visit grouping, and place name checks.")
    }

    @MainActor
    private static func checkPhotoAttachments(context: ModelContext, start: Date) throws {
        let a = insertRoute(context: context, start: start, samples: [(0, 0, .walking, true), (20, 0.001, .walking, false)])
        let b = insertRoute(context: context, start: start.addingTimeInterval(60), samples: [(0, 0, .walking, true), (20, 0.001, .walking, false)])
        try context.save()
        let source = RouteMemoryKey(owner: a.id, start: a.startedAt)
        let destination = RouteMemoryKey(owner: b.id, start: b.startedAt)
        let asset = "same-synthetic-asset"
        let container = context.container
        for key in [source, source, destination] {
            try key.update(in: container) { memory, writer in
                let photo = try memory.attachment(for: asset, in: writer)
                photo.thumbnail = Data([2])
            }
        }
        func copies() throws -> [MemoryPhoto] {
            try ModelContext(container).fetch(FetchDescriptor<MemoryPhoto>(predicate: #Predicate { $0.assetID == asset }))
        }
        let both = try copies()
        precondition(both.count == 2 && Set(both.compactMap { $0.memory?.key }) == [source.value, destination.value])
        for key in [source, destination] {
            try key.update(in: container) { memory, writer in
                let photo = try memory.attachment(for: asset, in: writer)
                photo.setVoice(audio: Data([1]), duration: 1, transcript: key.value)
            }
        }
        do {
            try destination.update(in: container) { target, writer in
                try source.memory(in: writer).attachment(for: asset, in: writer).move(to: target, in: writer)
            }
            preconditionFailure("A move must preserve both existing voice memos")
        } catch MemoryPhoto.MoveError.bothHaveVoice {}
        let retained = try copies()
        precondition(Set(retained.compactMap(\.voiceTranscript)) == [source.value, destination.value])
        try source.update(in: container) { memory, writer in
            try memory.attachment(for: asset, in: writer).setVoice(audio: nil, duration: nil, transcript: nil)
        }
        let secondAsset = "only-at-source"
        let pixels = Data(repeating: 42, count: 256_000)
        try source.update(in: container) { memory, writer in
            let original = try memory.attachment(for: secondAsset, in: writer)
            original.image = pixels
            original.thumbnail = Data([4])
            original.taken = start
            original.setVoice(audio: pixels, duration: 4, transcript: "Synthetic voice")
        }
        let cachedSource = try source.memory(in: context)
        precondition(cachedSource.photos?.count == 2)
        try destination.update(in: container) { target, writer in
            let origin = try source.memory(in: writer)
            let photo = try origin.attachment(for: asset, in: writer)
            try photo.move(to: target, in: writer)
            try origin.attachment(for: secondAsset, in: writer).move(to: target, in: writer)
        }
        try a.deleteWithMemories(in: context)
        try context.save()
        let moved = try copies()
        precondition(moved.count == 1 && moved[0].memory?.key == destination.value)

        let reopened = ModelContext(container)
        let transferred = try reopened.fetch(FetchDescriptor<MemoryPhoto>(predicate: #Predicate { $0.assetID == secondAsset }))
        precondition(transferred.count == 1 && transferred[0].memory?.key == destination.value)
        precondition(transferred[0].image == pixels && transferred[0].thumbnail == Data([4]) && transferred[0].taken == start)
        precondition(transferred[0].voiceAudio == pixels && transferred[0].voiceDuration == 4)
        precondition(transferred[0].voiceTranscript == "Synthetic voice")
        try destination.update(in: container) { memory, writer in
            try memory.attachment(for: secondAsset, in: writer).hide(in: writer)
            try memory.attachment(for: asset, in: writer).hide(in: writer)
            _ = try memory.attachment(for: nil, in: writer)
        }
        let prior = try destination.memory(in: ModelContext(container)).owner?.visitRevision
        try destination.update(in: container) { memory, writer in
            let photo = memory.photos!.first { $0.assetID == nil }!
            photo.hide(in: writer)
        }
        let after = try destination.memory(in: ModelContext(container))
        let hidden = after.photos?.first { $0.assetID == secondAsset }
        precondition(hidden?.hidden == true && hidden?.voiceDuration == nil && hidden?.voiceAudio == nil && hidden?.voiceTranscript == nil)
        precondition(!after.isAnnotated && after.owner?.visitRevision != prior)
    }

    @MainActor
    private static func checkPhotoMatching(context: ModelContext, start: Date) throws {
        let samples: [Sample] = [(0, 0, .walking, true), (30, 0.0004, .walking, false),
                                 (300, 0.002, .walking, true), (330, 0.0024, .walking, false)]
        let route = insertRoute(context: context, start: start, samples: samples)
        try context.save()
        let day = RouteReview(routes: [route], calendar: .current).days[0]
        let time = start.addingTimeInterval(15)
        let near = CLLocationCoordinate2D(latitude: 0, longitude: 0.0002)
        let far = CLLocationCoordinate2D(latitude: 1, longitude: 1)
        precondition(day.memoryKey(forPhotoAt: time, coordinate: nil) != nil)
        precondition(day.memoryKey(forPhotoAt: time, coordinate: near) != nil)
        precondition(day.memoryKey(forPhotoAt: time, coordinate: far) == nil)
        precondition(day.memoryKey(forPhotoAt: start.addingTimeInterval(100), coordinate: nil) == nil)
        let second = insertRoute(context: context, start: start, samples: samples)
        try context.save()
        let overlap = RouteReview(routes: [route, second], calendar: .current).days[0]
        precondition(overlap.memoryKey(forPhotoAt: time, coordinate: nil) == nil)
        precondition(overlap.memoryKey(forPhotoAt: time, coordinate: near) == nil)
        let distant = insertRoute(context: context, start: start, samples: [(0, 1, .walking, true), (30, 1.001, .walking, false)])
        try context.save()
        let ambiguous = RouteReview(routes: [route, distant], calendar: .current).days[0]
        precondition(ambiguous.memoryKey(forPhotoAt: time, coordinate: near) == nil)
        let later = insertRoute(context: context, start: start.addingTimeInterval(3600), samples: samples)
        try context.save()
        let allDay = RouteReviewCache().review(routes: [route, later], calendar: .current).days[0]
        precondition(allDay.memoryKey(forPhotoAt: time.addingTimeInterval(3600), coordinate: near)?.owner == later.id)
        precondition(allDay.placement(forPhotoAt: time.addingTimeInterval(3600), coordinate: near, in: day) == .outsideDetail)
        precondition(ambiguous.placement(forPhotoAt: time, coordinate: near, in: day) == .pending)
        let midnight = Calendar.current.startOfDay(for: start)
        let early = insertRoute(context: context, start: midnight.addingTimeInterval(-32), samples: [(0, 0, .walking, true), (64, 0.001, .walking, false)])
        let late = insertRoute(context: context, start: midnight.addingTimeInterval(-20), samples: [(0, 1, .walking, true), (40, 1.001, .walking, false)])
        try context.save()
        let overnight = RouteReviewCache().day(routes: [late, early], containing: midnight, calendar: .current).days[0]
        precondition(overnight.entries.count == 2 && overnight.memoryKey(forPhotoAt: midnight.addingTimeInterval(8), coordinate: near) == nil)
    }

    private static func checkNoteTranscripts() {
        var speech = NoteTranscript()
        precondition(speech.update("到了公元", range: nil, settled: false) == "到了公元")
        precondition(speech.update("到了公园。", range: 0.3..<2.1, settled: true) == "到了公园。")
        precondition(speech.update("看见白", range: nil, settled: false) == "到了公园。看见白")
        precondition(speech.update("看见白鹭。", range: 4.0..<5.8, settled: true) == "到了公园。看见白鹭。")
        precondition(speech.update("看见白鹭！", range: 4.05..<5.9, settled: true) == "到了公园。看见白鹭！")
        precondition(speech.update("到了公园。看见白鹭！", range: 0.3..<5.9, settled: true) == "到了公园。看见白鹭！")
        precondition(speech.update("到了公园。看见白鹭！", range: nil, settled: false) == "到了公园。看见白鹭！")
        precondition(NoteTranscript.join("午后", "散步") == "午后散步" && NoteTranscript.join("River", "walk") == "River walk")
        var repeated = NoteTranscript()
        precondition(repeated.update("好", range: 0..<1, settled: true) == "好")
        precondition(repeated.update("好想再来", range: nil, settled: false) == "好好想再来")
        precondition(repeated.update("好", range: 3..<4, settled: true) == "好好")
        precondition(repeated.update("好想再来", range: nil, settled: false) == "好好好想再来")
        var interrupted = NoteTranscript()
        _ = interrupted.update("出发。", range: 0.3..<1, settled: true)
        _ = interrupted.update("好", range: 3..<4, settled: true)
        precondition(interrupted.update("好", range: nil, settled: true) == "出发。好")
        precondition(interrupted.update("好想再来", range: nil, settled: false) == "出发。好好想再来")
        precondition(interrupted.update("好想再来", range: nil, settled: true) == "出发。好好想再来")
    }

    private static func checkMapProjection() {
        let coverageURL = URL(fileURLWithPath: "LifeMem/AMapMainlandCoverage.json")
        let projection = RouteMapProjection(coverageURL: coverageURL)
        let mainlandExamples = [
            // Beijing and Shanghai public example coordinates with reference conversion results.
            (39.9, 116.3, 39.90126009494757, 116.30607290385822),
            (31.2304, 121.4737, 31.22845773757727, 121.47822305927693)
        ]
        for (latitude, longitude, expectedLatitude, expectedLongitude) in mainlandExamples {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let projected = projection.coordinate(for: coordinate)
            precondition(abs(projected.latitude - expectedLatitude) < 1e-9)
            precondition(abs(projected.longitude - expectedLongitude) < 1e-9)
        }

        let haikou = CLLocationCoordinate2D(latitude: 20.02, longitude: 110.33)
        precondition(projection.coordinate(for: haikou).longitude != haikou.longitude)
        let outsideCoverage = [
            (22.2819, 114.1581), (22.1943, 113.5438), (25.034, 121.5654), // Hong Kong, Macao, Taipei
            (21.0278, 105.8342), (37.5665, 126.978), (47.9186, 106.9176), // Hanoi, Seoul, Ulaanbaatar
            (35.6762, 139.6503), (37.78, -122.42), (91.0, 116.3)
        ]
        for (latitude, longitude) in outsideCoverage {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let projected = projection.coordinate(for: coordinate)
            precondition(projected.latitude == latitude && projected.longitude == longitude)
        }
        let invalid = projection.coordinate(for: .init(latitude: .nan, longitude: 116.3))
        precondition(invalid.latitude.isNaN && invalid.longitude == 116.3)

        let missingCoverage = RouteMapProjection(coverageURL: nil)
        let unchanged = missingCoverage.coordinate(for: haikou)
        precondition(unchanged.latitude == haikou.latitude && unchanged.longitude == haikou.longitude)
    }

    private static func checkPureSegmentBuilder(at start: Date) {
        let points = (0...16).map { index in
            LocationPoint(id: index, timestamp: start.addingTimeInterval(Double(index) * 30),
                          coordinate: .init(latitude: 0, longitude: 0), accuracy: 5,
                          mode: .unknown, startsNewSegment: index == 0, startsRecordingRun: index == 0)
        }
        let split = LocationPoint(id: 17, timestamp: start.addingTimeInterval(540),
                                  coordinate: .init(latitude: 0, longitude: 0.001), accuracy: 5,
                                  mode: .walking, startsNewSegment: true, startsRecordingRun: true)
        let runs = SegmentBuilder.build([split] + points.reversed())
        precondition(runs.count == 2 && runs.allSatisfy { $0.count == 1 })
        precondition(runs[0][0].visitCoordinate?.longitude == 0)
        precondition(runs[0][0].points.first?.id == 0 && runs[0][0].points.last?.id == 16)
        precondition(runs[1][0].visitCoordinate == nil && runs[1][0].points.first?.id == 17)
        let repeatedTime = LocationPoint(id: 18, timestamp: start,
                                         coordinate: .init(latitude: 0, longitude: 0.005), accuracy: 5,
                                         mode: .unknown, startsNewSegment: false, startsRecordingRun: false)
        let duplicate = SegmentBuilder.group(sortedPoints: [points[0], repeatedTime], inferModes: true, trailingStayPoint: repeatedTime)
        precondition(duplicate.count == 1 && duplicate[0].mode == .unknown && duplicate[0].distanceMeters == 0)
    }

    @MainActor
    private static func checkSemanticTimeline(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let homeEnd = 8 * 3_600
        let walkEnd = homeEnd + 600
        let driveEnd = walkEnd + 1_200
        let workStart = driveEnd + 30
        let route = RecordedRoute(startedAt: day)
        context.insert(route)

        func add(_ seconds: Int, longitude: Double, mode: TravelMode, accuracy: Double = 5, boundary: Bool = false) {
            context.insert(RoutePoint(
                location: location(longitude: longitude, at: day.addingTimeInterval(Double(seconds)), accuracy: accuracy),
                mode: mode,
                startsNewSegment: boundary || seconds == homeEnd,
                startsRecordingRun: boundary,
                route: route
            ))
        }

        for seconds in stride(from: 0, to: homeEnd, by: 30) {
            let drift = seconds == homeEnd - 30 ? 0 : Double((seconds / 30) % 5 - 2) * 0.0001
            if seconds == 4 * 3_600 {
                add(seconds, longitude: 0.00072, mode: .stationary, accuracy: 45)
            } else {
                add(seconds, longitude: drift, mode: seconds % 60 == 0 ? .unknown : .stationary)
            }
        }
        add(301, longitude: 0.04, mode: .unknown, accuracy: 70)
        add(601, longitude: 0.04, mode: .unknown)
        for seconds in stride(from: homeEnd, through: walkEnd, by: 30) {
            add(seconds, longitude: Double(seconds - homeEnd) * 0.00001, mode: seconds == homeEnd ? .walking : .unknown)
        }
        for seconds in stride(from: walkEnd + 30, through: driveEnd, by: 30) {
            add(seconds, longitude: 0.006 + Double(seconds - walkEnd) * 0.00012, mode: .automotive)
        }
        for seconds in stride(from: workStart, through: workStart + 4 * 3_600, by: 30) {
            add(seconds, longitude: 0.15, mode: .stationary)
        }
        // Resuming in a different motion state still starts a new observation run.
        add(workStart + 4 * 3_600 + 20, longitude: 0.151, mode: .walking, boundary: true)
        try context.save()

        let review = RouteReview(routes: [route], calendar: calendar)
        let entries = review.days[0].entries
        let events = review.days[0].timeline
        guard events.count == 4,
              case let .stay(home) = events[0],
              case let .move(walk) = events[1],
              case let .move(drive) = events[2],
              case let .stay(work) = events[3] else {
            preconditionFailure("Expected home, walk, drive, work.")
        }
        precondition(abs(home.coordinate.longitude) < 0.00001)
        precondition(home.duration == Double(homeEnd - 30) && work.duration == 4 * 3_600)
        precondition(walk.mode == .walking && walk.duration == 600)
        precondition(drive.mode == .automotive && drive.duration == 1_200)
        let expected = location(longitude: 0, at: day).distance(from: location(longitude: 0.15, at: day))
        precondition(abs(review.days[0].movingDistanceMeters - expected) < 5)
        precondition(review.days[0].movingDuration == 1_800 && review.days[0].stays.count == 2)
        precondition(entries.last?.kind == .fragment && entries.last?.followsGap == true)

        let shortTrip = insertRoute(context: context, start: day, samples: stop(start: 0, longitude: 0) + [
            (510, 0.002, .automotive, true)
        ] + stop(start: 540, longitude: 0.004))
        let shortTimeline = RouteReview(routes: [shortTrip], calendar: calendar).days[0].timeline
        guard shortTimeline.count == 3, case let .move(move) = shortTimeline[1] else {
            preconditionFailure("A single moving sample should retain both observed edges.")
        }
        precondition(move.mode == .automotive && move.duration == 60 && move.distanceMeters > 440)
        precondition(move.coordinates.first?.longitude == 0 && move.coordinates.last?.longitude == 0.004)
    }

    @MainActor
    private static func checkReview(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let previousDay = day.addingTimeInterval(-86_400)
        let nextDay = day.addingTimeInterval(86_400)
        let morning = day.addingTimeInterval(8 * 3_600)
        let destination = 0.0100

        let outing = insertRoute(
            context: context,
            start: morning,
            samples: [
                (0, 0.0, .walking, true),
                (15, 0.0003, .walking, false),
                (30, 0.0030, .automotive, false),
                (45, 0.0040, .unknown, false),
                (60, 0.0040, .stationary, true),
                (90, 0.0040, .stationary, false),
                (110, 0.0042, .automotive, true),
                (130, 0.0099, .automotive, false)
            ] + stop(start: 150, longitude: destination) + [
                (655, 0.0099, .walking, true),
                (670, 0.0096, .walking, false),
                (690, 0.0003, .automotive, false),
                (705, 0.0, .walking, false),
                (730, 0.03, .walking, true),
                (745, 0.0302, .walking, false),
                (880, 0.04, .walking, false),
                (895, 0.0402, .walking, false)
            ]
        )
        let repeatedVisit = insertRoute(
            context: context,
            start: morning.addingTimeInterval(-86_400),
            samples: [(0, 0.0, .walking, true), (20, destination, .walking, false)]
                + stop(start: 35, longitude: destination + 0.0002)
        )
        let drift = insertRoute(
            context: context,
            start: morning.addingTimeInterval(3_600),
            samples: stride(from: 0, through: 300, by: 30).map {
                (TimeInterval($0), 0.02 + Double($0) * 0.0001, .stationary, $0 == 0)
            }
        )
        try context.save()

        let review = RouteReview(routes: [outing, repeatedVisit, drift], calendar: calendar)
        precondition(review.days.map(\.date) == [day, previousDay])
        let today = review.days[0].entries
        precondition(today.map(\.kind) == [.trip, .visit, .trip, .trip, .fragment])
        precondition(today[0].segments.map(\.mode) == [.walking, .automotive, .stationary, .automotive])
        precondition(today[1].endedAt.timeIntervalSince(today[1].startedAt) == 480)
        precondition(today[0].endpoints?.start.longitude == 0)
        precondition(today[0].endpoints?.end.longitude == destination)
        precondition(today[1].visitCoordinate?.longitude == destination)
        precondition(today[2].endpoints?.start.longitude == destination)
        precondition(today[2].endpoints?.end.longitude == 0)
        precondition(today[3].endpoints?.start.longitude == 0.03)
        precondition(today[2].segments.last?.coordinates.last?.longitude == 0)
        precondition(today[0].segments.first?.coordinates.first?.longitude == 0)
        precondition(today.filter(\.followsGap).map(\.startedAt) == [morning.addingTimeInterval(730)])
        precondition(today[3].segments[1].coordinates.map(\.longitude) == [0.04, 0.0402])
        precondition(review.places.map { $0.visits.count } == [2])
        precondition(review.places[0].visits.map(\.date) == [previousDay, day])
        precondition(review.places[0].mostRecentVisit.id == today[1].id)

        let crossMidnight = insertRoute(
            context: context,
            start: nextDay.addingTimeInterval(-30),
            samples: [
                (0, 0.0, .walking, true),
                (20, 0.0002, .walking, false),
                (40, 0.0004, .walking, false),
                (60, 0.0006, .walking, false)
            ]
        )
        let overnightVisit = insertRoute(
            context: context,
            start: nextDay.addingTimeInterval(-120),
            samples: stop(start: 0, longitude: 0.05)
        )
        try context.save()

        let midnightReview = RouteReview(routes: [crossMidnight, overnightVisit], calendar: calendar)
        precondition(midnightReview.days.map(\.date) == [nextDay, day])
        precondition(midnightReview.places.map { $0.visits.count } == [1])
        let before = midnightReview.days[1]
        let after = midnightReview.days[0]
        precondition(before.entries.count == 2 && after.entries.count == 2)
        let beforeTrip = before.entries.first { $0.kind == .trip }!
        let afterTrip = after.entries.first { $0.kind == .trip }!
        let boundary = beforeTrip.segments[0].coordinates.last!.longitude
        precondition(abs(boundary - 0.0003) < 1e-8)
        precondition(beforeTrip.segments[0].coordinates.map(\.longitude) == [0.0, 0.0002, boundary])
        precondition(afterTrip.segments[0].coordinates.map(\.longitude) == [boundary, 0.0004, 0.0006])
        precondition(beforeTrip.endpoints?.end.longitude == boundary && afterTrip.endpoints?.start.longitude == boundary)
        precondition(beforeTrip.endedAt == nextDay && afterTrip.startedAt == nextDay)
        precondition(after.stays[0].startedAt == nextDay && before.stays[0].endedAt == nextDay)
        precondition(after.stays[0].visitID == before.stays[0].visitID)
        precondition(after.stays[0].duration + before.stays[0].duration == 480)
        precondition(midnightReview.places[0].mostRecentVisit.id == before.stays[0].id)

        let bothDays = RouteAnalytics(review: midnightReview, range: day...nextDay, calendar: calendar, now: nextDay.addingTimeInterval(86_400)) { _ in .home }
        precondition(bothDays.days.map(\.date) == [day, nextDay])
        precondition(bothDays.time.first { $0.use == .home }?.seconds == 420)
        precondition(bothDays.time.first { $0.use == .moving }?.seconds == 60)
        precondition(bothDays.elapsedDuration == 2 * 86_400 && bothDays.trackedDuration == 480)
        precondition(bothDays.time.first { $0.use == .untracked }?.seconds == 2 * 86_400 - 480)
        precondition(midnightReview.days.allSatisfy { $0.movingDuration == 30 })
        precondition(bothDays.places.count == 1 && bothDays.places[0].visits == 1 && bothDays.places[0].seconds == 480)
        let onlyNextDay = RouteAnalytics(review: midnightReview, range: nextDay...nextDay, calendar: calendar, now: nextDay.addingTimeInterval(86_400)) { _ in nil }
        precondition(onlyNextDay.time.first { $0.use == .other }?.seconds == 330)
        precondition(onlyNextDay.places[0].visits == 1 && onlyNextDay.places[0].seconds == 360)

        let midnightEdge = insertRoute(context: context, start: nextDay.addingTimeInterval(-10), samples: [
            (0, 0, .walking, true), (20, 0.0002, .walking, false)
        ])
        let midnightOnly = RouteReview(routes: [midnightEdge], calendar: calendar)
        precondition(midnightOnly.days.allSatisfy { $0.movingDuration == 10 && $0.movingDistanceMeters > 10 })
        precondition(midnightOnly.days.allSatisfy { $0.moves.count == 1 && $0.moves[0].coordinates.count == 2 })
        let wholeDistance = location(longitude: 0, at: day).distance(from: location(longitude: 0.0002, at: nextDay))
        precondition(abs(midnightOnly.days.reduce(0) { $0 + $1.movingDistanceMeters } - wholeDistance) < 0.01)

        let exactMidnight = insertRoute(context: context, start: nextDay.addingTimeInterval(-10), samples: [
            (0, 0, .walking, true), (10, 0.0002, .walking, false), (20, 0.0004, .walking, false)
        ])
        let exactDays = RouteReview(routes: [exactMidnight], calendar: calendar).days
        precondition(exactDays.allSatisfy { $0.moves.count == 1 && $0.moves[0].duration == 10 })
        precondition(exactDays[1].moves[0].coordinates.last?.longitude == 0.0002)
        precondition(exactDays[0].moves[0].coordinates.first?.longitude == 0.0002)

        let gap = insertRoute(context: context, start: nextDay.addingTimeInterval(-60), samples: [
            (0, 0, .walking, true), (120, 0.001, .walking, false)
        ])
        let gapDays = RouteReview(routes: [gap], calendar: calendar).days
        precondition(gapDays.count == 2 && gapDays.allSatisfy { $0.moves.isEmpty })
        precondition(gapDays.allSatisfy { $0.entries.count == 1 && $0.movingDuration == 0 })

        let dateline = insertRoute(context: context, start: nextDay.addingTimeInterval(-10), samples: [
            (0, 179.9998, .walking, true), (20, -179.9998, .walking, false)
        ])
        let datelineDays = RouteReview(routes: [dateline], calendar: calendar).days
        precondition(datelineDays.allSatisfy { $0.moves.count == 1 })
        precondition(abs(abs(datelineDays[0].moves[0].coordinates[0].longitude) - 180) < 1e-8)

        let longVisit = insertRoute(context: context, start: morning, samples: stride(from: 0, through: 1_200, by: 30).map {
            (Double($0), 0.05, .stationary, $0 == 0)
        })
        let rankedReview = RouteReview(routes: [outing, repeatedVisit, longVisit], calendar: calendar)
        let ranked = RouteAnalytics(review: rankedReview, range: previousDay...day, calendar: calendar, now: nextDay) { _ in nil }
        precondition(ranked.topPlaces(by: .visits).first?.visits == 2)
        precondition(ranked.topPlaces(by: .duration).first?.seconds == 1_200)
    }

    @MainActor
    private static func checkTripBoundaries(context: ModelContext, start: Date) throws {
        let approaching: [Sample] = [(0, 0, .automotive, true), (30, 0.002, .automotive, false)]
        let sparse: [Sample] = (1...5).map { i in
            (30 + Double(i * 91), 0.002 + Double(i) * 0.00005, .automotive, true)
        }
        func entries(_ samples: [Sample], automatic: Bool = true) -> [RouteReviewEntry] {
            let route = insertRoute(context: context, start: start, samples: samples)
            route.isAutomatic = automatic
            return RouteReview(routes: [route], calendar: .current).days.flatMap(\.entries)
        }
        let traffic = entries(approaching + sparse + [(510, 0.004, .automotive, false)])
        precondition(traffic.map(\.kind) == [.trip] && traffic[0].moves.count == 2)
        precondition(traffic[0].endedAt == start.addingTimeInterval(510))
        precondition(traffic[0].moves.reduce(0) { $0 + $1.duration } == 55)

        let shop = stop(start: 530, longitude: 0.004)
        let departure: [Sample] = [(1_040, 0.0046, .walking, true), (1_070, 0.005, .walking, false)]
        let visits = entries(approaching + sparse + shop + departure)
        precondition(visits.map(\.kind) == [.trip, .visit, .trip] && visits[1].stay?.duration == 480)

        // Two nearby fixes across a blind interval cannot establish a visit.
        let blind: [Sample] = [(60, 0.002, .stationary, true), (1_260, 0.002, .stationary, true)]
        let tunnel = entries(approaching + blind + [(1_290, 0.003, .automotive, true), (1_320, 0.005, .automotive, false)])
        precondition(tunnel.map(\.kind) == [.trip] && tunnel[0].moves.allSatisfy { $0.duration <= 30 })
        let noFlag = entries(approaching + [(1_350, 0.12, .automotive, false), (1_380, 0.122, .automotive, false)])
        precondition(noFlag.map(\.kind) == [.trip] && noFlag[0].moves.map(\.duration) == [30, 30])

        let interruptedDwell: [Sample] = [(60, 0.002, .stationary, false), (90, 0.002, .stationary, false),
                                          (540, 0.002, .stationary, true), (570, 0.002, .stationary, false)]
        precondition(entries(approaching + interruptedDwell + departure).map(\.kind) == [.trip])

        let named = insertRoute(context: context, start: start, samples:
            [(0, -0.00045, .stationary, true)] + stop(start: 30, longitude: 0) +
            [(750, 0.05, .walking, false), (780, 0.051, .walking, false)] + stop(start: 1_230, longitude: 0.1))
        let owner = named.points.first { $0.timestamp == start }!
        for point in named.points { point.startsRecordingRun = point === owner }
        owner.visitName = "旧地名"
        try context.save()
        let old = RouteReview(routes: [named], calendar: .current)
        let edited = old.days.flatMap(\.stays).first!
        precondition(edited.visitID == owner.persistentModelID && edited.visitName == "旧地名")
        let journey = old.journeys.first!
        precondition(journey.departureStay == nil && journey.arrivalStay == nil)
        precondition(journey.endpoints.startName == nil && journey.endpoints.endName == nil)
        try VisitCorrection.save(edited, name: "新地名", in: context)
        precondition(owner.visitName == "新地名")
        try VisitCorrection.save(edited, name: nil, in: context)
        precondition(owner.visitName == nil)

        // All fixes fit the old named anchor radius, while HHTCore's moving centre sees two clusters.
        var wideSamples: [Sample] = [(0, 0, .stationary, true)]
        for offset in stride(from: 30, through: 900, by: 30) {
            let longitude = offset <= 180 ? 0.00049 : -0.00049
            wideSamples.append((TimeInterval(offset), longitude, .stationary, false))
        }
        let wide = insertRoute(context: context, start: start, samples: wideSamples)
        let wideOwner = wide.points.first { $0.timestamp == start }!
        wideOwner.visitName = "原有名称"
        try context.save()
        let wideStays = RouteReview(routes: [wide], calendar: .current).days.flatMap(\.stays)
        precondition(wideStays.count == 1 && wideStays[0].visitID == wideOwner.persistentModelID)
        precondition(wideStays[0].visitName == wideOwner.visitName && wideStays[0].duration == 900)

        let isolatedEdges = insertRoute(context: context, start: start, samples:
            stop(start: 0, longitude: 0) + [(510, 0, .walking, true), (900, 0.02, .walking, false),
            (930, 0.021, .walking, false), (1_410, 0.05, .walking, false)] + stop(start: 1_440, longitude: 0.05))
        let measured = RouteReview(routes: [isolatedEdges], calendar: .current).journeys
        precondition(measured.count == 1 && measured[0].departureStay == nil && measured[0].arrivalStay == nil)
        precondition(measured[0].endpoints.start.longitude == 0.02 && measured[0].endpoints.end.longitude == 0.021)

        let rejoined = insertRoute(context: context, start: start, samples: approaching + [
            (110, 0.0021, .automotive, true), (140, 0.003, .automotive, false)
        ])
        let resumed = rejoined.points.first { $0.timestamp == start.addingTimeInterval(110) }!
        resumed.startsRecordingRun = true
        rejoined.isAutomatic = true
        let automatic = RouteReview(routes: [rejoined], calendar: .current)
        precondition(automatic.days.flatMap(\.entries).count == 1 && automatic.days.flatMap(\.moves).count == 2)
        rejoined.isAutomatic = false
        let manual = RouteReview(routes: [rejoined], calendar: .current)
        precondition(manual.days.flatMap(\.entries).map(\.kind) == [.trip, .trip])
    }

    private static func checkCoverageDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let empty = RouteSummary(records: [])
        for (month, day, length) in [(3, 8, 23), (11, 1, 25)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let next = calendar.date(byAdding: .day, value: 1, to: date)!
            let analytics = RouteAnalytics(summary: empty, range: date...date, calendar: calendar, now: next) { _ in nil }
            precondition(analytics.days.count == 1 && analytics.elapsedDuration == Double(length * 3_600))
            precondition(analytics.time.count == 1 && analytics.time[0].use == .untracked)
        }
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let now = today.addingTimeInterval(4_321)
        let analytics = RouteAnalytics(summary: empty, range: today...tomorrow, calendar: calendar, now: now) { _ in nil }
        precondition(analytics.days.map(\.date) == [today] && analytics.elapsedDuration == 4_321)
        let future = RouteAnalytics(summary: empty, range: tomorrow...tomorrow, calendar: calendar, now: now) { _ in nil }
        precondition(future.days.isEmpty && future.elapsedDuration == 0)
    }

    @MainActor
    private static func checkRouteReviewCache(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_006_400))
        let nextDate = calendar.date(byAdding: .day, value: 1, to: date)!
        let walk = insertRoute(context: context, start: date.addingTimeInterval(23 * 3_600), samples: [
            (0, 0, .walking, true), (30, 0.0003, .walking, false)
        ])
        let stay = insertRoute(context: context, start: nextDate.addingTimeInterval(3_600), samples: stop(start: 0, longitude: 0.01))
        try context.save()

        let cache = RouteReviewCache()
        let original = cache.review(routes: [walk, stay], calendar: calendar)
        precondition(original.days.map(\.date) == [nextDate, date] && original.days[1].movingDuration == 30)
        let secondReader = cache.review(routes: [walk, stay], calendar: calendar)
        precondition(secondReader.days.flatMap(\.entries).map(\.id) == original.days.flatMap(\.entries).map(\.id))

        let fix = location(longitude: 0.0006, at: walk.startedAt.addingTimeInterval(60))
        context.insert(RoutePoint(location: fix, mode: .walking, startsNewSegment: false, startsRecordingRun: false, route: walk))
        walk.pointCount += 1
        try context.save()
        let afterAppend = cache.review(routes: [walk, stay], calendar: calendar)
        precondition(afterAppend.days[1].movingDuration == 60)
        precondition(afterAppend.places[0].visits[0].id == original.places[0].visits[0].id)

        context.delete(walk)
        try context.save()
        let afterDeletion = cache.review(routes: [stay], calendar: calendar)
        precondition(afterDeletion.days.map(\.date) == [nextDate] && afterDeletion.journeys.isEmpty)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3_600)!
        let shifted = cache.review(routes: [stay], calendar: calendar)
        precondition(shifted.days[0].date == calendar.startOfDay(for: stay.startedAt) && shifted.days[0].date != nextDate)

        let previousDefault = NSTimeZone.default
        defer { NSTimeZone.default = previousDefault }
        let automatic = Calendar.autoupdatingCurrent
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        let beforeChange = cache.review(routes: [stay], calendar: automatic)
        NSTimeZone.default = TimeZone(identifier: "Pacific/Honolulu")!
        let afterChange = cache.review(routes: [stay], calendar: automatic)
        precondition(afterChange.days[0].date == automatic.startOfDay(for: stay.startedAt))
        precondition(beforeChange.days[0].date != afterChange.days[0].date)
    }

    @MainActor
    private static func checkSummaryIndex(context: ModelContext, directory: URL) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_006_400))
        let next = calendar.date(byAdding: .day, value: 1, to: start)!
        let walk = insertRoute(context: context, start: next.addingTimeInterval(-30), samples: [
            (0, 0, .walking, true), (20, 0.0003, .walking, false),
            (40, 0.0006, .walking, false), (60, 0.0009, .walking, false)
        ])
        let stay = insertRoute(context: context, start: next.addingTimeInterval(-120), samples: stop(start: 0, longitude: 0.01))
        try context.save()
        let routes = [walk, stay]
        let original = RouteReview(routes: routes, calendar: calendar)
        let cache = RouteReviewCache()
        let revision = RouteReviewRevision(calendar: calendar, routes: routes)
        let file = directory.appending(path: "daily-summary.json")
        let index = RouteSummaryIndex(file: file)
        let records = cache.summaries(for: routes, revision: revision, indexed: [:])
        await index.save(records, for: revision)

        let reopened = RouteSummaryIndex(file: file)
        let loaded = await reopened.records(for: revision)
        let summary = RouteSummary(records: revision.routes.compactMap { loaded[$0] })
        precondition(loaded.count == 2 && summary.days.map(\.movingDuration) == original.days.map(\.movingDuration))
        precondition(summary.places.map(\.id) == original.places.map(\.id))
        precondition(summary.journeys.map(\.duration) == original.journeys.map(\.duration))
        precondition(summary.days.flatMap(\.stays).map(\.visitID) == original.days.flatMap(\.stays).map(\.visitID))

        let fix = location(longitude: 0.0012, at: walk.startedAt.addingTimeInterval(80))
        context.insert(RoutePoint(location: fix, mode: .walking, startsNewSegment: false, route: walk))
        walk.pointCount += 1
        try context.save()
        let changed = RouteReviewRevision(calendar: calendar, routes: routes)
        let retained = await reopened.records(for: changed)
        precondition(retained.count == 1 && retained[changed.routes[1]] != nil)
        let updated = RouteReviewCache().summaries(for: routes, revision: changed, indexed: retained)
        let afterAppend = RouteSummary(records: changed.routes.compactMap { updated[$0] })
        precondition(afterAppend.days.map(\.movingDuration) == [50, 30])

        let afterDeletion = RouteReviewRevision(calendar: calendar, routes: [stay])
        try await reopened.prepareToDelete(routeID: walk.id)
        await reopened.save(records, for: revision)
        let surviving = await reopened.records(for: afterDeletion)
        await reopened.save(surviving, for: afterDeletion)
        let pruned = await RouteSummaryIndex(file: file).records(for: revision)
        precondition(pruned.count == 1 && pruned[revision.routes[0]] == nil)

        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let shifted = await reopened.records(for: RouteReviewRevision(calendar: calendar, routes: [stay]))
        precondition(shifted.isEmpty)
        try Data("invalid".utf8).write(to: file)
        let corrupt = await RouteSummaryIndex(file: file).records(for: revision)
        precondition(corrupt.isEmpty)
    }

    @MainActor
    private static func checkBehavior(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        var routes: [RecordedRoute] = []
        for index in 0..<4 {
            let hour = index < 2 ? 8 : 9
            let day = calendar.date(byAdding: .day, value: index, to: firstDay)!
            let start = calendar.date(byAdding: .hour, value: hour, to: day)!
            let transit = index < 2 ? 120 : 240
            let outbound: [Sample] = stride(from: 30, to: transit, by: 30).map { offset in
                (480 + Double(offset), (offset == 30 ? 0.0002 : 0.01 * Double(offset) / Double(transit)), offset == 30 ? .walking : .automotive, offset == 30)
            }
            let arrive = 480 + Double(transit)
            var samples = stop(start: 0, longitude: 0) + outbound + stop(start: arrive, longitude: 0.01)
            if index == 0 {
                samples += [(arrive + 510, 0.005, .automotive, true)]
                    + stop(start: arrive + 540, longitude: 0)
            }
            routes.append(insertRoute(context: context, start: start, samples: samples))
        }
        let lastDay = calendar.date(byAdding: .day, value: 4, to: firstDay)!
        let disconnected = stop(start: 0, longitude: 0) + [
            (510, 0.001, .walking, true), (540, 0.002, .walking, false)
        ]
        let pausedRoute = insertRoute(context: context, start: lastDay, samples: disconnected)
        for point in pausedRoute.points where point.timestamp == lastDay.addingTimeInterval(510) {
            point.startsRecordingRun = true
        }
        routes.append(pausedRoute)
        let walkingDay = calendar.date(byAdding: .day, value: 1, to: lastDay)!
        var walking: [Sample] = []
        for offset in stride(from: 510, to: 1_080, by: 30) {
            let longitude = Double(offset - 480) / 60_000
            walking.append((Double(offset), longitude, .walking, offset == 510))
        }
        routes.append(insertRoute(context: context, start: walkingDay,
                                  samples: stop(start: 0, longitude: 0) + walking + stop(start: 1_080, longitude: 0.01)))
        try context.save()

        let review = RouteReview(routes: routes, calendar: calendar)
        let behavior = RouteBehavior(review: review, range: firstDay...walkingDay, calendar: calendar) { coordinate in
            abs(coordinate.longitude) < 0.0005 ? .home : .work
        }
        precondition(behavior.patterns.count == 1 && behavior.patterns[0].samples.count == 4)
        let commute = behavior.patterns[0]
        precondition(commute.byHour.map(\.hour) == [8, 9])
        precondition(commute.byHour.map(\.median) == [120, 240])
        precondition(commute.mode == .automotive && commute.shorterDepartureWindow?.hour == 8)
        precondition(behavior.routine.filter { $0.kind == .departure }.count == 5)
        precondition(behavior.routine.filter { $0.kind == .arrival }.count == 1)
        precondition(behavior.routine.allSatisfy { $0.day != lastDay })

        let sparse = RouteBehavior(review: review, range: firstDay...firstDay, calendar: calendar) { _ in nil }
        precondition(sparse.patterns.isEmpty && sparse.routine.isEmpty)

        let midnight = firstDay.addingTimeInterval(86_400)
        let otherMidnight = midnight.addingTimeInterval(86_400)
        let acrossMidnight: [Sample] = [
            (0, 0.03, .automotive, true), (40, 0.031, .automotive, false),
            (60, 0.032, .automotive, false), (100, 0.033, .automotive, false)
        ]
        let repeatedOvernight = [midnight, otherMidnight].map {
            insertRoute(context: context, start: $0.addingTimeInterval(-50), samples: acrossMidnight)
        }
        let midnightDeparture = insertRoute(
            context: context, start: midnight.addingTimeInterval(-490),
            samples: stop(start: 0, longitude: 0) + [(500, 0.0004, .walking, true), (520, 0.0006, .walking, false)]
        )
        let midnightArrival = insertRoute(
            context: context, start: midnight.addingTimeInterval(-40),
            samples: [(0, 0.001, .walking, true), (30, 0.0004, .walking, false)] + stop(start: 50, longitude: 0)
        )
        try context.save()
        let overnightReview = RouteReview(routes: repeatedOvernight + [midnightDeparture, midnightArrival], calendar: calendar)
        let departureDays = RouteReview(routes: [midnightDeparture], calendar: calendar).days
        precondition(departureDays.map(\.movingDuration) == [30, 10])
        let keys = departureDays.compactMap { $0.entries.first { $0.kind == .trip }?.memoryKey }
        precondition(keys.count == 2 && keys[0] == keys[1])
        let journalDates = departureDays[0].journalAttachmentDays(in: departureDays)[keys[0]]!
        precondition(journalDates == departureDays.map(\.date).sorted())
        precondition(RouteReviewDay.journalDay(for: midnight, on: journalDates, calendar: calendar) == journalDates.last)
        precondition(RouteReviewDay.journalDay(for: midnight.addingTimeInterval(-1), on: journalDates, calendar: calendar) == journalDates.first)
        precondition(RouteReviewDay.journalDay(for: nil, on: journalDates, calendar: calendar) == journalDates.first)
        let memory = try keys[0].memory(in: context)
        memory.text = "Synthetic overnight trip"
        try context.save()
        let rebuiltKey = RouteReview(routes: [midnightDeparture], calendar: calendar).days[0].entries.first { $0.kind == .trip }!.memoryKey!
        let reopened = try rebuiltKey.memory(in: context)
        precondition(reopened.persistentModelID == memory.persistentModelID)
        let isolatedRoute = insertRoute(context: context, start: midnight, samples: [(0, 0, .walking, true), (20, 0.0002, .walking, false)])
        try context.save()
        let isolatedKey = RouteReview(routes: [isolatedRoute], calendar: calendar).days[0].entries.first { $0.kind == .trip }!.memoryKey!
        let other = try isolatedKey.memory(in: context)
        precondition(other.text.isEmpty)
        let attachment = MemoryPhoto(memory: other, assetID: "synthetic-photo")
        attachment.thumbnail = Data([1, 2, 3])
        context.insert(attachment)
        try context.save()
        precondition(other.isAnnotated)
        attachment.hidden = true
        precondition(!other.isAnnotated)
        attachment.hidden = false
        try context.save()
        context.delete(isolatedRoute)
        try context.save()
        let removedKey = isolatedKey.value
        let count = try context.fetchCount(FetchDescriptor<RouteMemory>(predicate: #Predicate { $0.key == removedKey }))
        precondition(count == 0)
        let survivingPhotos = try context.fetchCount(FetchDescriptor<MemoryPhoto>())
        precondition(survivingPhotos == 0)
        precondition(departureDays[0].moves[0].coordinates.first?.longitude == departureDays[1].moves[0].coordinates.last?.longitude)
        let arrivalDays = RouteReview(routes: [midnightArrival], calendar: calendar).days
        precondition(arrivalDays.map(\.movingDuration) == [10, 40])
        precondition(arrivalDays[0].moves[0].coordinates.first?.longitude == arrivalDays[1].moves[0].coordinates.last?.longitude)
        let overnightEfficiency = RouteBehavior(review: overnightReview, range: firstDay...otherMidnight, calendar: calendar) { _ in nil }
        precondition(overnightEfficiency.patterns.count == 1)
        precondition(overnightEfficiency.patterns[0].samples.map(\.duration) == [100, 100])
        let overnightRoutine = RouteBehavior(review: overnightReview, range: midnight...midnight, calendar: calendar) {
            abs($0.longitude) < 0.0001 ? .home : nil
        }
        precondition(Set(overnightRoutine.routine.map(\.kind)) == [.departure, .arrival])
        precondition(overnightRoutine.routine.allSatisfy { $0.day == midnight && $0.time == midnight.addingTimeInterval(10) })
    }

    @MainActor
    private static func checkInsights(context: ModelContext, directory: URL) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let week = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        let upper = calendar.date(byAdding: .day, value: 6, to: week)!
        let now = week.addingTimeInterval(3 * 86_400)
        let home = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let work = CLLocationCoordinate2D(latitude: 0, longitude: 0.02)
        let newPlace = CLLocationCoordinate2D(latitude: 0, longitude: 0.03)
        let pointRoute = insertRoute(context: context, start: week,
                                     samples: (0..<12).map { (Double($0 * 10), 0, .unknown, $0 == 0) })
        try context.save()
        let ids = pointRoute.points.map(\.persistentModelID)
        func journey(_ index: Int, day: Int, seconds: TimeInterval, hour: Double = 8, mode: TravelMode = .automotive,
                     reverse: Bool = false, hasArrival: Bool = true) -> RouteJourney {
            let departure = week.addingTimeInterval(Double(day * 86_400) + hour * 3_600)
            let origin = reverse ? work : home
            let destination = reverse ? home : work
            let arrival = RouteJourney.StayConnection(coordinate: destination, time: departure.addingTimeInterval(seconds))
            return RouteJourney(id: ids[index], endpoints: .init(start: origin, end: destination), departedAt: departure,
                                duration: seconds, mode: mode,
                                departureStay: .init(coordinate: origin, time: departure), arrivalStay: hasArrival ? arrival : nil)
        }
        let journeys = [
            journey(0, day: -20, seconds: 1_200), journey(1, day: -7, seconds: 1_800), journey(2, day: -6, seconds: 2_400),
            journey(3, day: 0, seconds: 1_620, hour: 23.75), journey(4, day: 1, seconds: 1_380),
            journey(5, day: 2, seconds: 3_600, reverse: true), journey(6, day: 1, seconds: 2_200, mode: .cycling),
            journey(7, day: 4, seconds: 9_000), journey(8, day: 2, seconds: 60, hasArrival: false),
            journey(9, day: 2, seconds: 70_000)
        ]

        let stay = insertRoute(context: context, start: week, samples: stop(start: 0, longitude: 0))
        try context.save()
        let stays = RouteReview(routes: [stay], calendar: calendar)
        let knownHome = stays.places[0].visits[0]
        let priorStay = insertRoute(context: context, start: week.addingTimeInterval(-86_400),
                                    samples: stop(start: 0, longitude: 0) + [
                                        (510, 0.0003, .walking, true), (540, 0.0006, .walking, false)
                                    ])
        try context.save()
        let prior = RouteReview(routes: [priorStay], calendar: calendar)
        let priorHome = prior.places[0].visits[0]
        let firstVisit = RouteVisit(id: ids[10], date: week, startedAt: week, endedAt: week.addingTimeInterval(480), coordinate: newPlace)
        let futureVisit = RouteVisit(id: ids[11], date: upper, startedAt: upper, endedAt: upper.addingTimeInterval(480),
                                     coordinate: .init(latitude: 0, longitude: 0.04))
        let record = RouteSummaryRecord(days: (stays.days + prior.days).map(DailySummary.init(day:)),
                                        visits: [knownHome, priorHome, firstVisit, futureVisit], journeys: journeys)
        let summary = RouteSummary(records: [record])
        func category(_ coordinate: CLLocationCoordinate2D) -> PlaceCategory? {
            if coordinate.longitude == 0 { return .home }
            return coordinate.longitude == 0.02 ? .work : nil
        }
        let range = week...upper
        let patterns = RouteInsights.routePatterns(in: journeys, calendar: calendar)
        let analytics = RouteAnalytics(summary: summary, range: range, calendar: calendar, now: now, category: category)
        let priorShare = RouteInsights.homeShareBefore(week, summary: summary, calendar: calendar, category: category)
        let insights = RouteInsights(summary: summary, analytics: analytics, range: range, calendar: calendar, now: now,
                                     patterns: patterns, hasHome: true, priorHomeShare: priorShare, category: category)
        precondition(insights.newPlaceCount == 1 && insights.home?.share == 1)
        precondition(insights.home?.previousShare == 480.0 / 540.0)
        precondition(insights.home?.trackedDuration == 480 && insights.home?.elapsedDuration == 3 * 86_400)
        precondition(insights.commute?.sampleCount == 2 && insights.commute?.previousSampleCount == 2)
        precondition(insights.commute?.average == 1_500 && insights.commute?.previousAverage == 2_100)
        precondition(insights.commute?.fastestSample.duration == 1_380)
        precondition(insights.routes.count == 1 && insights.routes[0].fastest == 1_200 && insights.routes[0].slowest == 2_400)

        let singleDay = week...week
        let singleDayAnalytics = RouteAnalytics(summary: summary, range: singleDay, calendar: calendar, now: now, category: category)
        let sparse = RouteInsights(summary: summary, analytics: singleDayAnalytics, range: singleDay,
                                   calendar: calendar, now: now, patterns: patterns, hasHome: false, priorHomeShare: nil, category: category)
        precondition(sparse.commute == nil && sparse.routes.isEmpty && sparse.home == nil)

        let names = RoutePlaceNames(file: directory.appending(path: "analysis-place-names.json"))
        try names.save("家", category: .home, for: home)
        try names.save("公司", category: .work, for: work)
        let worker = RouteAnalysisWorker()
        func report(for range: ClosedRange<Date>, at date: Date) async -> RouteAnalysisReport? {
            let places = names.snapshot
            let scope = RouteAnalysisRequest.Scope(summaryID: summary.id, placesRevision: places.revision, calendar: calendar, range: range)
            return await worker.report(for: .init(scope: scope, now: date), summary: summary, places: places)
        }
        let firstReport = await report(for: range, at: now)
        precondition(firstReport?.analytics.trackedDuration == analytics.trackedDuration)
        precondition(firstReport?.insights?.home?.previousShare == insights.home?.previousShare)
        precondition(firstReport?.insights?.commute?.average == insights.commute?.average)
        precondition(firstReport?.placesByVisits.map(\.id) == analytics.topPlaces(by: .visits).map(\.id))
        let later = await report(for: range, at: now.addingTimeInterval(60))
        precondition(later?.analytics.elapsedDuration == analytics.elapsedDuration + 60)
        let filtered = await report(for: singleDay, at: now)
        precondition(filtered?.scope.range == singleDay && filtered?.insights?.routes.isEmpty == true)
        try names.save("休闲", category: .leisure, for: home)
        let reclassified = await report(for: range, at: now)
        precondition(reclassified?.scope.placesRevision != firstReport?.scope.placesRevision)
        precondition(reclassified?.insights?.home == nil && reclassified?.insights?.commute == nil)

        let cancelled = Task { await report(for: range, at: now) }
        cancelled.cancel()
        let cancelledReport = await cancelled.value
        precondition(cancelledReport == nil)

        let empty = RouteSummary(records: [])
        let places = names.snapshot
        let emptyScope = RouteAnalysisRequest.Scope(summaryID: empty.id, placesRevision: places.revision, calendar: calendar, range: range)
        let cleared = await worker.report(for: .init(scope: emptyScope, now: now), summary: empty, places: places)
        precondition(cleared?.analytics.trackedDuration == 0 && cleared?.behavior == nil)
    }

    @MainActor
    private static func checkPlaceSuggestions(context: ModelContext) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let weekday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        let route = insertRoute(context: context, start: weekday,
                                samples: (0..<8).map { (Double($0 * 10), 0, .unknown, $0 == 0) })
        try context.save()
        let ids = route.points.map(\.persistentModelID)
        var visits: [RouteVisit] = []
        for index in 0..<4 {
            let day = calendar.date(byAdding: .day, value: index, to: weekday)!
            let midnight = day.addingTimeInterval(-3_600)
            visits.append(RouteVisit(id: ids[index], date: calendar.startOfDay(for: midnight),
                                     startedAt: midnight, endedAt: day.addingTimeInterval(7 * 3_600),
                                     coordinate: .init(latitude: 0, longitude: 0)))
            let work = day.addingTimeInterval(11 * 3_600)
            visits.append(RouteVisit(id: ids[index + 4], date: day, startedAt: work,
                                     endedAt: work.addingTimeInterval(3_600), coordinate: .init(latitude: 0, longitude: 0.02)))
        }
        let places = RoutePlace.group(visits, within: RouteReview.placeRadius)
        let now = calendar.date(byAdding: .day, value: 5, to: weekday)!
        let suggestions = PlaceSuggestions.candidates(in: places, calendar: calendar, now: now) { _ in nil }
        precondition(suggestions.map(\.category) == [.home, .work] && suggestions.allSatisfy { $0.observedDays == 4 })
        let confirmed = PlaceSuggestions.candidates(in: places, calendar: calendar, now: now) {
            $0.longitude == 0 ? .home : nil
        }
        precondition(confirmed.map(\.category) == [.work])
        let sparse = PlaceSuggestions.candidates(in: places, calendar: calendar, now: weekday.addingTimeInterval(3_600)) { _ in nil }
        precondition(sparse.isEmpty)

        let weekend = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 11))!
        let weekends = [0, 7, 14].enumerated().map { index, offset in
            let time = calendar.date(byAdding: .day, value: offset, to: weekend)!
            return RouteVisit(id: ids[index], date: calendar.startOfDay(for: time),
                              startedAt: time, endedAt: time.addingTimeInterval(3_600),
                              coordinate: .init(latitude: 0, longitude: 0.04))
        }
        let weekendPlaces = RoutePlace.group(weekends, within: RouteReview.placeRadius)
        let weekendOnly = PlaceSuggestions.candidates(in: weekendPlaces, calendar: calendar, now: now) { _ in nil }
        precondition(weekendOnly.isEmpty)
    }

    @MainActor
    private static func checkPlaceNames(in directory: URL) throws {
        let file = directory.appending(path: "place-names.json")
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let nearby = CLLocationCoordinate2D(latitude: 0, longitude: 0.0002)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 0.0100)
        let legacy = Data(#"[{"name":"旧版地点","latitude":0,"longitude":0}]"#.utf8)
        try legacy.write(to: file)
        let names = RoutePlaceNames(file: file)
        precondition(names.name(for: start) == "旧版地点" && names.category(for: start) == nil)
        try names.save(" 河滨公园 ", category: .leisure, for: start)
        try names.save("市图书馆", for: end)
        precondition(names.name(for: nearby) == "河滨公园")

        let reopened = RoutePlaceNames(file: file)
        precondition(reopened.name(for: end) == "市图书馆")
        precondition(reopened.category(for: nearby) == .leisure)
        try reopened.save("公园入口", for: nearby)
        precondition(reopened.name(for: start) == "公园入口")
        try reopened.save(nil, for: start)
        let afterRemoval = RoutePlaceNames(file: file)
        precondition(afterRemoval.name(for: nearby) == nil)
        precondition(afterRemoval.name(for: end) == "市图书馆")

        let invalidFile = directory.appending(path: "invalid-place-names.json")
        let invalid = Data("incomplete".utf8)
        try invalid.write(to: invalidFile)
        let invalidStore = RoutePlaceNames(file: invalidFile)
        precondition(invalidStore.loadIssue == .damaged)
        do {
            try invalidStore.save("测试名称", for: start)
            preconditionFailure("Saving must not replace a place-name file that could not be loaded.")
        } catch {
            let persisted = try Data(contentsOf: invalidFile)
            precondition(persisted == invalid)
        }
        try invalidStore.rebuildDamagedFile()
        precondition(invalidStore.loadIssue == nil)
        try invalidStore.save("重新保存的地名", category: .work, for: start)
        let rebuilt = RoutePlaceNames(file: invalidFile)
        precondition(rebuilt.name(for: start) == "重新保存的地名" && rebuilt.category(for: start) == .work)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("invalid-place-names-damaged-") }
        precondition(backups.count == 1)
        let preserved = try Data(contentsOf: backups[0])
        precondition(preserved == invalid)

        let unreadableFile = directory.appending(path: "unreadable.json")
        try FileManager.default.createDirectory(at: unreadableFile, withIntermediateDirectories: false)
        let unreadable = RoutePlaceNames(file: unreadableFile)
        precondition(unreadable.loadIssue == .unreadable)
        try unreadable.rebuildDamagedFile()
        precondition(unreadable.loadIssue == .unreadable)
        try FileManager.default.removeItem(at: unreadableFile)
        try legacy.write(to: unreadableFile)
        unreadable.reload()
        precondition(unreadable.loadIssue == nil && unreadable.name(for: start) == "旧版地点")
    }

    private static func checkRankedPlaceNames() throws {
        typealias Point = MapPlaceSuggestion.NearbyPoint
        let cafe = Point(name: "合成咖啡店", distance: 21, isLandmark: false)
        let competitor = Point(name: "合成便利店", distance: 29, isLandmark: false)
        let fartherStore = Point(name: "远处的商店", distance: 80, isLandmark: false)
        let mall = Point(name: "城市购物中心", distance: 155, isLandmark: true)
        let outside = Point(name: "范围外的公园", distance: 205, isLandmark: true)
        let address = MapPlaceSuggestion.Address(street: "合成路", district: "测试街区", city: "测试城市", detailed: "合成路 18 号")

        let clear = MapPlaceSuggestion.ranked(points: [fartherStore, cafe, mall], address: address)
        precondition(clear.displayName == "合成咖啡店附近")
        precondition(clear.candidates.contains("合成路 18 号") && clear.candidates.contains("城市购物中心附近"))
        precondition(!clear.candidates.contains("远处的商店"))

        let ambiguous = MapPlaceSuggestion.ranked(points: [competitor, cafe, mall], address: address)
        precondition(ambiguous.displayName == "合成路附近")
        precondition(ambiguous.candidates.contains("合成咖啡店") && ambiguous.candidates.contains("合成便利店"))
        let manualOnly = MapPlaceSuggestion.ranked(points: [competitor, cafe], address: .init())
        precondition(manualOnly.displayName == nil && manualOnly.candidates.count == 2)

        let landmark = MapPlaceSuggestion.ranked(points: [outside, fartherStore, mall], address: .init(city: "测试城市"))
        precondition(landmark.displayName == "城市购物中心附近" && !landmark.candidates.contains("范围外的公园附近"))
        let district = MapPlaceSuggestion.ranked(points: [mall], address: .init(street: " ", district: "测试街区"))
        precondition(district.displayName == "测试街区附近")
        let empty = MapPlaceSuggestion.ranked(points: [outside, fartherStore], address: .init())
        precondition(empty.displayName == nil && empty.candidates.isEmpty)

        let cached = try JSONDecoder().decode(MapPlaceSuggestion.self, from: JSONEncoder().encode(ambiguous))
        precondition(cached.displayName == ambiguous.displayName && cached.candidates == ambiguous.candidates)
        let old = Data(#"{"pointOfInterestNames":["旧版地点"],"streetOrArea":"旧版街道"}"#.utf8)
        let legacy = try JSONDecoder().decode(MapPlaceSuggestion.self, from: old)
        precondition(legacy.displayName == "旧版地点附近" && legacy.candidates.contains("旧版街道附近"))
    }

    @MainActor
    private static func checkPlaceResolver(in directory: URL) async throws {
        let suite = "LifeMemTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = directory.appending(path: "place-suggestions.json")
        let names = RoutePlaceNames(file: directory.appending(path: "test-aliases.json"))
        let place = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let neighbor = CLLocationCoordinate2D(latitude: 0, longitude: 0.00012)
        let anotherPlace = CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
        var requests = 0
        let resolver = PlaceResolver(file: file, defaults: defaults) { _, _ in
            requests += 1
            return .init(MapPlaceSuggestion(pointOfInterestNames: ["市图书馆"], streetOrArea: "书院路", district: nil, city: nil))
        }
        await resolver.resolveAutomatically(near: place, names: names)
        precondition(requests == 0)
        resolver.setAutomaticEnabled(true)
        await resolver.resolveAutomatically(near: place, names: names)
        await resolver.resolveAutomatically(near: neighbor, names: names)
        precondition(requests == 1)
        precondition(resolver.label(near: neighbor, names: names) == "市图书馆附近")
        try names.save("最喜欢的图书馆", category: .leisure, for: place)
        try names.save("家", category: .home, for: anotherPlace)
        await resolver.resolveAutomatically(near: anotherPlace, names: names)
        precondition(requests == 1)
        precondition(resolver.label(near: neighbor, names: names) == "最喜欢的图书馆")
        resolver.setAutomaticEnabled(false)
        let reopened = PlaceResolver(file: file, defaults: defaults) { _, _ in .init(nil) }
        precondition(!reopened.isAutomaticEnabled)
        precondition(reopened.cached(near: neighbor)?.candidates == ["市图书馆", "书院路附近"])
        try reopened.clearCache()
        let cleared = PlaceResolver(file: file, defaults: defaults) { _, _ in .init(nil) }
        precondition(cleared.cached(near: neighbor) == nil)
        precondition(cleared.label(near: neighbor, names: names) == "最喜欢的图书馆")

        let clock = ContinuousClock()
        var starts: [ContinuousClock.Instant] = []
        let coordinated = PlaceResolver(file: file, defaults: defaults, minimumInterval: .milliseconds(40)) { _, _ in
            starts.append(clock.now)
            try await Task.sleep(for: .milliseconds(20))
            return .init(MapPlaceSuggestion(pointOfInterestNames: ["合成地名"], streetOrArea: nil, district: nil, city: nil))
        }
        coordinated.setAutomaticEnabled(true)
        async let automatic = coordinated.resolve(near: place, automatic: true)
        async let manual = coordinated.resolve(near: neighbor, automatic: false)
        async let distinct = coordinated.resolve(near: anotherPlace, automatic: false)
        for result in await [automatic, manual, distinct] {
            precondition(result?.displayName == "合成地名附近")
        }
        precondition(starts.count == 2 && starts[0].duration(to: starts[1]) >= .milliseconds(40))

        enum LookupFailure: Error { case unavailable }
        var attempts = 0
        let failed = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero, initialBackoff: .milliseconds(200)) { _, _ in
            attempts += 1
            if attempts == 1 { throw LookupFailure.unavailable }
            return .init(nil)
        }
        let uncached = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let anotherUncached = CLLocationCoordinate2D(latitude: 0, longitude: 2)
        _ = await failed.resolve(near: uncached, automatic: false)
        _ = await failed.resolve(near: anotherUncached, automatic: false)
        precondition(attempts == 1)
        let cachedOffline = await failed.resolve(near: place, automatic: false)
        precondition(cachedOffline?.displayName == "合成地名附近")
        try await Task.sleep(for: .milliseconds(220))
        _ = await failed.resolve(near: uncached, automatic: false)
        _ = await failed.resolve(near: anotherUncached, automatic: false)
        precondition(attempts == 3, "A completed lookup with no match must not trigger network backoff.")

        var partialAttempts = 0
        let partial = PlaceResolver(file: directory.appending(path: "partial-suggestions.json"), defaults: defaults) { _, _ in
            partialAttempts += 1
            let suggestion = MapPlaceSuggestion(pointOfInterestNames: ["附近地名"], streetOrArea: nil, district: nil, city: nil)
            return .init(suggestion, shouldBackOff: true)
        }
        let partialResult = await partial.resolve(near: uncached, automatic: false)
        _ = await partial.resolve(near: anotherUncached, automatic: false)
        precondition(partialResult != nil && partialAttempts == 1)
        precondition(partial.cached(near: uncached) != nil)

        var finish: CheckedContinuation<Void, Never>?
        var furtherRequests = 0
        let clearing = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero) { _, checkDemand in
            await withCheckedContinuation { finish = $0 }
            try checkDemand()
            furtherRequests += 1
            return .init(MapPlaceSuggestion(pointOfInterestNames: ["过期结果"], streetOrArea: nil, district: nil, city: nil))
        }
        let pending = Task { await clearing.resolve(near: uncached, automatic: false) }
        while finish == nil { await Task.yield() }
        try clearing.clearCache()
        finish?.resume()
        let clearedPending = await pending.value
        precondition(clearedPending == nil && clearing.cached(near: uncached) == nil)

        finish = nil
        let automaticPending = Task { await clearing.resolve(near: anotherUncached, automatic: true) }
        while finish == nil { await Task.yield() }
        clearing.setAutomaticEnabled(false)
        clearing.setAutomaticEnabled(true)
        finish?.resume()
        let revokedPending = await automaticPending.value
        precondition(revokedPending == nil && clearing.cached(near: anotherUncached) == nil)

        finish = nil
        let cancelled = Task { await clearing.resolve(near: uncached, automatic: false) }
        while finish == nil { await Task.yield() }
        finish?.resume()
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil && clearing.cached(near: uncached) == nil)
        precondition(furtherRequests == 0, "Revoked demand must not start a fallback network request.")
    }

    @MainActor
    private static func checkMainlandPlaceLookup(in directory: URL) async throws {
        let suite = "LifeMemTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = directory.appending(path: "mainland-place-suggestions.json")
        let names = RoutePlaceNames(file: directory.appending(path: "mainland-place-names.json"))
        let mainland = CLLocationCoordinate2D(latitude: 39.9, longitude: 116.3)
        let nearbyMainland = CLLocationCoordinate2D(latitude: 39.9001, longitude: 116.3001)
        let named = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let abroad = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        let otherAbroad = CLLocationCoordinate2D(latitude: 35.6600, longitude: 139.6503)
        let previousProjection = RouteMapProjection(coverageURL: nil)
        let legacy = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero, projection: previousProjection) { coordinate, _ in
            .init(.ranked(points: [], address: .init(street: coordinate.latitude == abroad.latitude ? "海外街道" : "偏移地址")))
        }
        for coordinate in [mainland, named, abroad] {
            _ = await legacy.resolve(near: coordinate, automatic: false)
        }
        precondition(legacy.label(near: mainland, names: names) == "偏移地址附近")
        try names.save("手动保存的地名", category: .home, for: named)

        let projection = RouteMapProjection(coverageURL: URL(fileURLWithPath: "LifeMem/AMapMainlandCoverage.json"))
        var queries: [CLLocationCoordinate2D] = []
        let resolver = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero, projection: projection) { coordinate, _ in
            queries.append(coordinate)
            return .init(.ranked(points: [], address: .init(street: "合成街道")))
        }
        precondition(resolver.cached(near: mainland) == nil && resolver.cached(near: named) == nil)
        precondition(resolver.label(near: named, names: names) == "手动保存的地名" && names.category(for: named) == .home)
        precondition(resolver.label(near: abroad, names: names) == "海外街道附近")
        await resolver.resolveAutomatically(near: mainland, names: names)
        precondition(queries.isEmpty)

        resolver.setAutomaticEnabled(true)
        await resolver.resolveAutomatically(near: mainland, names: names)
        await resolver.resolveAutomatically(near: named, names: names)
        let manual = await resolver.resolve(near: nearbyMainland, automatic: false)
        precondition(queries.count == 1 && manual?.displayName == "合成街道附近")
        precondition(abs(queries[0].latitude - 39.90126009494757) < 1e-9)
        precondition(abs(queries[0].longitude - 116.30607290385822) < 1e-9)
        precondition(resolver.cached(near: queries[0]) == nil, "Cache must use the raw route coordinate.")

        resolver.setAutomaticEnabled(false)
        let explicitLookup = await resolver.resolve(near: named, automatic: false)
        precondition(explicitLookup?.displayName == "合成街道附近" && queries.count == 2)
        precondition(abs(queries[1].latitude - 31.22845773757727) < 1e-9)
        precondition(abs(queries[1].longitude - 121.47822305927693) < 1e-9)
        _ = await resolver.resolve(near: otherAbroad, automatic: false)
        precondition(queries.count == 3 && queries[2].latitude == otherAbroad.latitude && queries[2].longitude == otherAbroad.longitude)
        let reopened = PlaceResolver(file: file, defaults: defaults, projection: projection) { _, _ in
            preconditionFailure("A refreshed cache should resolve without a lookup.")
        }
        let saved = await reopened.resolve(near: mainland, automatic: false)
        precondition(saved?.displayName == "合成街道附近")
        precondition(reopened.label(near: abroad, names: names) == "海外街道附近")
        precondition(reopened.label(near: named, names: names) == "手动保存的地名")
    }

    @MainActor
    private static func checkSharedPlaceCancellation(in directory: URL) async {
        let suite = "LifeMemTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let nearby = CLLocationCoordinate2D(latitude: 0, longitude: 0.00012)
        let suggestion = MapPlaceSuggestion(pointOfInterestNames: ["合成地名"], streetOrArea: nil, district: nil, city: nil)

        for needsFallback in [false, true] {
            let file = directory.appending(path: "shared-\(needsFallback).json")
            var starts: [Double] = []
            var fallbackStarts: [Double] = []
            var finishFirst: CheckedContinuation<Void, Never>?
            let resolver = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero) { coordinate, checkDemand in
                starts.append(coordinate.longitude)
                if starts.count == 1 { await withCheckedContinuation { finishFirst = $0 } }
                if needsFallback {
                    try checkDemand()
                    fallbackStarts.append(coordinate.longitude)
                }
                return .init(suggestion)
            }
            resolver.setAutomaticEnabled(true)
            let automatic = Task { await resolver.resolve(near: origin, automatic: true) }
            while finishFirst == nil { await Task.yield() }
            var joined = false
            let manual = Task {
                joined = true
                return await resolver.resolve(near: nearby, automatic: false)
            }
            while !joined { await Task.yield() }
            if needsFallback { resolver.setAutomaticEnabled(false) } else { automatic.cancel() }
            finishFirst?.resume()
            let originalResult = await automatic.value
            let manualResult = await manual.value
            precondition(originalResult == nil && manualResult?.displayName == suggestion.displayName)
            precondition(starts == (needsFallback ? [origin.longitude, nearby.longitude] : [origin.longitude]))
            precondition(fallbackStarts == (needsFallback ? [nearby.longitude] : []))
        }
    }

    @MainActor
    private static func checkPlacePrefetch(in directory: URL) async throws {
        let suite = "LifeMemTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = directory.appending(path: "prefetched-places.json")
        let names = RoutePlaceNames(file: directory.appending(path: "prefetch-place-names.json"))
        let now = Date.now
        let visits = (0..<6).map { index in
            RouteVisit(id: RecordedRoute(startedAt: now).persistentModelID, date: now, startedAt: now.addingTimeInterval(-500),
                       endedAt: now, coordinate: .init(latitude: 0, longitude: Double(index) * 0.01))
        }
        try names.save("用户输入", for: visits[0].coordinate)
        var starts = 0
        var gate: CheckedContinuation<Void, Never>?
        var pauses = false
        let resolver = PlaceResolver(file: file, defaults: defaults, minimumInterval: .zero) { _, _ in
            starts += 1
            if pauses { await withCheckedContinuation { gate = $0 } }
            return .init(MapPlaceSuggestion(pointOfInterestNames: ["合成地名"], streetOrArea: nil, district: nil, city: nil))
        }
        resolver.setAutomaticEnabled(true)
        let legacy = PlaceResolver(file: file, defaults: defaults)
        precondition(legacy.isAutomaticEnabled && !legacy.isPrefetchEnabled)
        await resolver.prefetch(visits, names: names)
        precondition(starts == 0 && !resolver.hasSeenAutomaticIntroduction)

        resolver.dismissAutomaticIntroduction()
        resolver.setAutomaticEnabled(true, includesPrefetch: true)
        await resolver.prefetch(visits, names: names)
        precondition(starts == 4 && resolver.cached(near: visits[0].coordinate) == nil)
        await resolver.prefetch(visits, names: names)
        precondition(starts == 5 && resolver.cached(near: visits[5].coordinate) != nil)
        let reopened = PlaceResolver(file: file, defaults: defaults)
        precondition(reopened.isPrefetchEnabled && reopened.hasSeenAutomaticIntroduction)

        try resolver.clearCache()
        pauses = true
        let pending = Task { await resolver.prefetch(visits, names: names) }
        while gate == nil { await Task.yield() }
        try resolver.clearCache()
        gate?.resume()
        await pending.value
        precondition(starts == 6 && resolver.cached(near: visits[1].coordinate) == nil)
        resolver.setAutomaticEnabled(false)
        await resolver.prefetch(visits, names: names)
        precondition(starts == 6)
    }

    private typealias Sample = (seconds: TimeInterval, longitude: Double, mode: TravelMode, newSegment: Bool)

    private static func stop(start: TimeInterval, longitude: Double) -> [Sample] {
        stride(from: 0, through: 480, by: 30).map {
            (start + TimeInterval($0), longitude, .stationary, $0 == 0)
        }
    }

    @MainActor
    private static func insertRoute(context: ModelContext, start: Date, samples: [Sample]) -> RecordedRoute {
        let route = RecordedRoute(startedAt: start)
        context.insert(route)
        for sample in samples {
            context.insert(RoutePoint(
                location: location(longitude: sample.longitude, at: start.addingTimeInterval(sample.seconds)),
                mode: sample.mode,
                startsNewSegment: sample.newSegment,
                route: route
            ))
        }
        route.pointCount = samples.count
        return route
    }

    @MainActor
    private static func writeRoute(points: [CLLocation], schema: Schema, configuration: ModelConfiguration) throws {
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let route = RecordedRoute(startedAt: points[0].timestamp)
        context.insert(route)
        try context.save()
        var lastPoint: CLLocation?
        for (index, location) in points.enumerated() {
            let mode: TravelMode = index < 2 ? .walking : .automotive
            let step = LocationSampling(mode: mode).assess(location, after: lastPoint, mode: mode)!
            context.insert(RoutePoint(location: location, mode: mode, startsNewSegment: step.startsNewSegment, route: route))
            route.pointCount += 1
            route.distanceMeters += step.distance
            try context.save()
            lastPoint = location
        }
    }

    private static func checkSpeedEstimate(start: Date) {
        let stationary = LocationSampling(mode: .stationary)
        precondition(stationary.desiredAccuracy < stationary.maximumAccuracy)
        precondition(stationary.assess(location(longitude: 0, at: start, accuracy: 65), after: nil, mode: .stationary) == nil)

        func sample(_ seconds: TimeInterval, _ speed: Double, uncertainty: Double = 0.5) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 0, longitude: 0), altitude: 0, horizontalAccuracy: 5,
                       verticalAccuracy: 5, course: -1, courseAccuracy: -1, speed: speed,
                       speedAccuracy: uncertainty, timestamp: start.addingTimeInterval(seconds))
        }

        var estimate = SpeedModeEstimate()
        precondition(estimate.observe(sample(0, 2.8), currentMode: .unknown) == nil)
        precondition(estimate.observe(sample(1, 2.8), currentMode: .unknown) == .walking)
        precondition(estimate.observe(sample(2, 4), currentMode: .walking) == nil)
        precondition(estimate.observe(sample(10, 4, uncertainty: 2), currentMode: .walking) == nil)
        precondition(estimate.observe(sample(11, 4), currentMode: .walking) == nil)
        precondition(estimate.observe(sample(18, 4), currentMode: .walking) == nil)
        precondition(estimate.observe(sample(19, 4), currentMode: .walking) == .cycling)
        precondition(estimate.observe(sample(20, 7.5), currentMode: .cycling) == nil)
        precondition(estimate.observe(sample(21, 7.5), currentMode: .cycling) == .automotive)
        precondition(estimate.observe(sample(22, 4), currentMode: .automotive) == nil)
        precondition(estimate.observe(sample(31, 4), currentMode: .automotive) == nil)
        precondition(estimate.observe(sample(32, 0.3), currentMode: .automotive) == nil)
        precondition(estimate.observe(sample(38, 0.2), currentMode: .automotive) == nil)
        precondition(estimate.observe(sample(40, 8), currentMode: .automotive) == nil)
        precondition(estimate.observe(sample(41, 0.1), currentMode: .automotive) == nil)
        precondition(estimate.observe(sample(53, 0.1), currentMode: .automotive) == .stationary)
        precondition(estimate.observe(sample(150, 0.1), currentMode: .stationary) == nil)
        precondition(estimate.observe(sample(151, 1.2), currentMode: .stationary) == nil)
        precondition(estimate.observe(sample(152, 1.2), currentMode: .stationary) == .walking)
    }

    private static func checkWeeklyVisits() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        pacific.firstWeekday = 1
        let sunday = pacific.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let spring = (0...4).map { week -> RouteSummaryRecord in
            let day = pacific.date(byAdding: .weekOfYear, value: -week, to: sunday)!
            let start = pacific.date(bySettingHour: week == 0 ? 3 : 2, minute: 0, second: 0, of: day)!
            let end = start.addingTimeInterval(1800)
            let id = RecordedRoute(startedAt: start).persistentModelID
            let stay = StayEvent(id: id, visitID: id, coordinate: .init(latitude: 0, longitude: 0), startedAt: start, endedAt: end)
            let visit = RouteVisit(id: id, date: day, startedAt: start, endedAt: end, coordinate: stay.coordinate)
            return RouteSummaryRecord(days: [DailySummary(date: day, inferredStay: stay)], visits: [visit], journeys: [])
        }
        let afterJump = WeeklyVisits(summary: RouteSummary(records: spring, calendar: pacific),
                                     calendar: pacific, now: sunday.addingTimeInterval(5 * 3600))
        precondition(afterJump.places.first?.current.visits.count == 1 && afterJump.places.first?.usualDays == nil)

        let nextSunday = pacific.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        let earlyRecords = (0...4).map { week -> RouteSummaryRecord in
            let day = pacific.date(byAdding: .weekOfYear, value: -week, to: nextSunday)!
            let end = day.addingTimeInterval(1800)
            let id = RecordedRoute(startedAt: day).persistentModelID
            let stay = StayEvent(id: id, visitID: id, coordinate: .init(latitude: 0, longitude: 0), startedAt: day, endedAt: end)
            let visit = RouteVisit(id: id, date: day, startedAt: day, endedAt: end, coordinate: stay.coordinate)
            return RouteSummaryRecord(days: [DailySummary(date: day, inferredStay: stay)], visits: [visit], journeys: [])
        }
        let missingCutoff = WeeklyVisits(summary: RouteSummary(records: earlyRecords, calendar: pacific),
                                        calendar: pacific, now: nextSunday.addingTimeInterval(2.5 * 3600))
        precondition(missingCutoff.places.first?.current.visits.count == 1 && missingCutoff.places.first?.usualDays == nil)
        let ordinarySunday = pacific.date(from: DateComponents(year: 2026, month: 11, day: 8))!
        let autumn = (0...4).map { week -> RouteSummaryRecord in
            let day = pacific.date(byAdding: .weekOfYear, value: -week, to: ordinarySunday)!
            let repeatedHour = week == 1
            let starts = repeatedHour ? [4200.0, 7800.0] : [3900.0]
            var days: [DailySummary] = []
            var visits: [RouteVisit] = []
            for offset in starts {
                let time = day.addingTimeInterval(offset)
                let id = RecordedRoute(startedAt: time).persistentModelID
                let stay = StayEvent(id: id, visitID: id, coordinate: .init(latitude: 0, longitude: 0), startedAt: time,
                                     endedAt: time.addingTimeInterval(repeatedHour ? 600 : 1200))
                days.append(DailySummary(date: day, inferredStay: stay))
                visits.append(RouteVisit(id: id, date: day, startedAt: time, endedAt: stay.endedAt, coordinate: stay.coordinate))
            }
            return RouteSummaryRecord(days: days, visits: visits, journeys: [])
        }
        let afterFall = WeeklyVisits(summary: RouteSummary(records: autumn, calendar: pacific),
                                     calendar: pacific, now: ordinarySunday.addingTimeInterval(5 * 3600))
        precondition(afterFall.places.first?.usualDays == nil)
        for (zone, firstWeekday, month, date) in [("UTC", 2, 11, 23), ("America/Santiago", 1, 9, 6)] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            calendar.firstWeekday = firstWeekday
            let monday = calendar.date(from: DateComponents(year: 2026, month: month, day: date))!
            checkWeeklyPeriod(calendar: calendar, monday: monday)
        }
    }

    private static func checkWeeklyPeriod(calendar: Calendar, monday: Date) {
        let now = monday.addingTimeInterval(36 * 3600)
        var records: [RouteSummaryRecord] = []
        for week in 0...4 {
            let start = calendar.startOfDay(for: calendar.date(byAdding: .weekOfYear, value: -week, to: monday)!)
            var days: [DailySummary] = []
            var visits: [RouteVisit] = []
            for n in 0...1 {
                let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: n, to: start)!)
                let time = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
                let id = RecordedRoute(startedAt: time).persistentModelID
                let stay = StayEvent(id: id, visitID: id, coordinate: .init(latitude: 0, longitude: 0),
                                     startedAt: time, endedAt: time.addingTimeInterval(3600))
                days.append(DailySummary(date: day, inferredStay: stay))
                if n == 0 || week == 0 {
                    for j in 0..<2 {
                        let arrival = time.addingTimeInterval(Double(j * 60))
                        visits.append(RouteVisit(id: RecordedRoute(startedAt: arrival).persistentModelID, date: day,
                                                 startedAt: arrival, endedAt: stay.endedAt, coordinate: stay.coordinate))
                    }
                }
            }
            // A Tuesday evening visit falls beyond Tuesday noon's comparison window.
            let late = start.addingTimeInterval(44 * 3600)
            visits.append(RouteVisit(id: RecordedRoute(startedAt: late).persistentModelID,
                                     date: calendar.startOfDay(for: late), startedAt: late, endedAt: late.addingTimeInterval(600),
                                     coordinate: .init(latitude: 0, longitude: 0)))
            records.append(RouteSummaryRecord(days: days, visits: visits, journeys: []))
        }
        func report(_ data: [RouteSummaryRecord]) -> WeeklyVisits.Place? {
            WeeklyVisits(summary: RouteSummary(records: data, calendar: calendar), calendar: calendar, now: now).places.first
        }
        precondition(report(records)?.usualDays == 1 && report(records)?.current.visits.count == 2)
        precondition(report([records[0]])?.usualDays == nil)
        precondition(report(Array(records.dropLast()))?.history.isEmpty == true)
        let prior = records[1]
        let evenings = prior.days.map { day in
            let visit = day.stays[0]
            let start = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: day.date)!
            let stay = StayEvent(id: visit.id, visitID: visit.visitID, coordinate: visit.coordinate,
                                 startedAt: start, endedAt: start.addingTimeInterval(3600))
            return DailySummary(date: day.date, inferredStay: stay)
        }
        records[1] = RouteSummaryRecord(days: evenings, visits: prior.visits, journeys: [])
        precondition(report(records)?.usualDays == nil)
    }

    @MainActor
    private static func checkVisitCandidates() throws {
        let container = try ModelContainer(for: RecordedRoute.self, RoutePoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date.now)
        func route(_ start: Date, _ from: Double, _ to: Double) -> RecordedRoute {
            let route = RecordedRoute(startedAt: start)
            route.isAutomatic = true
            route.automaticSessionStart = midnight.addingTimeInterval(-3600)
            context.insert(route)
            for (index, x) in [from, to].enumerated() {
                let fix = location(longitude: x, at: start.addingTimeInterval(Double(index * 60)))
                context.insert(RoutePoint(location: fix, mode: .walking, startsNewSegment: index == 0, route: route))
                route.pointCount += 1
            }
            return route
        }
        let a = route(midnight.addingTimeInterval(-1800), 0, 0.0008)
        let b = route(midnight.addingTimeInterval(1800), 0.0008, 0)
        a.endedAtRest = true
        b.previousAutomaticRouteID = a.id
        try context.save()
        func candidates() -> [StayEvent] {
            RouteReview(routes: [b, a], calendar: calendar).days.flatMap(\.entries)
                .compactMap(\.stay).filter { $0.isCandidate == true }
        }
        let projected = candidates()
        precondition(projected.count == 2 && Set(projected.map(\.visitID)).count == 1)
        precondition(RouteReview(routes: [b, a], calendar: calendar).places.isEmpty)
        try VisitCorrection.save(projected[0], name: "测试书店", in: context)
        let confirmed = RouteReview(routes: [b, a], calendar: calendar)
        precondition(confirmed.places.count == 1 && confirmed.places[0].visitName == "测试书店")
        precondition(confirmed.days.flatMap(\.stays).count == 2)
        let revision = RouteReviewRevision(calendar: calendar, routes: [a, b])
        let records = RouteReviewCache().summaries(for: [a, b], revision: revision, indexed: [:])
        let indexed = RouteSummary(records: Array(records.values), calendar: calendar)
        precondition(indexed.places.count == 1 && indexed.days.flatMap(\.stays).count == 2)
        for journeys in [confirmed.journeys, indexed.journeys] {
            precondition(journeys.contains { $0.endpoints.endName == "测试书店" })
            precondition(journeys.contains { $0.endpoints.startName == "测试书店" })
        }
        try VisitCorrection.save(projected[0], name: nil, ignore: true, in: context)
        precondition(candidates().isEmpty && RouteReview(routes: [b, a], calendar: calendar).places.isEmpty)
        b.arrivalDecision = nil
        b.automaticSessionStart = midnight
        precondition(candidates().isEmpty)
        b.automaticSessionStart = a.automaticSessionStart
        b.previousAutomaticRouteID = nil
        precondition(candidates().isEmpty)
        if let movement = confirmed.days.flatMap(\.entries).first(where: { $0.kind == .trip }),
           let stay = confirmed.days.flatMap(\.entries).first(where: { $0.stay != nil }) {
            var separate = movement
            separate.endpoints?.startName = "学校"
            separate.endpoints?.endName = "车站"
            let sequence = RouteReviewDay(date: midnight, entries: [stay, separate]).placeSequence { _ in nil }
            precondition(sequence == "测试书店 → 学校 → 车站")
        } else { preconditionFailure("Missing synthetic movement or stop") }
        // A previously confirmed gap touches a newly recognized observed stay in the arriving route.
        let arriving = route(midnight.addingTimeInterval(4_000), 0, 0.002)
        for offset in stride(from: 90, through: 810, by: 30) {
            let longitude = (390...420).contains(offset) ? 0.003 : 0.002
            let fix = location(longitude: longitude, at: arriving.startedAt.addingTimeInterval(Double(offset)))
            context.insert(RoutePoint(location: fix, mode: .stationary, startsNewSegment: offset == 90, route: arriving))
            arriving.pointCount += 1
        }
        let leaving = route(arriving.startedAt.addingTimeInterval(2_010), 0.002, 0.003)
        leaving.previousAutomaticRouteID = arriving.id
        arriving.endedAtRest = true
        leaving.arrivalDecision = "confirmed"
        leaving.arrivalName = "已确认的店"
        try context.save()
        let joined = RouteReview(routes: [leaving, arriving], calendar: calendar)
        let joinedIndex = RouteSummary(records: [leaving, arriving].map { RouteReview.summaryRecord(for: $0, calendar: calendar) },
                                       calendar: calendar)
        for places in [joined.places, joinedIndex.places] {
            precondition(places.count == 1 && places[0].visits.count == 1)
            let v = places[0].visits[0]
            precondition(v.id == leaving.persistentModelID && v.isConfirmed && v.visitName == "已确认的店")
            precondition(v.endedAt.timeIntervalSince(v.startedAt) == 1_920)
        }
        precondition(joined.days.flatMap(\.stays).map(\.duration) == [1_920])
        precondition(joinedIndex.days.flatMap(\.stays).map(\.duration) == [1_920])
        let mergedStay = joined.days.flatMap(\.entries).first { $0.stay?.isInferred == true }!
        let captured = arriving.startedAt.addingTimeInterval(180)
        precondition(joined.days[0].memoryKey(forPhotoAt: captured, coordinate: mergedStay.stay?.coordinate) == mergedStay.memoryKey)
        let gap = arriving.startedAt.addingTimeInterval(1200)
        precondition(joined.days[0].memoryKey(forPhotoAt: gap, coordinate: nil) == nil)
        let rawDay = RouteReview(routes: [arriving], calendar: calendar).days[0]
        let observedEntry = rawDay.entries.first { $0.kind == .visit }!
        precondition(joined.days[0].placement(forPhotoAt: captured, coordinate: nil, in: rawDay) == .record(observedEntry.memoryKey!))
        try VisitCorrection.save(observedEntry.stay!, name: "Separate visit", in: context)
        let observedKey = observedEntry.memoryKey!
        try observedKey.update(in: container) { memory, _ in memory.text = "Window seat" }
        try VisitCorrection.save(observedEntry.stay!, name: nil, in: context)
        let retained = RouteReview(routes: [leaving, arriving], calendar: calendar)
        precondition(retained.days.flatMap(\.entries).contains { $0.memoryKey == observedKey })
        precondition(retained.places.flatMap(\.visits).contains { $0.id == observedEntry.stay?.visitID })
        try VisitCorrection.save(joined.days[0].stays[0], name: nil, ignore: true, in: context)
        let ignored = RouteReview(routes: [leaving, arriving], calendar: calendar)
        precondition(ignored.days.flatMap(\.stays).map(\.duration) == [720])

        let visitStart = midnight.addingTimeInterval(5000)
        let observed = RecordedRoute(startedAt: visitStart)
        context.insert(observed)
        for seconds in stride(from: 0, through: 600, by: 30) {
            let fix = location(longitude: 0, at: visitStart.addingTimeInterval(Double(seconds)))
            context.insert(RoutePoint(location: fix, mode: .stationary, startsNewSegment: seconds == 0, route: observed))
            observed.pointCount += 1
        }
        try context.save()
        let stay = RouteReview(routes: [observed], calendar: calendar).days[0].stays[0]
        try VisitCorrection.save(stay, name: "隔壁咖啡店", in: context)
        let edited = RouteReview(routes: [observed], calendar: calendar)
        precondition(edited.places[0].visitName == "隔壁咖啡店")
        for (index, x) in [0.001, 0.002].enumerated() {
            let fix = location(longitude: x, at: visitStart.addingTimeInterval(Double(630 + index * 30)))
            context.insert(RoutePoint(location: fix, mode: .walking, startsNewSegment: index == 0, route: observed))
            observed.pointCount += 1
        }
        try context.save()
        let changed = RouteReview(routes: [observed], calendar: calendar)
        precondition(changed.journeys.first?.endpoints.startName == "隔壁咖啡店")
        let behavior = RouteBehavior(review: changed, range: midnight...midnight, calendar: calendar) { _ in .home }
        precondition(behavior.routine.isEmpty)
        var firstVisit = confirmed.places[0].visits[0]
        firstVisit.visitName = "书店"
        var laterVisit = edited.places[0].visits[0]
        laterVisit.visitName = "书店"
        let grouped = RoutePlace.group([laterVisit, firstVisit], within: 100)
        let recall = VisitRecallIndex(places: grouped)
        precondition(recall[firstVisit.id]?.previous == nil && recall[laterVisit.id]?.previous?.id == firstVisit.id)
        let all = RoutePlace.group(edited.places[0].visits + confirmed.places[0].visits, within: 100)
        precondition(all.count == 2)
    }

    @MainActor
    private static func checkTodayPlaceStays() throws {
        let store = try ModelContainer(for: RecordedRoute.self, RoutePoint.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = RoutePlaceNames(file: directory.appending(path: "places"))
        try names.save("测试之家", for: .init(latitude: 0, longitude: 0))
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: .now)
        let session = day.addingTimeInterval(3600)
        let now = day.addingTimeInterval(16 * 3600)
        var routes = [RecordedRoute]()
        func record(_ hour: Int, _ xs: [Double], legacy: Bool = false) -> RecordedRoute {
            let route = RecordedRoute(startedAt: day.addingTimeInterval(Double(hour * 3600)))
            route.isAutomatic = true
            route.isFinished = true
            if !legacy { route.endedAtRest = true; route.automaticSessionStart = session }
            store.mainContext.insert(route)
            for (i, x) in xs.enumerated() {
                let fix = location(longitude: x, at: route.startedAt.addingTimeInterval(Double(i * 60)))
                store.mainContext.insert(RoutePoint(location: fix, mode: .walking, startsNewSegment: i == 0, route: route))
                route.pointCount += 1
            }
            routes.insert(route, at: 0)
            return route
        }
        func stays(_ active: Date? = nil, on date: Date? = nil) -> [TodayPlaceStay] {
            RouteReviewCache().today(routes: routes, now: date ?? now, calendar: calendar,
                                                           places: names.snapshot, activeSession: active).stays
        }
        let arrival = record(7, [0.005, 0], legacy: true)
        let arrived = arrival.startedAt.addingTimeInterval(60)
        _ = record(8, [0.0001, 0.0003, 0])
        let local = record(10, [0, -0.0002, 0])
        let seen = local.startedAt.addingTimeInterval(120)
        try store.mainContext.save()
        let open = stays(session)
        precondition(open.count == 1 && open[0].startedAt == arrived && open[0].end == nil && open[0].name == "测试之家")
        precondition(stays().first?.end == seen && stays(now).first?.end == seen)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        let overnight = stays(session, on: tomorrow)
        precondition(overnight.count == 1 && overnight[0].startedAt == arrived && overnight[0].end == nil)
        let review = RouteReview(routes: routes, calendar: calendar)
        precondition(review.days.flatMap(\.stays).isEmpty && review.places.isEmpty)
        // Both endpoints are at home, but the interior point proves an actual outing.
        let outing = record(12, [0, 0.004, 0])
        var projected = stays(session)
        precondition(projected.count == 2 && projected[0].startedAt == arrived && projected[0].end == outing.startedAt)
        precondition(projected[1].startedAt == outing.startedAt.addingTimeInterval(120) && projected[1].end == nil)
        // A new session already away cannot supply the departure time for the prior one.
        outing.automaticSessionStart = outing.startedAt
        projected = stays(outing.startedAt)
        precondition(projected.first?.end == seen)
        outing.isAutomatic = false
        precondition(stays(session).allSatisfy { $0.end != nil })
    }

    @MainActor
    private static func checkAutomaticTrips() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RecordedRoute.self, RoutePoint.self, configurations: config)
        let context = container.mainContext
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var trips = AutomaticTrips(context: context)
        func send(_ seconds: Int, _ longitude: Double, paused: Bool = false, accuracy: Double = 5) throws {
            let time = start.addingTimeInterval(Double(seconds))
            try trips.receive(location(longitude: longitude, at: time, accuracy: accuracy),
                              stationary: paused, receivedAt: time)
        }
        try send(0, 0)
        try send(8, 0.00002)
        try send(9, 0.002, accuracy: 90)
        precondition(trips.route == nil)
        try send(30, 0.00035)
        let first = trips.route!
        precondition(first.pointCount == 2 && first.startedAt == start && first.distanceMeters > 25)
        try send(50, 0.0004, paused: true)
        precondition(first.isFinished && first.automaticPauseAt != nil)
        trips = AutomaticTrips(context: context)
        try trips.restore(now: start.addingTimeInterval(60))
        try send(90, 0.0004)
        try send(110, 0.0008)
        precondition(trips.route?.id == first.id && !first.isFinished && first.pointCount == 5)
        try send(100, 0.0015, paused: true)
        precondition(!first.isFinished)
        try send(120, 0.0008, paused: true)
        try send(720, 0.0008)
        try send(750, 0.0012)
        precondition(trips.route?.id == first.id && !first.isFinished)
        trips = AutomaticTrips(context: context)
        trips.sessionStart = start
        try trips.restore(now: start.addingTimeInterval(755))
        try send(780, 0.0016)
        precondition(trips.route?.id == first.id)
        for t in stride(from: 810, through: 1320, by: 30) { try send(t, 0.0016) }
        precondition(!first.isFinished && trips.route?.id == first.id)
        let saved = try context.fetch(FetchDescriptor<RecordedRoute>())
        precondition(saved.count == 1 && !RouteReview(routes: saved, calendar: .current).days.isEmpty)
        try send(1500, 0.002)
        try send(1530, 0.0024)
        let stale = trips.route!
        try trips.receive(nil, stationary: true, receivedAt: start.addingTimeInterval(6000))
        precondition(stale.isFinished && stale.endedAtRest != true)
        try send(7200, 0.0024)
        try send(7230, 0.0030)
        let invalid = trips.route!
        try send(8500, 0.0030, paused: true, accuracy: 500)
        precondition(invalid.isFinished && invalid.endedAtRest != true)
    }

    @MainActor
    private static func checkDrivingStops() throws {
        // Feed the live recorder, reopen its archive, then check both the timeline and the index.
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        func replay(shop: Bool, paused: Bool = false, creep: Double = 0, stopAndGo: Bool = false, restore: Bool = false, inVehicle: Bool = false, crawlBefore: Bool = false, crawlAfter: Bool = false, distantSignalLoss: Bool = false, latePause: Bool = false, resumeWhileMoving: Bool = false) throws {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let store = try ModelContainer(for: RecordedRoute.self, RoutePoint.self, configurations: config)
            var recorder = AutomaticTrips(context: store.mainContext)
            recorder.sessionStart = start
            if inVehicle { recorder.motionActivity = (.automotive, start) }
            var time = start
            var x = 0.0, y = 0.0
            func fix(_ speed: Double, paused: Bool = false) throws {
                let point = CLLocation(coordinate: .init(latitude: y / 111_195, longitude: x / 111_195), altitude: 0,
                                       horizontalAccuracy: 5, verticalAccuracy: 5, course: -1, courseAccuracy: -1,
                                       speed: speed, speedAccuracy: 0.5, timestamp: time)
                try recorder.receive(point, stationary: paused, receivedAt: time)
            }
            func move(_ seconds: Int, east: Double = 0, north: Double = 0) throws {
                for _ in stride(from: 0, to: seconds, by: 5) {
                    time.addTimeInterval(5)
                    x += east * 5
                    y += north * 5
                    try fix(hypot(east, north))
                }
            }
            func reopen() throws {
                recorder = AutomaticTrips(context: store.mainContext)
                recorder.sessionStart = start
                try recorder.restore(now: time)
            }
            try fix(10)
            try move(240, east: 10)
            if crawlBefore { try move(30); try move(50, east: 1) }
            if shop {
                try move(30)
                try move(40, north: 1)
                if distantSignalLoss {
                    time.addTimeInterval(150)
                    x += 3_000
                }
            }
            if paused {
                try move(25)
                time.addTimeInterval(5)
                try fix(0, paused: true)
                time.addTimeInterval(870)
                if restore { try reopen() }
                try fix(0)
            } else if stopAndGo {
                for _ in 0..<15 { try move(50); try move(10, east: 1) }
            } else {
                try move(600, east: creep)
                if restore { try reopen() }
                try move(300, east: creep)
            }
            if latePause {
                time.addTimeInterval(5)
                try fix(0, paused: true)
                time.addTimeInterval(25)
                if restore { try reopen() }
                if !resumeWhileMoving { try fix(0) }
            }
            if shop && !distantSignalLoss { try move(40, north: -1); try move(30) }
            if crawlAfter { try move(50, east: 1) }
            try move(240, east: 10)
            try recorder.end()

            let reader = ModelContext(store)
            let routes = try reader.fetch(FetchDescriptor<RecordedRoute>())
            let review = RouteReview(routes: routes, calendar: .current)
            let index = RouteSummary(records: routes.map { RouteReview.summaryRecord(for: $0, calendar: .current) })
            let entries = review.days.flatMap(\.entries)
            let hasVisit = shop && !inVehicle && !distantSignalLoss
            let expected = hasVisit ? 2 : 1
            precondition(routes.count == expected && review.journeys.count == expected && index.journeys.count == expected,
                         "shop=\(shop) paused=\(paused) latePause=\(latePause) restore=\(restore) raw=\(routes.count) cards=\(entries.map(\.kind))")
            precondition(entries.map(\.kind) == (hasVisit ? [.trip, .visit, .trip] : [.trip]))
            if hasVisit {
                precondition((entries[1].stay?.isCandidate == true) == paused)
            }
        }
        try replay(shop: false, stopAndGo: true)
        try replay(shop: false, creep: 1.0 / 60)
        try replay(shop: false)
        try replay(shop: false, paused: true, restore: true)
        try replay(shop: true)
        try replay(shop: true, restore: true)
        try replay(shop: true, paused: true, restore: true)
        try replay(shop: true, inVehicle: true)
        try replay(shop: true, distantSignalLoss: true)
        try replay(shop: true, restore: true, distantSignalLoss: true)
        try replay(shop: false, crawlBefore: true)
        try replay(shop: false, crawlAfter: true)
        try replay(shop: false, crawlBefore: true, crawlAfter: true)
        try replay(shop: false, paused: true, crawlBefore: true, crawlAfter: true)
        try replay(shop: false, crawlBefore: true, latePause: true)
        try replay(shop: false, restore: true, crawlBefore: true, latePause: true)
        try replay(shop: false, crawlBefore: true, latePause: true, resumeWhileMoving: true)
        try replay(shop: false, restore: true, crawlBefore: true, latePause: true, resumeWhileMoving: true)
        try replay(shop: true, latePause: true)
        try replay(shop: true, restore: true, latePause: true)

        // Earlier recorders wrote separate rows for the same vehicle stop.
        let store = try ModelContainer(for: RecordedRoute.self, RoutePoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = store.mainContext
        let arrival = insertRoute(context: context, start: start, samples:
            [(0, 0, .automotive, true), (30, 0.002, .automotive, false)] + stop(start: 60, longitude: 0.002))
        let departure = insertRoute(context: context, start: start.addingTimeInterval(1_200), samples:
            [(0, 0.002, .unknown, true), (10, 0.0028, .automotive, false), (40, 0.005, .automotive, false)])
        for route in [arrival, departure] { route.isAutomatic = true; route.automaticSessionStart = start }
        arrival.endedAtRest = true
        departure.previousAutomaticRouteID = arrival.id
        try context.save()
        let routes = [departure, arrival]
        let merged = RouteReview(routes: routes, calendar: .current)
        precondition(merged.days.flatMap(\.entries).map(\.kind) == [.trip] && merged.journeys.count == 1)
        precondition(RouteSummary(records: routes.map { RouteReview.summaryRecord(for: $0, calendar: .current) }).journeys.count == 1)
        departure.arrivalDecision = "confirmed"
        precondition(RouteReview(routes: routes, calendar: .current).days.flatMap(\.entries).map(\.kind) == [.trip, .visit, .trip])
        departure.arrivalDecision = nil
        departure.automaticSessionStart = start.addingTimeInterval(1_200)
        precondition(RouteReview(routes: routes, calendar: .current).journeys.count == 2)
    }

    @MainActor
    private static func checkLegacyDrivingEdges() throws {
        let store = try ModelContainer(for: RecordedRoute.self, RoutePoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = store.mainContext
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        func oldRoute(_ seconds: Double, _ samples: [Sample], after previous: RecordedRoute? = nil) -> RecordedRoute {
            let route = insertRoute(context: context, start: start.addingTimeInterval(seconds), samples: samples)
            route.isAutomatic = true
            route.automaticSessionStart = start
            route.previousAutomaticRouteID = previous?.id
            route.endedAtRest = true
            return route
        }
        func verify(_ routes: [RecordedRoute], expectedModes: [TravelMode]) {
            let review = RouteReview(routes: routes, calendar: .current)
            let indexed = RouteSummary(records: routes.map { RouteReview.summaryRecord(for: $0, calendar: .current) })
            precondition(review.journeys.map(\.mode) == expectedModes && indexed.journeys.map(\.mode) == expectedModes)
            precondition(review.days.flatMap(\.entries).filter { $0.kind == .trip }.count == expectedModes.count)
        }
        let beforeMidnight = Calendar.current.startOfDay(for: start).timeIntervalSince(start)
        let a = oldRoute(beforeMidnight - 400, [(0, 0, .automotive, true), (30, 0.003, .automotive, false)])
        let b = oldRoute(beforeMidnight - 15, [(0, 0.003, .automotive, true), (30, 0.006, .automotive, false)], after: a)
        try context.save()
        let joined = RouteReview(routes: [a, b], calendar: .current)
        let joinedKeys = joined.days.flatMap(\.entries).filter { $0.kind == .trip }.compactMap(\.memoryKey)
        precondition(joined.journeys.count == 1 && joinedKeys.count == 2 && Set(joinedKeys).count == 1)

        let todayOnly = RouteReviewCache().day(routes: [b, a], containing: Calendar.current.startOfDay(for: start), calendar: .current)
        precondition(todayOnly.days.first?.entries.first?.memoryKey == joinedKeys.first)

        let visit = insertRoute(context: context, start: start, samples: stop(start: 0, longitude: 0.2))
        let visitDay = RouteReviewCache().day(routes: [visit, b, a], containing: start, calendar: .current).days.first!
        precondition(visitDay.entries.contains { $0.kind == .visit })
        precondition(visitDay.entries.first { $0.kind == .trip }?.memoryKey == joinedKeys.first)
        let raw = RouteReviewCache().detail(for: b, among: [visit, b, a], calendar: .current)
        precondition(raw.days.flatMap(\.entries).filter { $0.kind == .trip }.allSatisfy { $0.memoryKey == joinedKeys.first })

        let changing = insertRoute(context: context, start: start, samples: [(0, 0, .unknown, true), (30, 0.0003, .unknown, false)])
        try context.save()
        let before = RouteReview(routes: [changing], calendar: .current).days[0].entries[0]
        precondition(before.kind == .trip)
        let memory = try before.memoryKey!.memory(in: context)
        memory.text = "Original note"
        memory.draft = "Original draft"
        for seconds in stride(from: 60, through: 600, by: 30) {
            context.insert(RoutePoint(location: location(longitude: 0.0003, at: start.addingTimeInterval(Double(seconds))),
                                      mode: .unknown, startsNewSegment: false, route: changing))
            changing.pointCount += 1
        }
        try context.save()
        let after = RouteReview(routes: [changing], calendar: .current).days[0].entries[0]
        precondition(after.kind == .visit)
        let restored = try after.memoryKey!.memory(in: context)
        precondition(restored.text == memory.text && restored.draft == memory.draft)

        let walking: [Sample] = [(0, 0, .walking, true), (30, 0.00035, .walking, false), (60, 0.0007, .walking, false)]
        let isolated = oldRoute(0, walking + stop(start: 90, longitude: 0.0007) + [(1_000, 0.04, .automotive, true)])
        let next = oldRoute(2_000, [(0, 0.04, .automotive, true), (30, 0.042, .automotive, false)], after: isolated)
        verify([next, isolated], expectedModes: [.walking, .automotive])

        let first = oldRoute(0, walking + [(90, 0.002, .automotive, false), (120, 0.004, .automotive, false)])
        let middle = oldRoute(700, [(0, 0.004, .automotive, true), (20, 0.006, .automotive, false)], after: first)
        var lastLeg: [Sample] = [(0, 0.006, .automotive, true), (10, 0.007, .automotive, false)]
        lastLeg += stride(from: 30, through: 330, by: 30).map { (Double($0), 0.007 + Double($0) / 80_000, .walking, false) }
        let last = oldRoute(1_400, lastLeg, after: middle)
        verify([last, first, middle], expectedModes: [.walking])
    }

    private static func location(longitude: Double, at timestamp: Date, accuracy: Double = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            timestamp: timestamp
        )
    }
}
