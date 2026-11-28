import CoreLocation
import Foundation
import SwiftData
import SwiftUI

@main
struct LifeMemApp: App {
    private static let storageDirectory: URL = {
        #if DEBUG && targetEnvironment(simulator)
        if ReviewTestFixture.scenario != nil {
            return URL.temporaryDirectory.appending(path: ReviewTestFixture.storageID.uuidString, directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "LifeMem", directoryHint: .isDirectory)
    }()

    private struct AppStorage {
        let container: ModelContainer
        let recorder: RouteRecorder
        let index: RouteSummaryIndex
    }

    private let storage: Result<AppStorage, Error>
    @State private var placeNames: RoutePlaceNames
    @State private var placeResolver: PlaceResolver

    init() {
        let names = RoutePlaceNames(file: Self.storageDirectory.appending(path: "place-names.json"))
        var preferences = UserDefaults.standard
        #if DEBUG && targetEnvironment(simulator)
        if ReviewTestFixture.scenario != nil,
           let isolated = UserDefaults(suiteName: "LifeMemUITests.\(Self.storageDirectory.lastPathComponent)") {
            preferences = isolated
        }
        #endif
        _placeNames = State(initialValue: names)
        let lookup: PlaceResolver.Lookup?
        #if DEBUG && targetEnvironment(simulator)
        lookup = ReviewTestFixture.scenario == "prefetch" ? { _, _ in
            .init(.ranked(points: [
                .init(name: "测试咖啡店", distance: 15, isLandmark: false),
                .init(name: "测试便利店", distance: 22, isLandmark: false)
            ], address: .init(street: "测试街道")))
        } : nil
        #else
        lookup = nil
        #endif
        _placeResolver = State(initialValue: PlaceResolver(
            file: Self.storageDirectory.appending(path: "place-suggestions.json"),
            defaults: preferences,
            lookup: lookup
        ))
        storage = Result {
            #if DEBUG && targetEnvironment(simulator)
            let shouldSeed = ReviewTestFixture.scenario != nil && !FileManager.default.fileExists(atPath: Self.storageDirectory.path)
            #endif
            let container = try RouteStore.open(directory: Self.storageDirectory)
            #if DEBUG && targetEnvironment(simulator)
            if shouldSeed { try ReviewTestFixture.seed(context: container.mainContext, names: names, directory: Self.storageDirectory) }
            #endif
            let index = RouteSummaryIndex(file: Self.storageDirectory.appending(path: "daily-summary.json"))
            let recorder = RouteRecorder(context: container.mainContext, summaryIndex: index, preferences: preferences)
            return AppStorage(container: container, recorder: recorder, index: index)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case let .success(store):
                RootView(recorder: store.recorder, index: store.index)
                    .modelContainer(store.container)
                    .environment(placeNames)
                    .environment(placeResolver)
            case .failure:
                ContentUnavailableView(
                    "暂时无法打开路线存储",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("请检查可用存储空间，再重新打开 Life Mem。")
                )
            }
        }
    }
}

private struct RootView: View {
    private enum Tab {
        case record, review, analytics
    }

    private struct Request: Equatable {
        let tab: Tab
        let revision: RouteReviewRevision
    }

