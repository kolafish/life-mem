import MapKit
import SwiftData
import SwiftUI

struct RouteHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(filter: #Predicate<RecordedRoute> { $0.pointCount > 0 }, sort: \RecordedRoute.startedAt, order: .reverse)
    private var routes: [RecordedRoute]
    @State private var browseMode: BrowseMode = .routes
    @State private var selectedMode: TravelMode?
    @State private var routeToDelete: RecordedRoute?
    @State private var deleteFailed = false

    private enum BrowseMode: String, CaseIterable {
        case routes = "整条路线"
        case activities = "活动"
        case places = "地点"
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    browsePicker.pickerStyle(.menu)
                } else {
                    browsePicker.pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)

            historyContent
        }
        .navigationTitle("路线")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { categoryMenu }
        }
        .confirmationDialog("删除这条路线？", isPresented: Binding(
            get: { routeToDelete != nil },
            set: { if !$0 { routeToDelete = nil } }
        ), titleVisibility: .visible, presenting: routeToDelete) { route in
            Button("删除路线", role: .destructive) { delete(route) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这条路线和定位点将从手机中删除。")
        }
        .alert("暂时无法删除路线", isPresented: $deleteFailed) { Button("好", role: .cancel) {} }
    }

    private var browsePicker: some View {
        Picker("浏览方式", selection: $browseMode) {
            ForEach(BrowseMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if routes.isEmpty {
            ContentUnavailableView("还没有路线", systemImage: "map", description: Text("开始记录后，即可在这里回看。"))
        } else if browseMode == .routes {
            let filteredRoutes = selectedMode.map { mode in
                routes.filter { $0.matches(travelMode: mode) }
            } ?? routes
            if let selectedMode, filteredRoutes.isEmpty {
                emptyCategory(selectedMode)
            } else {
                routeList(filteredRoutes)
            }
        } else {
            let segments = routes.flatMap(\.activitySegments)
            let filteredSegments = selectedMode.map { mode in segments.filter { $0.mode == mode } } ?? segments
            if let selectedMode, filteredSegments.isEmpty {
                emptyCategory(selectedMode)
            } else if browseMode == .activities {
                activityList(filteredSegments)
            } else {
                RoutePlacesList(places: RoutePlace.group(segments), mode: selectedMode)
            }
        }
    }

    private func emptyCategory(_ mode: TravelMode) -> some View {
        ContentUnavailableView {
            Label("暂无\(mode.recordedTitle)记录", systemImage: mode.symbol)
        } actions: {
            Button("查看全部") { selectedMode = nil }
        }
    }

    private func routeList(_ routes: [RecordedRoute]) -> some View {
        List(routes) { route in
            NavigationLink {
                RouteDetailView(route: route)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(route.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text("\(route.formattedDistance) · \(route.pointCount) 个定位点")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 6)
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

    private func activityList(_ segments: [RouteActivitySegment]) -> some View {
        let groups = Dictionary(grouping: segments.sorted { $0.startedAt > $1.startedAt }, by: \.mode)
        return List {
            ForEach(TravelMode.historyOrder, id: \.self) { mode in
                if let group = groups[mode] {
                    Section {
                        ForEach(group) { segment in
                            ActivitySegmentLink(segment: segment, showsMode: false)
                        }
                    } header: {
                        Label(mode.recordedTitle, systemImage: mode.symbol)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var categoryMenu: some View {
        let categoryTitle = selectedMode?.recordedTitle ?? "全部"
        return Menu {
            Picker("路线分类", selection: $selectedMode) {
                Label("全部", systemImage: "map").tag(nil as TravelMode?)
                ForEach(TravelMode.historyOrder, id: \.self) { mode in
                    Label(mode.recordedTitle, systemImage: mode.symbol).tag(Optional(mode))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selectedMode == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .accessibilityHidden(true)
                Text(selectedMode?.recordedTitle ?? "分类")
                    .accessibilityLabel("路线分类")
                    .accessibilityValue(categoryTitle)
            }
        }
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

private struct RoutePlacesList: View {
    let places: [RoutePlace]
    let mode: TravelMode?
    @State private var selectedPlace: RoutePlace.ID?

    private var visiblePlaces: [RoutePlace] {
        places.compactMap { place -> RoutePlace? in
            var place = place
            if let mode { place.segments.removeAll { $0.mode != mode } }
            return place.segments.isEmpty ? nil : place
        }.sorted {
            ($0.segments.last?.startedAt ?? .distantPast) > ($1.segments.last?.startedAt ?? .distantPast)
        }
    }

    var body: some View {
        let visiblePlaces = visiblePlaces
        ScrollViewReader { proxy in
            List {
                Section {
                    Map(selection: $selectedPlace) {
                        ForEach(visiblePlaces) { place in
                            Marker(place.title, coordinate: place.location.coordinate)
                                .tint(.indigo)
                                .tag(place.id)
                        }
                    }
                    .frame(height: 190)
                    .accessibilityLabel("地点地图")
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("起点相近的片段归在同一地点。")
                }

                ForEach(visiblePlaces) { place in
                    Section {
                        ForEach(place.segments.reversed()) { segment in
                            ActivitySegmentLink(segment: segment, showsMode: true)
                        }
                    } header: {
                        Label(place.title, systemImage: "mappin.circle")
                            .id(place.id)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: selectedPlace) { _, place in
                guard let place else { return }
                proxy.scrollTo(place, anchor: .top)
            }
            .onChange(of: mode) { selectedPlace = nil }
        }
    }
}

private struct ActivitySegmentLink: View {
    let segment: RouteActivitySegment
    let showsMode: Bool

    var body: some View {
        NavigationLink {
            VStack(alignment: .leading, spacing: 14) {
                RouteMap(segments: [segment])
                Text(segment.formattedTime).font(.headline)
            }
            .padding(16)
            .navigationTitle(segment.mode.recordedTitle)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if showsMode {
                    Label(segment.mode.recordedTitle, systemImage: segment.mode.symbol)
                        .font(.headline)
                }
                Text(segment.formattedTime)
                    .font(showsMode ? .subheadline : .body)
                    .foregroundStyle(showsMode ? .secondary : .primary)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }
}

struct RouteDetailView: View {
    let route: RecordedRoute
    @State private var segments: [RouteActivitySegment] = []

    var body: some View {
        let displayedModes = Set(segments.map(\.mode))
        let modes = TravelMode.allCases.filter(displayedModes.contains)
        VStack(alignment: .leading, spacing: 14) {
            RouteMap(segments: segments)
            Text(route.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text("\(route.formattedDistance) · \(route.pointCount) 个定位点")
                .foregroundStyle(.secondary)
                .font(.subheadline.monospacedDigit())
            if !modes.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { legend(for: modes) }
                    VStack(alignment: .leading, spacing: 8) { legend(for: modes) }
                }
            }
        }
        .padding(16)
        .navigationTitle("路线回看")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route.pointCount) { segments = route.activitySegments }
    }

    private func legend(for modes: [TravelMode]) -> some View {
        ForEach(modes, id: \.self) { mode in
            Label(mode.recordedTitle, systemImage: mode.symbol)
                .foregroundStyle(mode.routeColor)
                .font(.subheadline)
        }
    }
}

private struct RouteMap: View {
    let segments: [RouteActivitySegment]
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(segments) { segment in
                if segment.mode == .stationary {
                    Marker(segment.mode.recordedTitle, systemImage: segment.mode.symbol, coordinate: segment.startCoordinate)
                        .tint(segment.mode.routeColor)
                } else if segment.coordinates.count > 1 {
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(segment.mode.routeColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                } else if segment.id != segments.first?.id {
                    Annotation(segment.mode.recordedTitle, coordinate: segment.startCoordinate) {
                        Circle().fill(segment.mode.routeColor).frame(width: 10, height: 10)
                    }
                    .annotationTitles(.hidden)
                }
            }
            if let first = segments.first, first.mode != .stationary {
                Marker("起点", systemImage: "flag.fill", coordinate: first.startCoordinate)
                    .tint(.indigo)
            }
        }
        .accessibilityLabel("路线地图")
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .frame(maxHeight: .infinity)
        .onChange(of: segments.last?.endedAt) { position = .automatic }
    }
}

private extension RouteActivitySegment {
    var formattedTime: String {
        if Calendar.current.isDate(startedAt, equalTo: endedAt, toGranularity: .minute) {
            return startedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return (startedAt..<endedAt).formatted(.interval.year().month().day().hour().minute())
    }
}

private extension RoutePlace {
    var title: String { "地点 \(number)" }
}

private extension TravelMode {
    var routeColor: Color {
        switch self {
        case .walking: .indigo
        case .automotive: .orange
        case .cycling: .teal
        case .stationary, .unknown: .gray
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
