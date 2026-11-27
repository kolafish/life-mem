import MapKit
import SwiftData
import SwiftUI

struct RouteHistoryView: View {
    let review: RouteReview?
    let hasRoutes: Bool
    let recorder: RouteRecorder

    @Environment(\.calendar) private var calendar
    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @State private var mode = BrowseMode.timeline
    @State private var showsArchive = false
    @State private var confirmsAutomaticLookup = false
    @State private var confirmsCacheRemoval = false
    @State private var cacheRemovalFailed = false

    private enum BrowseMode: String, CaseIterable {
        case timeline = "时间线"
        case places = "地点"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !placeResolver.hasSeenAutomaticIntroduction, !placeResolver.isAutomaticEnabled,
               placeNames.loadIssue == nil, let review,
               review.places.contains(where: { placeResolver.label(near: $0.coordinate, names: placeNames) == nil }) {
                automaticIntroduction
            }
            if hasRoutes {
                ReviewModePicker(selection: $mode)
            }
            if let review {
                history(review)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("回顾")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("管理记录", systemImage: "tray.full") { showsArchive = true }
                    if placeResolver.isAutomaticEnabled {
                        Button("关闭自动地名", systemImage: "mappin.slash") {
                            placeResolver.setAutomaticEnabled(false)
                        }
                        if !placeResolver.isPrefetchEnabled {
                            Button("提前准备地名", systemImage: "mappin.and.ellipse") { confirmsAutomaticLookup = true }
                        }
                    } else {
                        Button("开启自动地名", systemImage: "mappin.and.ellipse") {
                            confirmsAutomaticLookup = true
                        }
                    }
                    Button("清除地名建议缓存", systemImage: "trash", role: .destructive) {
                        confirmsCacheRemoval = true
                    }
                } label: {
                    Label("回顾选项", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
            }
        }
        .alert("开启自动地名？", isPresented: $confirmsAutomaticLookup) {
            Button("开启") {
                placeResolver.dismissAutomaticIntroduction()
                placeResolver.setAutomaticEnabled(true, includesPrefetch: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 在前台时，Apple 地图会使用未命名停留的中心坐标查找地名，包括提前准备最近的停留地点。可以随时在回顾选项里关闭。")
        }
        .alert("清除地名建议缓存？", isPresented: $confirmsCacheRemoval) {
            Button("清除", role: .destructive) {
                do {
                    try placeResolver.clearCache()
                } catch {
                    cacheRemovalFailed = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除缓存的地图建议及查询坐标。你保存的地名仍可使用。")
        }
        .alert("暂时无法清除缓存", isPresented: $cacheRemovalFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请检查设备的可用存储空间后重试。")
        }
        .sheet(isPresented: $showsArchive) {
            NavigationStack { RouteArchiveView(recorder: recorder) }
        }
    }

    private var automaticIntroduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("为停留显示地名").font(.headline)
            Text("允许 Apple 地图查找附近地名，下次回顾时可以直接看到。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { introductionActions }
                VStack(alignment: .leading, spacing: 0) { introductionActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var introductionActions: some View {
        Button { confirmsAutomaticLookup = true } label: {
            Text("开启自动地名").frame(minHeight: 44)
        }
        Button { placeResolver.dismissAutomaticIntroduction() } label: {
            Text("以后再说").frame(minHeight: 44)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func history(_ review: RouteReview) -> some View {
        if review.days.isEmpty {
            ContentUnavailableView("还没有记录", systemImage: "calendar", description: Text("开始记录后，可以在这里按天回看。"))
        } else if mode == .timeline {
            timeline(review.days)
        } else if review.places.isEmpty {
            ContentUnavailableView("暂无停留地点", systemImage: "mappin.circle", description: Text("记录到持续停留后，可以在这里回看历次到访。"))
        } else {
            let suggestions = PlaceSuggestions.candidates(in: review.places, calendar: calendar, category: placeNames.category(for:))
            List {
                if !suggestions.isEmpty {
                    Section("常用地点建议") {
                        ForEach(suggestions) { item in
                            NavigationLink {
                                RoutePlaceReviewView(place: item.place, days: review.days, suggestedCategory: item.category)
                            } label: {
                                Label {
                                    ReviewTextRow(title: "建议设为\(item.category.title)", detail: "\(item.observedDays) 天有相符的停留")
                                } icon: {
                                    Image(systemName: item.category.symbol).foregroundStyle(.indigo)
                                }
                            }
                            .accessibilityIdentifier("place-suggestion-\(item.category.rawValue)")
                        }
                    }
                }
                Section {
                    ForEach(review.places) { place in
                        let name = placeResolver.label(near: place.coordinate, names: placeNames)
                        let visitCount = "\(place.visits.count) 次到访"
                        let lastVisit = "最近 \(place.mostRecentVisit.startedAt.formatted(.dateTime.year().month().day().hour().minute()))"
                        NavigationLink {
                            RoutePlaceReviewView(place: place, days: review.days)
                        } label: {
                            Label {
                                ReviewTextRow(
                                    title: name ?? visitCount,
                                    detail: name == nil ? lastVisit : "\(visitCount) · \(lastVisit)"
                                )
                            } icon: {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(.indigo)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func timeline(_ days: [RouteReviewDay]) -> some View {
        let months = Dictionary(grouping: days) { calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
        return List {
            ForEach(months.keys.sorted(by: >), id: \.self) { month in
                Section {
                    ForEach(months[month, default: []]) { day in
                        NavigationLink {
                            RouteDayReviewView(day: day)
                        } label: {
                            ReviewTextRow(
                                title: day.date.formatted(.dateTime.month().day().weekday(.wide)),
                                detail: daySummary(day)
                            )
                        }
                        .accessibilityIdentifier("review-day")
                    }
                } header: {
                    Text(month, format: .dateTime.year().month(.wide))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func daySummary(_ day: RouteReviewDay) -> String {
        let name = day.entries.lazy.compactMap(\.visitCoordinate).compactMap { placeResolver.label(near: $0, names: placeNames) }.first
        return name.map { "\(day.summary) · \($0)" } ?? day.summary
    }

    private struct ReviewModePicker: View {
        @Environment(\.dynamicTypeSize) private var typeSize
        @Binding var selection: BrowseMode

        var body: some View {
            Group {
                if typeSize.isAccessibilitySize {
                    picker.pickerStyle(.menu)
                } else {
                    picker.pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
        }

        private var picker: some View {
            Picker("回顾方式", selection: $selection) {
                ForEach(BrowseMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        }
    }
}

private struct RoutePlaceReviewView: View {
    let place: RoutePlace
    let days: [RouteReviewDay]
    var suggestedCategory: PlaceCategory? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @State private var namingTarget: PlaceNamingTarget?

    var body: some View {
        let canLookUp = scenePhase == .active && suggestedCategory == nil && placeResolver.isAutomaticEnabled && namingTarget == nil
        let name = placeResolver.label(near: place.coordinate, names: placeNames)
        let mapCoordinate = RouteMapProjection.standard.coordinate(for: place.coordinate)
        let daysByDate = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        List {
            Section {
                Map(
                    initialPosition: .region(MKCoordinateRegion(center: mapCoordinate, latitudinalMeters: 500, longitudinalMeters: 500)),
                    interactionModes: [.pan, .zoom]
                ) {
                    Marker(name ?? "停留地点", coordinate: mapCoordinate).tint(.indigo)
                }
                .mapStyle(.standard(emphasis: .muted))
                .frame(height: 220)
                .accessibilityLabel("停留地点地图")
                .listRowInsets(EdgeInsets())
                if let suggestedCategory, placeNames.category(for: place.coordinate) == nil {
                    Button("设为\(suggestedCategory.title)") {
                        namingTarget = PlaceNamingTarget(
                            title: "确认地点分类", coordinate: place.coordinate, suggestedCategory: suggestedCategory
                        )
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                Button(placeNames.name(for: place.coordinate) == nil ? "给地点命名" : "编辑地名") {
                    namingTarget = PlaceNamingTarget(title: "停留地点", coordinate: place.coordinate)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            Section("到访记录") {
                ForEach(place.visits.reversed()) { visit in
                    if let day = daysByDate[visit.date] {
                        NavigationLink {
                            RouteDayReviewView(day: day, focus: visit.id, allowsAutomaticLookup: suggestedCategory == nil)
                        } label: {
                            ReviewTextRow(
                                title: visit.startedAt.formatted(.dateTime.year().month().day().weekday(.abbreviated)),
                                detail: visit.startedAt.formatted(.dateTime.hour().minute())
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name ?? "停留地点")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: canLookUp) {
            guard canLookUp else { return }
            await placeResolver.resolveAutomatically(near: place.coordinate, names: placeNames)
        }
        .sheet(item: $namingTarget) { target in
            PlaceNamingView(
                target: target,
                initialName: placeNames.name(for: target.coordinate) ?? target.suggestedCategory?.defaultName,
                category: placeNames.category(for: target.coordinate) ?? target.suggestedCategory
            )
        }
    }
}

private struct RouteDayReviewView: View {
    let day: RouteReviewDay

    @Environment(\.scenePhase) private var scenePhase
    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection: Selection
    @State private var namingTarget: PlaceNamingTarget?
    private let initialFocus: RouteReviewEntry.ID?
    private let allowsAutomaticLookup: Bool

    private struct Selection {
        var id: RouteReviewEntry.ID?
        private(set) var request = UUID()

        mutating func focus(_ id: RouteReviewEntry.ID) {
            self.id = id
            request = UUID()
        }
    }

    init(day: RouteReviewDay, focus: RouteReviewEntry.ID? = nil, allowsAutomaticLookup: Bool = true) {
        self.day = day
        initialFocus = focus
        self.allowsAutomaticLookup = allowsAutomaticLookup
        _selection = State(initialValue: Selection(id: focus))
    }

    var body: some View {
        let canLookUp = scenePhase == .active && allowsAutomaticLookup && placeResolver.isAutomaticEnabled && namingTarget == nil
        let selected = day.entries.first { $0.id == selection.id }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    DailySummaryCard(day: day)
                    Section {
                        ForEach(day.entries) { entry in
                            if entry.followsGap {
                                Label("记录中断", systemImage: "ellipsis")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 12)
                            }
                            TimelineSegmentRow(entry: entry, selected: selection.id == entry.id) {
                                selection.focus(entry.id)
                            } nameTarget: { target in
                                namingTarget = target
                            }
                            .id(entry.id)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("时间线").font(.headline).accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 8)
                                if selected != nil {
                                    Button("显示全天") { selection.id = nil }
                                        .font(.subheadline)
                                        .frame(minHeight: 44)
                                }
                            }
                            .frame(minHeight: 44)
                            RouteMapContainer(entries: day.entries, selected: selected, focusRequest: selection.request) { id in
                                selection.focus(id)
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            }
                            .frame(height: typeSize.isAccessibilitySize ? 145 : 184)
                            .clipShape(.rect(cornerRadius: 16))
                        }
                        .padding(.bottom, 8)
                        .background(Color(uiColor: .systemGroupedBackground))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .task {
                if let initialFocus { proxy.scrollTo(initialFocus, anchor: .bottom) }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(day.date.formatted(.dateTime.month().day().weekday(.abbreviated)))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: canLookUp) {
            guard canLookUp else { return }
            await placeResolver.resolveAutomatically(near: day.entries.compactMap(\.visitCoordinate), names: placeNames)
        }
        .sheet(item: $namingTarget) { target in
            PlaceNamingView(
                target: target,
                initialName: placeNames.name(for: target.coordinate),
                category: placeNames.category(for: target.coordinate)
            )
        }
    }
}

struct RouteDetailView: View {
    let route: RecordedRoute

    @Environment(\.calendar) private var calendar
    @State private var selectedDate: Date?

    var body: some View {
        let days = RouteReview(routes: [route], calendar: calendar).days
        if let day = days.first(where: { $0.date == selectedDate }) ?? days.first {
            RouteDayReviewView(day: day)
                .id(day.id)
                .toolbar {
                    if days.count > 1 {
                        ToolbarItem(placement: .topBarTrailing) {
                            DayPickerHeader(
                                days: days,
                                selection: Binding(get: { day.date }, set: { selectedDate = $0 })
                            )
                        }
                    }
                }
        } else {
            ContentUnavailableView("这条路线没有定位记录", systemImage: "map")
                .navigationTitle("路线回看")
        }
    }
}

private struct RouteArchiveView: View {
    let recorder: RouteRecorder

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecordedRoute.startedAt, order: .reverse)
    private var routes: [RecordedRoute]
    @State private var routeToDelete: RecordedRoute?
    @State private var deleteFailed = false

    var body: some View {
        Group {
            if routes.isEmpty {
                ContentUnavailableView("没有可管理的记录", systemImage: "tray")
            } else {
                List(routes) { route in
                    NavigationLink {
                        RouteDetailView(route: route)
                    } label: {
                        ReviewTextRow(
                            title: route.startedAt.formatted(date: .abbreviated, time: .shortened),
                            detail: route.isFinished ? route.formattedDistance : "未结束 · \(route.pointCount == 0 ? "还没有定位点" : route.formattedDistance)"
                        )
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        if recorder.canDelete(route) {
                            Button(role: .destructive) { routeToDelete = route } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("管理记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .confirmationDialog("删除这条路线？", isPresented: Binding(
            get: { routeToDelete != nil },
            set: { if !$0 { routeToDelete = nil } }
        ), titleVisibility: .visible, presenting: routeToDelete) { route in
            Button("删除路线", role: .destructive) { Task { await delete(route) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这条路线及其所有日期的定位点将从手机中删除。")
        }
        .alert("暂时无法删除路线", isPresented: $deleteFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请检查设备的可用存储空间后重试。")
        }
    }

    private func delete(_ route: RecordedRoute) async {
        do {
            try await recorder.delete(route)
        } catch {
            deleteFailed = true
        }
    }
}

private extension RouteReviewDay {
    var summary: String {
        let counts = Dictionary(grouping: entries, by: \.kind).mapValues(\.count)
        var parts: [String] = []
        if let trips = counts[.trip] { parts.append("\(trips) 趟行程") }
        if let visits = counts[.visit] { parts.append("\(visits) 次停留") }
        if parts.isEmpty { parts.append("\(entries.count) 段记录") }
        return parts.joined(separator: " · ")
    }
}
