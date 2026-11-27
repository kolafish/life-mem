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
    @Environment(PlaceResolver.self) private var placeResolver
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: PlaceCategory?
    @State private var lookupID: UUID?
    @State private var suggestions: [String]?
    @State private var saveFailed = false

    init(target: PlaceNamingTarget, initialName: String?, category: PlaceCategory?) {
        self.target = target
        _name = State(initialValue: initialName ?? "")
        _category = State(initialValue: category)
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
                Section("地点分类") {
                    Picker("分类", selection: $category) {
                        Text("未分类").tag(nil as PlaceCategory?)
                        ForEach(PlaceCategory.allCases) { item in
                            Label(item.title, systemImage: item.symbol).tag(Optional(item))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .onChange(of: category) { previous, selected in
                        if let selected, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            name == previous?.defaultName {
                            name = selected.defaultName
                        }
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
                if let suggestions = suggestions ?? placeResolver.cached(near: target.coordinate)?.candidates {
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
                let results = await placeResolver.resolve(near: target.coordinate, automatic: false)?.candidates ?? []
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
            try placeNames.save(name, category: category, for: target.coordinate)
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
