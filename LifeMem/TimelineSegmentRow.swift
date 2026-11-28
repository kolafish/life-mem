import CoreLocation
import SwiftUI

struct TimelineSegmentRow: View {
    @Environment(\.modelContext) private var context
    @State private var editVisit = false
    @State private var saveError = false
    @State private var draftName = ""
    let entry: RouteReviewEntry
    let selected: Bool
    var showMemoryActions = false
    let select: () -> Void
    let nameTarget: (PlaceNamingTarget) -> Void

    @Environment(RoutePlaceNames.self) private var placeNames
    @Environment(PlaceResolver.self) private var placeResolver

    var body: some View {
        let category = entry.stay.flatMap { $0.visitName == nil ? placeNames.category(for: $0.coordinate) : nil }
        let moves = entry.moves
        let color = category?.mapColor ?? (entry.kind == .visit ? .teal : moves.first?.mode.mapColor ?? .secondary)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                select()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: category?.symbol ?? entry.symbol)
                        .foregroundStyle(color)
                        .frame(width: 29)
                        .accessibilityHidden(true)
                    ReviewTextRow(
                        title: title(for: entry),
                        detail: entry.stay.map { $0.isCandidate == true ? "由相邻行程端点推测" : routeDuration($0.duration) } ?? moveDetail(moves),
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
            if let key = entry.memoryKey {
                EntryMemoryView(key: key, title: title(for: entry), time: clockRange(entry.startedAt, entry.endedAt), selected: selected || showMemoryActions)
            }
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
                if let stay = entry.stay {
                    VisitMemoryLink(stay: stay)
                    HStack {
                        if stay.isCandidate == true {
                            Button("确认到访") { save(stay, name: nil) }
                            Button("忽略") { save(stay, name: nil, ignore: true) }
                        }
                        Button("只改这次地点") {
                            draftName = stay.visitName ?? ""
                            editVisit = true
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if entry.stay?.isCandidate != true { namingAction(for: entry) }
            }
        }
        .alert("只改这次地点", isPresented: $editVisit) {
            TextField("地点名称", text: $draftName)
            Button("保存") { if let stay = entry.stay { save(stay, name: draftName) } }
            Button("取消", role: .cancel) {}
        } message: { Text("留空会使用附近地点的默认名称。") }
        .alert("未能保存到访", isPresented: $saveError) {
            Button("好", role: .cancel) {}
        } message: { Text("请重新打开当天的记录，检查可用空间后再试。") }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.indigo.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 14))
    }

    private func save(_ stay: StayEvent, name: String?, ignore: Bool = false) {
        do { try VisitCorrection.save(stay, name: name, ignore: ignore, in: context) }
        catch { saveError = true }
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
        nameTarget(PlaceNamingTarget(title: title, coordinate: coordinate))
    }

    private func title(for entry: RouteReviewEntry) -> String {
        if let coordinate = entry.visitCoordinate {
            let name = entry.stay?.visitName ?? placeResolver.label(near: coordinate, names: placeNames)
            if entry.stay?.isCandidate == true { return name.map { "可能在\($0)附近停留" } ?? "可能的停留 · 待确认" }
            return name ?? "停留地点"
        }
        if let endpoints = entry.endpoints {
            let start = endpoints.startName ?? placeResolver.label(near: endpoints.start, names: placeNames)
            let end = endpoints.endName ?? placeResolver.label(near: endpoints.end, names: placeNames)
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
        let modes = Set(moves.map(\.mode))
        if modes.count == 1 {
            guard seconds.isFinite, seconds > 0 else { return distance }
            let speed = (meters / seconds * 3.6).formatted(.number.precision(.fractionLength(1)))
            return "\(distance) · \(duration) · \(speed) 公里/小时"
        }
        let modeNames = TravelMode.allCases.filter { modes.contains($0) }.map(\.recordedTitle).joined(separator: "、")
        return "\(modeNames) · \(distance) · \(duration)"
    }
}

private extension RouteReviewEntry {
    private var modes: [TravelMode] {
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