    @Environment(\.calendar) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @Query(filter: #Predicate<RecordedRoute> { $0.pointCount > 0 }, sort: \RecordedRoute.startedAt, order: .reverse)
    private var routes: [RecordedRoute]
    let recorder: RouteRecorder
    @State private var selection = Tab.record
    @State private var today = Date.now
    @State private var todayCache = RouteReviewCache()
    @State private var todayReview: RouteReview?
    @State private var review: RouteReview?
    @State private var reviewCache = RouteReviewCache()
    @State private var summary: RouteSummary?
    @State private var summaryRevision: RouteReviewRevision?
    let index: RouteSummaryIndex

    var body: some View {
        let midnight = calendar.startOfDay(for: today)
        let recent = Array(routes.prefix { $0.startedAt >= midnight })
        let todayRoutes = recent + Array(routes.dropFirst(recent.count).prefix(1))
        let request = Request(tab: selection, revision: RouteReviewRevision(calendar: calendar, routes: routes))
        let prefetchRoutes = recentFinishedRoutesForPrefetch
        let prefetch = prefetchRoutes.isEmpty ? nil : RouteReviewRevision(calendar: calendar, routes: prefetchRoutes)
        TabView(selection: $selection) {
            NavigationStack {
                RecordView(recorder: recorder, day: todayReview?.days.first { $0.date == midnight }, loading: todayReview == nil && !todayRoutes.isEmpty)
            }
            .tabItem { Label("今天", systemImage: "sun.max") }
            .tag(Tab.record)

            NavigationStack {
                RouteHistoryView(review: review, hasRoutes: !routes.isEmpty, recorder: recorder)
            }
            .tabItem { Label("回顾", systemImage: "calendar") }
            .tag(Tab.review)

            NavigationStack {
                AnalyticsView(summary: summary, isSelected: selection == .analytics)
            }
            .tabItem { Label("分析", systemImage: "chart.bar.xaxis") }
            .tag(Tab.analytics)
        }
        .environment(\.visitRecall, summary?.recall ?? VisitRecallIndex())
        .environment(\.currentRouteReview, selection == .record ? todayReview : review)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in today = .now }
        .onChange(of: scenePhase) { if scenePhase == .active { today = .now } }
        .tint(.indigo)
        .task(id: request) {
            guard !Task.isCancelled else { return }
            if request.tab == .record {
                todayReview = todayCache.review(routes: todayRoutes, calendar: request.revision.calendar)
            }
            if request.tab == .review {
                review = reviewCache.review(routes: routes, calendar: request.revision.calendar)
            }
            let indexed = await index.records(for: request.revision)
            guard !Task.isCancelled,
                  request.revision == RouteReviewRevision(calendar: calendar, routes: routes) else { return }
            let records = reviewCache.summaries(for: routes, revision: request.revision, indexed: indexed)
            if summaryRevision != request.revision {
                summary = RouteSummary(records: request.revision.routes.compactMap { records[$0] }, calendar: request.revision.calendar)
                summaryRevision = request.revision
            }
            await index.save(records, for: request.revision, after: .seconds(1))
        }
        .task(id: prefetch) {
            guard let prefetch else { return }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            let indexed = await index.records(for: prefetch)
            guard !Task.isCancelled, prefetchRoutes.allSatisfy({ !$0.isDeleted }) else { return }
            let now = Date.now
            let oldest = prefetch.calendar.date(byAdding: .day, value: -7, to: now) ?? now
            let visits = reviewCache.visits(for: prefetchRoutes, revision: prefetch, indexed: indexed)
                .filter { (oldest...now).contains($0.endedAt) }
                .sorted { $0.endedAt > $1.endedAt }
            await placeResolver.prefetch(visits, names: placeNames)
        }
        .alert("Life Mem", isPresented: Binding(
            get: { recorder.notice != nil },
            set: { if !$0 { recorder.notice = nil } }
        )) {
            Button("好") { recorder.notice = nil }
        } message: {
            Text(recorder.notice ?? "")
        }
    }

    private var recentFinishedRoutesForPrefetch: [RecordedRoute] {
        guard placeResolver.isPrefetchEnabled, placeNames.loadIssue == nil, scenePhase == .active,
              !recorder.isDeletingRoute, recorder.state == .idle || recorder.state == .paused else { return [] }
        return Array(routes.lazy.filter(\.isFinished).prefix(8))
    }
}

#if DEBUG && targetEnvironment(simulator)
private enum ReviewTestFixture {
    static let scenario = ProcessInfo.processInfo.environment["LIFEMEM_UI_TEST_FIXTURE"]
    static let storageID = ProcessInfo.processInfo.environment["LIFEMEM_UI_TEST_STORAGE_ID"].flatMap(UUID.init(uuidString:)) ?? UUID()

