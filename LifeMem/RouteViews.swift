import MapKit
import SwiftData
import SwiftUI

struct RouteHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<RecordedRoute> { $0.pointCount > 0 }, sort: \RecordedRoute.startedAt, order: .reverse)
    private var routes: [RecordedRoute]
    @State private var routeToDelete: RecordedRoute?
    @State private var deleteFailed = false

    var body: some View {
        Group {
            if routes.isEmpty {
                ContentUnavailableView("还没有路线", systemImage: "map", description: Text("记录一段移动后，即可在这里回看。"))
            } else {
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
        }
        .navigationTitle("路线")
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

struct RouteDetailView: View {
    let route: RecordedRoute
    @State private var segments: [RouteSegment] = []
    @State private var firstCoordinate: CLLocationCoordinate2D?
    @State private var modes: [TravelMode] = []
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Map(position: $mapPosition) {
                ForEach(segments) { segment in
                    if segment.coordinates.count > 1 {
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(segment.mode.routeColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    } else if segment.id != 0, let coordinate = segment.coordinates.first {
                        Annotation("定位点", coordinate: coordinate) {
                            Circle().fill(segment.mode.routeColor).frame(width: 10, height: 10)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                if let firstCoordinate {
                    Marker("起点", systemImage: "flag.fill", coordinate: firstCoordinate)
                        .tint(.indigo)
                }
            }
            .accessibilityLabel("路线地图")
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .frame(maxHeight: .infinity)

            Text(route.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text("\(route.formattedDistance) · \(route.pointCount) 个定位点")
                .foregroundStyle(.secondary)
                .font(.subheadline.monospacedDigit())
            if !modes.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { legend }
                    VStack(alignment: .leading, spacing: 8) { legend }
                }
            }
        }
        .padding(16)
        .navigationTitle("路线回看")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route.pointCount) { prepareRoute() }
    }

    @ViewBuilder
    private var legend: some View {
        ForEach(modes, id: \.self) { mode in
            Label(mode == .unknown ? "未分类" : mode.title, systemImage: mode.symbol)
                .foregroundStyle(mode.routeColor)
                .font(.subheadline)
        }
    }

    private func prepareRoute() {
        let points = route.points.sorted { $0.timestamp < $1.timestamp }
        firstCoordinate = points.first?.coordinate
        var grouped: [RouteSegment] = []
        var priorCoordinate: CLLocationCoordinate2D?
        for point in points {
            let coordinate = point.coordinate
            let pointMode = point.mode
            if point.startsNewSegment || grouped.isEmpty {
                grouped.append(RouteSegment(id: grouped.count, mode: pointMode, coordinates: [coordinate]))
            } else if grouped.last?.mode != pointMode {
                grouped.append(RouteSegment(id: grouped.count, mode: pointMode, coordinates: [priorCoordinate ?? coordinate, coordinate]))
            } else {
                grouped[grouped.count - 1].coordinates.append(coordinate)
            }
            priorCoordinate = coordinate
        }
        segments = grouped
        let displayedModes = Set(segments.map(\.mode))
        modes = TravelMode.allCases.filter(displayedModes.contains)
        mapPosition = .automatic
    }
}

private struct RouteSegment: Identifiable {
    let id: Int
    let mode: TravelMode
    var coordinates: [CLLocationCoordinate2D]
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
