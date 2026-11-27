import MapKit
import SwiftData
import SwiftUI

struct RouteHistoryView: View {
    @Environment(\.calendar) private var calendar
    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @Query(filter: #Predicate<RecordedRoute> { $0.pointCount > 0 }, sort: \RecordedRoute.startedAt, order: .reverse)
    private var routes: [RecordedRoute]

    @State private var mode = BrowseMode.timeline
    @State private var review: RouteReview?
    @State private var showsArchive = false
    @State private var confirmsAutomaticLookup = false
    @State private var confirmsCacheRemoval = false
    @State private var cacheRemovalFailed = false

    private enum BrowseMode: String, CaseIterable {
        case timeline = "时间线"
        case places = "地点"
    }

    private struct Revision: Hashable {
        let calendar: Calendar
        let routes: [RouteVersion]

        struct RouteVersion: Hashable {
            let id: UUID
            let pointCount: Int
        }
    }

    var body: some View {
        let routes = routes
        VStack(spacing: 0) {
            if !routes.isEmpty {
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
                    if !routes.isEmpty {
                        Button("管理记录", systemImage: "tray.full") { showsArchive = true }
                    }
                    if placeResolver.isAutomaticEnabled {
                        Button("关闭自动地名", systemImage: "mappin.slash") {
                            placeResolver.setAutomaticEnabled(false)
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
            Button("开启") { placeResolver.setAutomaticEnabled(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("打开回顾时，系统地图会使用未命名停留的中心坐标查找附近地名。可以随时在回顾选项里关闭。")
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
            NavigationStack { RouteArchiveView() }
        }
        .task(id: Revision(calendar: calendar, routes: routes.map { .init(id: $0.id, pointCount: $0.pointCount) })) {
            review = RouteReview(routes: routes, calendar: calendar)
        }
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
            List(review.places) { place in
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

    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @State private var namingTarget: PlaceNamingTarget?

    var body: some View {
        let name = placeResolver.label(near: place.coordinate, names: placeNames)
        let daysByDate = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        List {
            Section {
                Map(
                    initialPosition: .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 500, longitudinalMeters: 500)),
                    interactionModes: [.pan, .zoom]
                ) {
                    Marker(name ?? "停留地点", coordinate: place.coordinate).tint(.indigo)
                }
                .mapStyle(.standard(emphasis: .muted))
                .frame(height: 220)
                .accessibilityLabel("停留地点地图")
                .listRowInsets(EdgeInsets())
                Button(placeNames.name(for: place.coordinate) == nil ? "给地点命名" : "编辑地名") {
                    namingTarget = PlaceNamingTarget(title: "停留地点", coordinate: place.coordinate)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            Section("到访记录") {
                ForEach(place.visits.reversed()) { visit in
                    if let day = daysByDate[visit.date] {
                        NavigationLink {
                            RouteDayReviewView(day: day, focus: visit.id)
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
        .task(id: placeResolver.isAutomaticEnabled && namingTarget == nil) {
            guard placeResolver.isAutomaticEnabled, namingTarget == nil else { return }
            await placeResolver.resolveAutomatically(near: place.coordinate, names: placeNames)
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

private struct RouteDayReviewView: View {
    let day: RouteReviewDay
    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @State private var selectedID: RouteReviewEntry.ID?
    @State private var namingTarget: PlaceNamingTarget?

    init(day: RouteReviewDay, focus: RouteReviewEntry.ID? = nil) {
        self.day = day
        _selectedID = State(initialValue: focus)
    }

    var body: some View {
        let selected = day.entries.first { $0.id == selectedID }
        ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selected.map { title(for: $0) } ?? "当天轨迹")
                                .font(.subheadline.weight(.semibold))
                            if let selected {
                                Text(clockRange(selected.startedAt, selected.endedAt))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        ReviewMap(entries: selected.map { [$0] } ?? day.entries, focused: selected != nil)
                            .frame(height: 220)
                    }
                    .listRowInsets(EdgeInsets())
                    .id("review-map")
                } footer: {
                    if let selected {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { mapActions(for: selected) }
                                .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 0) { mapActions(for: selected) }
                        }
                    }
                }

                Section("时间线") {
                    ForEach(day.entries) { entry in
                        if entry.followsGap {
                            Label("记录中断", systemImage: "ellipsis")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            selectedID = entry.id
                            proxy.scrollTo("review-map", anchor: .top)
                        } label: {
                            entryRow(entry, selected: selectedID == entry.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
                        if selectedID == entry.id, entry.kind != .visit, entry.segments.count > 1 {
                            DisclosureGroup("活动片段") {
                                ForEach(entry.segments) { segment in
                                    ReviewTextRow(
                                        title: segment.mode.recordedTitle,
                                        detail: clockRange(segment.startedAt, segment.endedAt)
                                    )
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(day.date.formatted(.dateTime.month().day().weekday(.abbreviated)))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: placeResolver.isAutomaticEnabled && namingTarget == nil) {
            guard placeResolver.isAutomaticEnabled, namingTarget == nil else { return }
            for coordinate in day.entries.compactMap(\.visitCoordinate) {
                guard !Task.isCancelled else { return }
                await placeResolver.resolveAutomatically(near: coordinate, names: placeNames)
            }
        }
        .sheet(item: $namingTarget) { target in
            PlaceNamingView(
                target: target,
                initialName: placeNames.name(for: target.coordinate),
                category: placeNames.category(for: target.coordinate)
            )
        }
    }

    @ViewBuilder
    private func mapActions(for entry: RouteReviewEntry) -> some View {
        Button("查看当天全部") { selectedID = nil }
            .frame(minHeight: 44)
        if let endpoints = entry.endpoints {
            Menu {
                Button("起点地名") { namePlace("起点地名", at: endpoints.start) }
                Button("终点地名") { namePlace("终点地名", at: endpoints.end) }
            } label: {
                Label("地名", systemImage: "tag")
                    .frame(minHeight: 44)
            }
        } else if let coordinate = entry.visitCoordinate {
            Button("编辑地名") { namePlace("停留地点", at: coordinate) }
                .frame(minHeight: 44)
        }
    }

    private func namePlace(_ title: String, at coordinate: CLLocationCoordinate2D) {
        namingTarget = PlaceNamingTarget(title: title, coordinate: coordinate)
    }

    private func title(for entry: RouteReviewEntry) -> String {
        if let endpoints = entry.endpoints {
            let start = placeResolver.label(near: endpoints.start, names: placeNames)
            let end = placeResolver.label(near: endpoints.end, names: placeNames)
            if start != nil || end != nil {
                return "\(start ?? "起点") → \(end ?? "终点")"
            }
        }
        if let coordinate = entry.visitCoordinate, let name = placeResolver.label(near: coordinate, names: placeNames) {
            return name
        }
        return entry.title
    }

    private func entryRow(_ entry: RouteReviewEntry, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: entry.symbol)
                .foregroundStyle(entry.kind == .visit ? Color.teal : .indigo)
                .frame(width: 24)
                .accessibilityHidden(true)
            ReviewTextRow(title: title(for: entry), detail: entry.subtitle, time: clockRange(entry.startedAt, entry.endedAt))
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark.circle.fill" : "scope")
                .foregroundStyle(selected ? Color.indigo : .secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
                            Menu {
                                Picker("日期", selection: Binding(get: { day.date }, set: { selectedDate = $0 })) {
                                    ForEach(days) { item in
                                        Text(item.date, format: .dateTime.year().month().day()).tag(item.date)
                                    }
                                }
                            } label: {
                                Label("切换日期", systemImage: "calendar")
                            }
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
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<RecordedRoute> { $0.pointCount > 0 }, sort: \RecordedRoute.startedAt, order: .reverse)
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
                            detail: route.isFinished ? route.formattedDistance : "未结束 · \(route.formattedDistance)"
                        )
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        if route.isFinished {
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
            Button("删除路线", role: .destructive) { delete(route) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这条路线及其所有日期的定位点将从手机中删除。")
        }
        .alert("暂时无法删除路线", isPresented: $deleteFailed) { Button("好", role: .cancel) {} }
    }

    private func delete(_ route: RecordedRoute) {
        guard route.isFinished else { return }
        context.delete(route)
        do {
            try context.save()
        } catch {
            context.rollback()
            deleteFailed = true
        }
    }
}

private struct ReviewMap: View {
    let entries: [RouteReviewEntry]
    let focused: Bool
    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @State private var position: MapCameraPosition = .automatic

    private struct Viewport: Equatable {
        let focused: Bool
        let entries: [Entry]

        struct Entry: Equatable {
            let id: RouteReviewEntry.ID
            let endedAt: Date
        }
    }

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(entries) { entry in
                if let coordinate = entry.visitCoordinate {
                    Marker(
                        placeResolver.label(near: coordinate, names: placeNames) ?? "停留",
                        systemImage: placeNames.category(for: coordinate)?.symbol ?? "mappin",
                        coordinate: coordinate
                    )
                        .tint(.teal)
                } else {
                    ForEach(entry.segments) { segment in
                        if segment.coordinates.count > 1 {
                            MapPolyline(coordinates: segment.coordinates)
                                .stroke(.indigo, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        } else if segment.mode != .stationary || entry.kind == .fragment {
                            Annotation("定位点", coordinate: segment.startCoordinate) {
                                Circle().fill(.indigo).frame(width: 8, height: 8)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    if focused, entry.kind == .trip {
                        tripMarkers(entry)
                    }
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted))
        .accessibilityLabel(focused ? "所选记录地图" : "当天轨迹地图")
        .onChange(of: Viewport(focused: focused, entries: entries.map { .init(id: $0.id, endedAt: $0.endedAt) })) {
            position = .automatic
        }
    }

    @MapContentBuilder
    private func tripMarkers(_ entry: RouteReviewEntry) -> some MapContent {
        let segments = entry.segments.filter { $0.mode != .stationary }
        if let start = segments.first?.startCoordinate, let end = segments.last?.coordinates.last {
            let startName = entry.endpoints.flatMap { placeResolver.label(near: $0.start, names: placeNames) }
            let endName = entry.endpoints.flatMap { placeResolver.label(near: $0.end, names: placeNames) }
            if MKMapPoint(start).distance(to: MKMapPoint(end)) < 15 {
                Marker(startName ?? endName ?? "起点和终点", systemImage: "flag.checkered", coordinate: start).tint(.indigo)
            } else {
                Marker(startName ?? "起点", systemImage: "flag", coordinate: start).tint(.indigo)
                Marker(endName ?? "终点", systemImage: "flag.checkered", coordinate: end).tint(.indigo)
            }
        }
        if let line = segments.max(by: { $0.coordinates.count < $1.coordinates.count })?.coordinates, line.count > 1 {
            let index = (line.count - 1) / 2
            let start = line[index]
            let end = line[index + 1]
            let latitude = (start.latitude + end.latitude) / 2
            let longitudeDelta = (end.longitude - start.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            let longitude = (start.longitude + longitudeDelta / 2 + 540).truncatingRemainder(dividingBy: 360) - 180
            let direction = atan2(longitudeDelta * cos(latitude * .pi / 180), end.latitude - start.latitude)
            Annotation("行进方向", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.radians(direction))
                    .foregroundStyle(.white)
                    .frame(width: 23, height: 23)
                    .background(.indigo, in: Circle())
            }
            .annotationTitles(.hidden)
        }
    }
}

private struct ReviewTextRow: View {
    let title: String
    let detail: String?
    var time: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let time {
                Text(time).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(title).font(.body.weight(.medium))
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private func clockRange(_ start: Date, _ end: Date) -> String {
    if Calendar.current.isDate(start, equalTo: end, toGranularity: .minute) {
        return start.formatted(.dateTime.hour().minute())
    }
    return (start..<end).formatted(.interval.hour().minute())
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

private extension RouteReviewEntry {
    var modes: [TravelMode] {
        [.walking, .cycling, .automotive].filter { mode in segments.contains { $0.mode == mode } }
    }

    var title: String {
        switch kind {
        case .trip: "行程"
        case .visit: "停留"
        case .fragment: "记录片段"
        }
    }

    var symbol: String {
        switch kind {
        case .trip: modes.count == 1 ? modes[0].symbol : "point.topleft.down.to.point.bottomright.curvepath"
        case .visit: "mappin.circle.fill"
        case .fragment: "location.circle"
        }
    }

    var subtitle: String? {
        switch kind {
        case .trip:
            return modes.isEmpty ? "活动未分类" : modes.map(\.recordedTitle).joined(separator: "、")
        case .visit:
            let duration = endedAt.timeIntervalSince(startedAt)
            guard duration >= 60 else { return nil }
            return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        case .fragment:
            return nil
        }
    }
}

extension RecordedRoute {
    var formattedDistance: String {
        if distanceMeters < 1_000 {
            return "\(distanceMeters.formatted(.number.precision(.fractionLength(0)))) 米"
        }
        return "\((distanceMeters / 1_000).formatted(.number.precision(.fractionLength(2)))) 公里"
    }
}
