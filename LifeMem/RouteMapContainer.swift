import MapKit
import SwiftUI

struct RouteMapContainer: View {
    let entries: [RouteReviewEntry]
    let selected: RouteReviewEntry?
    let focusRequest: UUID
    var photo: CLLocationCoordinate2D? = nil
    var groupCoordinate: CLLocationCoordinate2D? = nil
    var openMap: ((CLLocationCoordinate2D?) -> Void)? = nil
    let selectEntry: (RouteReviewEntry.ID) -> Void

    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver
    @State private var position: MapCameraPosition = .automatic

    private struct Viewport: Equatable {
        let selection: RouteReviewEntry.ID?
        let request: UUID
    }

    private struct StayMarkers: Identifiable {
        var stays: [StayEvent]
        var id: StayEvent.ID { stays[0].id }
        var coordinate: CLLocationCoordinate2D { stays[0].coordinate }
    }

    var body: some View {
        if let openMap {
            routeMap
                .accessibilityLabel("当天地图预览")
                .accessibilityHint("轻点两下打开全屏地图")
                .accessibilityAction { openMap(nil) }
        } else {
            routeMap
        }
    }

    private var routeMap: some View {
        let stops = visibleStayMarkers
        return MapReader { proxy in
            Map(position: $position, interactionModes: openMap == nil ? [.pan, .zoom] : []) {
                ForEach(stops) { group in
                    let name = group.stays.first?.visitName ?? placeResolver.label(near: group.coordinate, names: placeNames)
                    let focused = selected == nil || group.stays.contains { $0.id == selected?.id }
                    Annotation(name ?? "停留", coordinate: RouteMapProjection.standard.coordinate(for: group.coordinate)) {
                        stayMarker(group, name: name)
                            .opacity(openMap == nil && !focused ? 0.7 : 1)
                    }
                    .annotationTitles(openMap == nil && focused && name != nil ? .visible : .hidden)
                }
                ForEach(entries.filter { $0.stay == nil }) { entry in
                    ForEach(entry.segments) { segment in
                        let coordinates = segment.coordinates
                        if segment.mode != .stationary, coordinates.count > 1 {
                            let focused = selected == nil || selected?.id == entry.id
                            MapPolyline(coordinates: coordinates.map(RouteMapProjection.standard.coordinate(for:)))
                                .stroke(segment.mode.mapColor.opacity(focused ? 1 : 0.4), style: StrokeStyle(
                                    lineWidth: focused ? 4 : 3, lineCap: .round, lineJoin: .round,
                                    dash: segment.mode == .walking ? [5, 6] : []
                                ))
                        } else if segment.mode != .stationary || entry.kind == .fragment {
                            Annotation("定位点", coordinate: RouteMapProjection.standard.coordinate(for: segment.startCoordinate)) {
                                Circle().fill(segment.mode.mapColor).frame(width: 8, height: 8)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    if photo == nil, selected?.id == entry.id, entry.kind == .trip {
                        tripMarkers(entry)
                    }
                }
                if openMap == nil, selected == nil, stops.isEmpty,
                   let first = entries.first(where: { $0.kind == .trip }),
                   let last = entries.last(where: { $0.kind == .trip }) {
                    tripEndpoints(from: first, to: last)
                }
                if let photo {
                    Annotation("拍摄位置", coordinate: RouteMapProjection.standard.coordinate(for: photo), anchor: .bottom) {
                        VStack(spacing: 0) {
                            Label("拍摄位置", systemImage: "camera.fill")
                                .font(.caption.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .foregroundStyle(.white).background(.purple, in: .capsule)
                            Rectangle().fill(.purple).frame(width: 2, height: 8)
                            Circle().fill(.purple).frame(width: 6, height: 6)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("拍摄位置")
                        .accessibilityIdentifier("photo-map-pin")
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .accessibilityIdentifier(openMap == nil ? "daily-route-map" : "day-map-preview")
            .onChange(of: Viewport(selection: selected?.id, request: focusRequest), initial: true) {
                if let photo {
                    position = .region(MKCoordinateRegion(center: RouteMapProjection.standard.coordinate(for: photo),
                                                          latitudinalMeters: 240, longitudinalMeters: 240))
                } else if let groupCoordinate {
                    position = stayCamera(at: groupCoordinate)
                } else { position = selected.map(camera(for:)) ?? .automatic }
            }
            .onChange(of: selected?.endedAt) {
                if photo == nil, let selected, !position.positionedByUser { position = camera(for: selected) }
            }
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                if let id = trip(at: tap.location, proxy: proxy) { selectEntry(id) }
                else { openMap?(nil) }
            })
        }
    }

    private func trip(at tap: CGPoint, proxy: MapProxy) -> RouteReviewEntry.ID? {
        func screenPoint(_ coordinate: CLLocationCoordinate2D) -> CGPoint? {
            proxy.convert(RouteMapProjection.standard.coordinate(for: coordinate), to: .local)
        }
        // Give the visible stay buttons priority where a trip meets a stop.
        if visibleStayMarkers.contains(where: { marker in
            guard let point = screenPoint(marker.coordinate) else { return false }
            return abs(point.x - tap.x) <= 28 && abs(point.y - tap.y) <= 22
        }) { return nil }

        var best: RouteReviewEntry.ID?
        var distance: CGFloat = 20
        for entry in entries where entry.kind == .trip {
            for segment in entry.segments where segment.mode != .stationary {
                var previous: CGPoint?
                for coordinate in segment.coordinates {
                    let point = screenPoint(coordinate)
                    if let a = previous, let b = point {
                        let dx = b.x - a.x, dy = b.y - a.y
                        let squared = dx * dx + dy * dy
                        let t = squared == 0 ? 0 : min(1, max(0, ((tap.x - a.x) * dx + (tap.y - a.y) * dy) / squared))
                        let offset = hypot(tap.x - a.x - t * dx, tap.y - a.y - t * dy)
                        if offset < distance { distance = offset; best = entry.id }
                    }
                    previous = point
                }
            }
        }
        return best
    }

    private var visibleStayMarkers: [StayMarkers] {
        guard let photo else { return stayMarkers }
        return stayMarkers.filter { MKMapPoint(photo).distance(to: MKMapPoint($0.coordinate)) > 18 }
    }

    private var stayMarkers: [StayMarkers] {
        entries.compactMap(\.stay).filter { $0.isCandidate != true }.reduce(into: []) { groups, stay in
            let location = MKMapPoint(stay.coordinate)
            if let index = groups.firstIndex(where: { $0.stays.first?.visitName == stay.visitName && MKMapPoint($0.coordinate).distance(to: location) < 25 }) {
                groups[index].stays.append(stay)
            } else {
                groups.append(StayMarkers(stays: [stay]))
            }
        }
    }

    private func stayMarker(_ group: StayMarkers, name: String?) -> some View {
        let category = group.stays.first?.visitName == nil ? placeNames.category(for: group.coordinate) : nil
        let isSelected = group.stays.contains { $0.id == selected?.id }
        let detail = group.stays.count == 1 ? routeDuration(group.stays[0].duration) : "\(group.stays.count) 次停留"
        return Group {
            if group.stays.count == 1 || openMap != nil {
                Button {
                    if group.stays.count == 1 { selectEntry(group.id) }
                    else if let id = selected?.id, isSelected { selectEntry(id) }
                    else { openMap?(group.coordinate) }
                } label: {
                    markerLabel(detail, category: category, selected: isSelected)
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(group.stays) { stay in
                        Button(clockRange(stay.startedAt, stay.endedAt)) { selectEntry(stay.id) }
                    }
                } label: {
                    markerLabel(detail, category: category, selected: isSelected)
                }
            }
        }
        .accessibilityLabel("\(name ?? "停留地点")，\(detail)")
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

    private func stayCamera(at coordinate: CLLocationCoordinate2D) -> MapCameraPosition {
        let center = RouteMapProjection.standard.coordinate(for: coordinate)
        return .region(MKCoordinateRegion(center: center, latitudinalMeters: 420, longitudinalMeters: 420))
    }

    private func camera(for entry: RouteReviewEntry) -> MapCameraPosition {
        if let coordinate = entry.visitCoordinate { return stayCamera(at: coordinate) }
        let coordinates = entry.segments.flatMap(\.coordinates)
        guard let firstCoordinate = coordinates.first else { return .automatic }
        let first = RouteMapProjection.standard.coordinate(for: firstCoordinate)
        var south = first.latitude
        var north = first.latitude
        var west = 0.0
        var east = 0.0
        for coordinate in coordinates.dropFirst() {
            let point = RouteMapProjection.standard.coordinate(for: coordinate)
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
    private func tripEndpoints(from departure: RouteReviewEntry, to arrival: RouteReviewEntry) -> some MapContent {
        if let start = departure.segments.first(where: { $0.mode != .stationary })?.firstCoordinate,
           let end = arrival.segments.last(where: { $0.mode != .stationary })?.lastCoordinate {
            let startName = departure.endpoints.flatMap { $0.startName ?? placeResolver.label(near: $0.start, names: placeNames) }
            let endName = arrival.endpoints.flatMap { $0.endName ?? placeResolver.label(near: $0.end, names: placeNames) }
            let mapStart = RouteMapProjection.standard.coordinate(for: start)
            if MKMapPoint(start).distance(to: MKMapPoint(end)) < 15 {
                Marker(startName ?? endName ?? "起点和终点", systemImage: "flag.checkered", coordinate: mapStart).tint(.indigo)
            } else {
                let mapEnd = RouteMapProjection.standard.coordinate(for: end)
                Marker(startName ?? "起点", systemImage: "flag", coordinate: mapStart).tint(.indigo)
                Marker(endName ?? "终点", systemImage: "flag.checkered", coordinate: mapEnd).tint(.indigo)
            }
        }
    }

    @MapContentBuilder
    private func tripMarkers(_ entry: RouteReviewEntry) -> some MapContent {
        tripEndpoints(from: entry, to: entry)
        let segments = entry.segments.filter { $0.mode != .stationary }
        if let line = segments.max(by: { $0.coordinates.count < $1.coordinates.count })?.coordinates, line.count > 1 {
            let index = (line.count - 1) / 2
            let start = RouteMapProjection.standard.coordinate(for: line[index])
            let end = RouteMapProjection.standard.coordinate(for: line[index + 1])
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
