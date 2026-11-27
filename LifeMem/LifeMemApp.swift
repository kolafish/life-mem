import CoreLocation
import Foundation
import SwiftData
import SwiftUI

@main
struct LifeMemApp: App {
    private static let storageDirectory: URL = {
        #if DEBUG && targetEnvironment(simulator)
        if ReviewTestFixture.scenario != nil {
            return URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "LifeMem", directoryHint: .isDirectory)
    }()

    private let storage: Result<ModelContainer, Error>
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
        _placeResolver = State(initialValue: PlaceResolver(
            file: Self.storageDirectory.appending(path: "place-suggestions.json"),
            defaults: preferences
        ))
        storage = Result {
            let container = try RouteStore.open(directory: Self.storageDirectory)
            #if DEBUG && targetEnvironment(simulator)
            try ReviewTestFixture.seed(context: container.mainContext, names: names)
            #endif
            return container
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case let .success(container):
                RootView(context: container.mainContext, summaryFile: Self.storageDirectory.appending(path: "daily-summary.json"))
                    .modelContainer(container)
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
    @Query(filter: #Predicate<RecordedRoute> { $0.pointCount > 0 }, sort: \RecordedRoute.startedAt, order: .reverse)
    private var routes: [RecordedRoute]
    @State private var recorder: RouteRecorder
    @State private var selection = Tab.record
    @State private var review: RouteReview?
    @State private var reviewCache = RouteReviewCache()
    @State private var summary: RouteSummary?
    @State private var index: RouteSummaryIndex

    init(context: ModelContext, summaryFile: URL) {
        _index = State(initialValue: RouteSummaryIndex(file: summaryFile))
        _recorder = State(initialValue: RouteRecorder(context: context))
    }

    var body: some View {
        let request = selection == .record ? nil : Request(tab: selection, revision: RouteReviewRevision(calendar: calendar, routes: routes))
        TabView(selection: $selection) {
            NavigationStack {
                RecordView(recorder: recorder)
            }
            .tabItem { Label("记录", systemImage: "location.circle") }
            .tag(Tab.record)

            NavigationStack {
                RouteHistoryView(review: review, hasRoutes: !routes.isEmpty, summaryIndex: index)
            }
            .tabItem { Label("回顾", systemImage: "calendar") }
            .tag(Tab.review)

            NavigationStack {
                AnalyticsView(summary: summary)
            }
            .tabItem { Label("分析", systemImage: "chart.bar.xaxis") }
            .tag(Tab.analytics)
        }
        .tint(.indigo)
        .task(id: request) {
            guard let request, !Task.isCancelled else { return }
            if request.tab == .review {
                review = reviewCache.review(routes: routes, calendar: request.revision.calendar)
            }
            let indexed = await index.records(for: request.revision)
            guard !Task.isCancelled,
                  request.revision == RouteReviewRevision(calendar: calendar, routes: routes) else { return }
            let records = reviewCache.summaries(for: routes, revision: request.revision, indexed: indexed)
            summary = RouteSummary(records: request.revision.routes.compactMap { records[$0] })
            await index.save(records, for: request.revision, after: .seconds(1))
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
}

#if DEBUG && targetEnvironment(simulator)
private enum ReviewTestFixture {
    static let scenario = ProcessInfo.processInfo.environment["LIFEMEM_UI_TEST_FIXTURE"]

    @MainActor
    static func seed(context: ModelContext, names: RoutePlaceNames) throws {
        if scenario == "suggestions" {
            try seedSuggestions(context: context)
            return
        }
        guard scenario == "day" else { return }
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
                    coordinate: .init(latitude: 37.3317, longitude: -122.0307 + offset),
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
                add(seconds, offset: 0.0105, mode: .stationary)
            }
            for seconds in stride(from: 1_920 + daysAgo * 60, through: 2_100 + daysAgo * 60, by: 30) {
                add(seconds, offset: 0.0105 - Double(seconds - 1_890 - daysAgo * 60) / 20_000, mode: .automotive)
            }
            for seconds in stride(from: 2_130 + daysAgo * 60, through: 2_730 + daysAgo * 60, by: 30) {
                add(seconds, offset: 0, mode: .stationary)
            }
        }
        try names.save("测试之家", category: .home, for: .init(latitude: 37.3317, longitude: -122.0307))
        try names.save("测试办公室", category: .work, for: .init(latitude: 37.3317, longitude: -122.0202))
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
