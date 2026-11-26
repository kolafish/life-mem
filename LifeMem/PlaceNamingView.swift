import MapKit
import SwiftUI

struct PlaceNamingTarget: Identifiable {
    let id = UUID()
    let title: String
    let coordinate: CLLocationCoordinate2D
}

struct PlaceNamingView: View {
    let target: PlaceNamingTarget

    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var lookupID: UUID?
    @State private var suggestions: [String]?
    @State private var saveFailed = false

    init(target: PlaceNamingTarget, initialName: String?) {
        self.target = target
        _name = State(initialValue: initialName ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("地名") {
                    TextField("例如市图书馆", text: $name)
                        .accessibilityLabel("地点名称")
                    if placeNames.name(for: target.coordinate) != nil {
                        Button("移除地名", role: .destructive) { save(nil) }
                    }
                }
                Section {
                    Button("查找地名") {
                        suggestions = nil
                        lookupID = UUID()
                    }
                    .disabled(lookupID != nil && suggestions == nil)
                    .frame(minHeight: 44, alignment: .leading)
                    if lookupID != nil, suggestions == nil {
                        ProgressView("正在查找地名")
                    }
                } footer: {
                    Text("查找时会把这个地点的坐标交给系统地图服务。附近的行程和停留会复用你保存的名字。")
                }
                if let suggestions {
                    Section("地图候选") {
                        if suggestions.isEmpty {
                            Text("暂时没有找到地名。可以手动输入，或稍后再查。")
                                .foregroundStyle(.secondary)
                        } else {
                            lookupMap
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button {
                                    name = suggestion
                                } label: {
                                    HStack {
                                        Text(suggestion)
                                            .foregroundStyle(.primary)
                                        Spacer(minLength: 8)
                                        if name == suggestion {
                                            Image(systemName: "checkmark")
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityAddTraits(name == suggestion ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(name) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("暂时无法保存地名", isPresented: $saveFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请检查设备的可用存储空间后重试。")
            }
            .task(id: lookupID) {
                guard lookupID != nil else { return }
                let results = await PlaceLookup.suggestions(near: target.coordinate)
                guard !Task.isCancelled else { return }
                suggestions = results
            }
        }
    }

    private var lookupMap: some View {
        Map(
            initialPosition: .region(MKCoordinateRegion(center: target.coordinate, latitudinalMeters: 350, longitudinalMeters: 350)),
            interactionModes: []
        ) {
            Marker("所选位置", coordinate: target.coordinate).tint(.indigo)
        }
        .mapStyle(.standard(emphasis: .muted))
        .frame(height: 150)
        .listRowInsets(EdgeInsets())
    }

    private func save(_ name: String?) {
        do {
            try placeNames.save(name, for: target.coordinate)
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

@MainActor
private enum PlaceLookup {
    static func suggestions(near coordinate: CLLocationCoordinate2D) async -> [String] {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: RouteReview.placeRadius)
        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return [] }
        let nearby = response?.mapItems.compactMap { item -> (name: String, distance: CLLocationDistance)? in
            guard let name = item.name else { return nil }
            let position: CLLocation?
            if #available(iOS 26.0, *) {
                position = item.location
            } else {
                position = item.placemark.location
            }
            guard let position else { return nil }
            let distance = position.distance(from: location)
            guard distance <= RouteReview.placeRadius else { return nil }
            return (name, distance)
        }.sorted { $0.distance < $1.distance } ?? []
        let place = try? await geocodedPlace(for: location)
        var seen: Set<String> = []
        var names: [String] = []
        for candidate in (place?.names ?? []) + nearby.map(\.name) {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seen.insert(name).inserted {
                names.append(name)
                if names.count == 5 { break }
            }
        }
        if let address = place?.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            let label = "\(address)附近"
            if seen.insert(label).inserted { names.append(label) }
        }
        return names
    }

    private static func geocodedPlace(for location: CLLocation) async throws -> (names: [String], address: String?) {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try await request.mapItems.first else { return ([], nil) }
            let name = item.pointOfInterestCategory != nil ? item.name : nil
            let address = item.address?.shortAddress ?? item.addressRepresentations?.cityName
            return ([name].compactMap { $0 }, address)
        } else {
            let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first
            let address = placemark?.thoroughfare ?? placemark?.subLocality ?? placemark?.locality
            return (placemark?.areasOfInterest ?? [], address)
        }
    }
}
