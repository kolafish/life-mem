import MapKit
import SwiftUI

struct RouteMapContainer: View {
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