    @MainActor
    static func seed(context: ModelContext, names: RoutePlaceNames, directory: URL) throws {
        if scenario == "suggestions" || scenario == "prefetch" {
            try seedSuggestions(context: context)
            return
        }
        if scenario == "unfinished" {
            let start = Date.now.addingTimeInterval(-600)
            let older = RecordedRoute(startedAt: start)
            let empty = RecordedRoute(startedAt: start.addingTimeInterval(300))
            context.insert(older)
            context.insert(empty)
            let location = CLLocation(coordinate: .init(latitude: 37.3317, longitude: -122.0307),
                                      altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start)
            context.insert(RoutePoint(location: location, mode: .walking, startsNewSegment: true, route: older))
            older.pointCount = 1
            try context.save()
            return
        }
        if scenario == "midnight" {
            let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(-3_600))
            let start = midnight.addingTimeInterval(-20)
            let route = RecordedRoute(startedAt: start)
            route.isFinished = true
            context.insert(route)
            for index in 0...1 {
                let location = CLLocation(coordinate: .init(latitude: 37.3317, longitude: -122.0307 + Double(index) * 0.001),
                                          altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                          timestamp: start.addingTimeInterval(Double(index) * 40))
                context.insert(RoutePoint(location: location, mode: .walking, startsNewSegment: index == 0, route: route))
                route.pointCount += 1
            }
            try context.save()
            return
        }
        guard scenario == "day" || scenario == "mainland-day" || scenario == "damaged-names" else { return }
        let origin = scenario == "mainland-day"
            ? CLLocationCoordinate2D(latitude: 39.9, longitude: 116.3)
            : CLLocationCoordinate2D(latitude: 37.3317, longitude: -122.0307)
        let officeOffset = 0.0105
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for daysAgo in 0...1 {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            let start = day.addingTimeInterval(Double(8 * 3_600 + daysAgo * 3_600))
            let route = RecordedRoute(startedAt: start)
            route.isFinished = true
            context.insert(route)

            func add(_ seconds: Int, offset: Double, mode: TravelMode) {
                let location = CLLocation(
                    coordinate: .init(latitude: origin.latitude, longitude: origin.longitude + offset),
                    altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                    timestamp: start.addingTimeInterval(Double(seconds))
                )
                let point = RoutePoint(location: location, mode: mode, startsNewSegment: seconds == 0,
                                       startsRecordingRun: seconds == 0, route: route)
                context.insert(point)
                route.pointCount += 1
            }

            for seconds in stride(from: 0, through: 600, by: 30) {
                add(seconds, offset: 0, mode: .stationary)
            }
            for seconds in stride(from: 630, through: 810, by: 30) {
                add(seconds, offset: Double(seconds - 600) / 80_000, mode: .walking)
            }
            for seconds in stride(from: 840, through: 960 + daysAgo * 60, by: 30) {
                add(seconds, offset: 0.003 + Double(seconds - 810) / 20_000, mode: .automotive)
            }
            for seconds in stride(from: 990 + daysAgo * 60, through: 1_890 + daysAgo * 60, by: 30) {
                add(seconds, offset: officeOffset, mode: .stationary)
            }
            for seconds in stride(from: 1_920 + daysAgo * 60, through: 2_100 + daysAgo * 60, by: 30) {
                add(seconds, offset: officeOffset - Double(seconds - 1_890 - daysAgo * 60) / 20_000, mode: .automotive)
            }
            for seconds in stride(from: 2_130 + daysAgo * 60, through: 2_730 + daysAgo * 60, by: 30) {
                add(seconds, offset: 0, mode: .stationary)
            }
        }
        if scenario == "damaged-names" {
            try Data("incomplete".utf8).write(to: directory.appending(path: "place-names.json"))
            names.reload()
        } else {
            try names.save("测试之家", category: .home, for: origin)
            try names.save("测试办公室", category: .work,
                           for: .init(latitude: origin.latitude, longitude: origin.longitude + officeOffset))
        }
        try context.save()
    }

    private static func seedSuggestions(context: ModelContext) throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for offset in 1...3 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let start = date.addingTimeInterval(2 * 3_600)
            let route = RecordedRoute(startedAt: start)
            route.isFinished = true
            context.insert(route)
            for seconds in stride(from: 0, through: 30 * 60, by: 60) {
                let location = CLLocation(coordinate: .init(latitude: 37.3317, longitude: -122.0307),
                                          altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                          timestamp: start.addingTimeInterval(Double(seconds)))
                context.insert(RoutePoint(location: location, mode: .stationary, startsNewSegment: seconds == 0, route: route))
                route.pointCount += 1
            }
        }
        try context.save()
    }
}
#endif
