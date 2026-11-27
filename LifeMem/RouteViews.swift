import MapKit
import SwiftData
import SwiftUI

struct RouteHistoryView: View {
    let review: RouteReview?
    let hasRoutes: Bool

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
                    if hasRoutes {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedID: RouteReviewEntry.ID?
    @State private var focusRequest = UUID()
    @State private var namingTarget: PlaceNamingTarget?
    private let initialFocus: RouteReviewEntry.ID?

    init(day: RouteReviewDay, focus: RouteReviewEntry.ID? = nil) {
        self.day = day
        initialFocus = focus
        _selectedID = State(initialValue: focus)
    }

    var body: some View {
        let selected = day.entries.first { $0.id == selectedID }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    DailyReviewSummary(day: day)
                    Section {
                        ForEach(day.entries) { entry in
                            if entry.followsGap {
                                Label("记录中断", systemImage: "ellipsis")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 12)
                            }
                            timelineCard(entry)
                                .id(entry.id)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("时间线").font(.headline).accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 8)
                                if selected != nil {
                                    Button("显示全天") { selectedID = nil }
                                        .font(.subheadline)
                                        .frame(minHeight: 44)
                                }
                            }
                            .frame(minHeight: 44)
                            ReviewMap(entries: day.entries, selected: selected, focusRequest: focusRequest) { id in
                                focus(on: id)
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

    private func timelineCard(_ entry: RouteReviewEntry) -> some View {
        let selected = selectedID == entry.id
        let category = entry.visitCoordinate.flatMap { placeNames.category(for: $0) }
        let moves = entry.moves
        let color = category?.mapColor ?? (entry.kind == .visit ? .teal : moves.first?.mode.mapColor ?? .secondary)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                focus(on: entry.id)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: category?.symbol ?? entry.symbol)
                        .foregroundStyle(color)
                        .frame(width: 29)
                        .accessibilityHidden(true)
                    ReviewTextRow(
                        title: title(for: entry),
                        detail: entry.stay.map { routeDuration($0.duration) } ?? moveDetail(moves),
                        time: clockRange(entry.startedAt, entry.endedAt)
                    )
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.indigo)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-entry")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if selected {
                if moves.count > 1 {
                    DisclosureGroup("移动片段") {
                        ForEach(moves) { move in
                            ReviewTextRow(
                                title: move.mode.recordedTitle,
                                detail: moveDetail([move]),
                                time: clockRange(move.startedAt, move.endedAt)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.subheadline)
                    .padding(.vertical, 6)
                }
                namingAction(for: entry)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.indigo.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func namingAction(for entry: RouteReviewEntry) -> some View {
        if let endpoints = entry.endpoints {
            Menu {
                Button("起点地名") { namePlace("起点地名", at: endpoints.start) }
                Button("终点地名") { namePlace("终点地名", at: endpoints.end) }
            } label: {
                Label("地名", systemImage: "tag").frame(minHeight: 44)
            }
        } else if let coordinate = entry.visitCoordinate {
            Button {
                namePlace("停留地点", at: coordinate)
            } label: {
                Label("编辑地名", systemImage: "tag").frame(minHeight: 44)
            }
        }
    }

    private func namePlace(_ title: String, at coordinate: CLLocationCoordinate2D) {
        namingTarget = PlaceNamingTarget(title: title, coordinate: coordinate)
    }

    private func focus(on id: RouteReviewEntry.ID) {
        selectedID = id
        focusRequest = UUID()
    }

    private func title(for entry: RouteReviewEntry) -> String {
        if let coordinate = entry.visitCoordinate {
            return placeResolver.label(near: coordinate, names: placeNames) ?? "停留地点"
        }
        if let endpoints = entry.endpoints {
            let start = placeResolver.label(near: endpoints.start, names: placeNames)
            let end = placeResolver.label(near: endpoints.end, names: placeNames)
            if start != nil || end != nil { return "\(start ?? "起点") → \(end ?? "终点")" }
        }
        if let mode = entry.moves.first?.mode, entry.moves.allSatisfy({ $0.mode == mode }) {
            return mode.recordedTitle
        }
        return entry.title
    }

    private func moveDetail(_ moves: [MoveEvent]) -> String? {
        guard !moves.isEmpty else { return nil }
        let meters = moves.reduce(0) { $0 + $1.distanceMeters }
        let seconds = moves.reduce(0) { $0 + $1.duration }
        let distance = routeDistance(meters)
        let duration = routeDuration(seconds)
        let speed = (meters / seconds * 3.6).formatted(.number.precision(.fractionLength(1)))
        let modes = Set(moves.map(\.mode))
        if modes.count == 1 { return "\(distance) · \(duration) · \(speed) 公里/小时" }
        let modeNames = TravelMode.allCases.filter { modes.contains($0) }.map(\.recordedTitle).joined(separator: "、")
        return "\(modeNames) · \(distance) · \(duration)"
    }
}

private struct DailyReviewSummary: View {
    let day: RouteReviewDay

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(RoutePlaceNames.self) private var placeNames

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当日概览").font(.headline).accessibilityAddTraits(.isHeader)
                .padding(.vertical, 4)
            if let start = day.entries.first?.startedAt, let end = day.entries.map(\.endedAt).max() {
                metric("记录跨度", clockRange(start, end), symbol: "clock")
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { movementMetrics }
            } else {
                HStack(spacing: 8) { movementMetrics }
            }
            stayDistribution
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var movementMetrics: some View {
        metric("移动里程", routeDistance(day.movingDistanceMeters), symbol: "point.topleft.down.to.point.bottomright.curvepath")
        metric("移动耗时", routeDuration(day.movingDuration), symbol: "timer")
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var stayDistribution: some View {
        let durations = day.stays.reduce(into: [PlaceCategory: TimeInterval]()) { result, stay in
            result[placeNames.category(for: stay.coordinate) ?? .other, default: 0] += stay.duration
        }
        let categories = PlaceCategory.allCases.filter { (durations[$0] ?? 0) > 0 }
        let total = durations.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            Text("停留分布").font(.subheadline).foregroundStyle(.secondary)
            if categories.isEmpty {
                Text("当天没有观测到持续停留").font(.footnote).foregroundStyle(.secondary)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(categories) { category in
                            Rectangle()
                                .fill(category.mapColor)
                                .frame(width: geometry.size.width * (durations[category, default: 0] / total))
                        }
                    }
                }
                .frame(height: 7)
                .clipShape(.capsule)
                .accessibilityHidden(true)
                ForEach(categories) { category in
                    HStack(alignment: .firstTextBaseline) {
                        Label(category == .other ? "其他停留" : category.title, systemImage: category.symbol)
                            .foregroundStyle(category == .other ? Color.secondary : Color.primary)
                        Spacer(minLength: 8)
                        Text(routeDuration(durations[category, default: 0])).monospacedDigit()
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
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
    let selected: RouteReviewEntry?
    let focusRequest: UUID
    let selectStay: (RouteReviewEntry.ID) -> Void

    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @State private var position: MapCameraPosition = .automatic

    private struct Viewport: Equatable {
        let selection: RouteReviewEntry.ID?
        let endedAt: Date?
        let request: UUID
    }

    private struct StayMarkers: Identifiable {
        var stays: [StayEvent]
        var id: StayEvent.ID { stays[0].id }
        var coordinate: CLLocationCoordinate2D { stays[0].coordinate }
    }

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(stayMarkers) { group in
                Annotation("停留", coordinate: group.coordinate) {
                    stayMarker(group)
                }
                .annotationTitles(.hidden)
            }
            ForEach(entries.filter { $0.stay == nil }) { entry in
                ForEach(entry.segments) { segment in
                    if segment.mode != .stationary, segment.coordinates.count > 1 {
                        let focused = selected == nil || selected?.id == entry.id
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(segment.mode.mapColor.opacity(focused ? 1 : 0.4), style: StrokeStyle(
                                lineWidth: focused ? 4 : 3, lineCap: .round, lineJoin: .round,
                                dash: segment.mode == .walking ? [5, 6] : []
                            ))
                    } else if segment.mode != .stationary || entry.kind == .fragment {
                        Annotation("定位点", coordinate: segment.startCoordinate) {
                            Circle().fill(segment.mode.mapColor).frame(width: 8, height: 8)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                if selected?.id == entry.id, entry.kind == .trip {
                    tripMarkers(entry)
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted))
        .accessibilityIdentifier("daily-route-map")
        .onChange(of: Viewport(selection: selected?.id, endedAt: selected?.endedAt, request: focusRequest), initial: true) {
            position = selected.map(camera(for:)) ?? .automatic
        }
    }

    private var stayMarkers: [StayMarkers] {
        entries.compactMap(\.stay).reduce(into: []) { groups, stay in
            let location = MKMapPoint(stay.coordinate)
            if let index = groups.firstIndex(where: { MKMapPoint($0.coordinate).distance(to: location) < 25 }) {
                groups[index].stays.append(stay)
            } else {
                groups.append(StayMarkers(stays: [stay]))
            }
        }
    }

    private func stayMarker(_ group: StayMarkers) -> some View {
        let category = placeNames.category(for: group.coordinate)
        let name = placeResolver.label(near: group.coordinate, names: placeNames) ?? "停留地点"
        let isSelected = group.stays.contains { $0.id == selected?.id }
        let detail = group.stays.count == 1 ? routeDuration(group.stays[0].duration) : "\(group.stays.count) 次停留"
        return Group {
            if group.stays.count == 1 {
                Button { selectStay(group.id) } label: { markerLabel(detail, category: category, selected: isSelected) }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(group.stays) { stay in
                        Button(clockRange(stay.startedAt, stay.endedAt)) { selectStay(stay.id) }
                    }
                } label: {
                    markerLabel(detail, category: category, selected: isSelected)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel("\(name)，\(detail)")
        .accessibilityIdentifier("stay-marker")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func markerLabel(_ title: String, category: PlaceCategory?, selected: Bool) -> some View {
        Label(title, systemImage: category?.symbol ?? "mappin")
            .font(.caption.weight(.semibold).monospacedDigit())
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Color.indigo : category?.mapColor ?? .teal, in: .capsule)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private func camera(for entry: RouteReviewEntry) -> MapCameraPosition {
        if let coordinate = entry.visitCoordinate {
            return .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 420, longitudinalMeters: 420))
        }
        let coordinates = entry.segments.flatMap(\.coordinates)
        guard let first = coordinates.first else { return .automatic }
        var south = first.latitude
        var north = first.latitude
        var west = 0.0
        var east = 0.0
        for point in coordinates.dropFirst() {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            let offset = (point.longitude - first.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            west = min(west, offset)
            east = max(east, offset)
        }
        let longitude = (first.longitude + (west + east) / 2 + 540).truncatingRemainder(dividingBy: 360) - 180
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (north + south) / 2, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: min(180, max(0.004, (north - south) * 1.55)),
                                   longitudeDelta: min(360, max(0.004, (east - west) * 1.55)))
        ))
    }

    @MapContentBuilder
    private func tripMarkers(_ entry: RouteReviewEntry) -> some MapContent {
        let segments = entry.segments.filter { $0.mode != .stationary }
        if let start = segments.first?.coordinates.first, let end = segments.last?.coordinates.last {
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

}

extension PlaceCategory {
    var mapColor: Color {
        switch self {
        case .home: .teal
        case .work: .indigo
        case .dining: .orange
        case .shopping: .pink
        case .exercise: .green
        case .leisure: .blue
        case .other: .gray
        }
    }
}

private extension TravelMode {
    var mapColor: Color {
        switch self {
        case .walking: .green
        case .cycling: .orange
        case .automotive: .blue
        case .stationary: .teal
        case .unknown: .gray
        }
    }
}

func routeDuration(_ seconds: TimeInterval) -> String {
    if seconds == 0 { return "0 分钟" }
    if seconds < 60 { return "\(Int(seconds.rounded())) 秒" }
    return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

private func routeDistance(_ meters: Double) -> String {
    if meters < 1_000 {
        return "\(meters.formatted(.number.precision(.fractionLength(0)))) 米"
    }
    return "\((meters / 1_000).formatted(.number.precision(.fractionLength(2)))) 公里"
}

extension RecordedRoute {
    var formattedDistance: String { routeDistance(distanceMeters) }
}
