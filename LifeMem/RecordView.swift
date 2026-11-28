import SwiftUI
import UIKit

struct RecordView: View {
    let recorder: RouteRecorder
    let day: RouteReviewDay?
    let loading: Bool
    let stays: [TodayPlaceStay]
    @Environment(\.calendar) private var calendar
    @Environment(RoutePlaceNames.self) private var names
    @Environment(PlaceResolver.self) private var resolver
    @Environment(\.openURL) private var openURL
    @State private var expandedStays = Set<Date>()
    @State private var focusedEntry: FocusedEntry?
    @State private var routeToDiscard: RecordedRoute?
    @State private var discardFailed = false

    private var status: String {
        if recorder.automaticEnabled {
            if recorder.automaticNeedsSettings { return "等待定位授权" }
            if recorder.automaticTrips.route?.isFinished == false { return "正在自动记录" }
            return "等待出发"
        }
        return switch recorder.state {
        case .idle: "可以开始记录"
        case .requestingPermission: "等待定位权限"
        case .recording: "正在记录"
        case .paused: "已暂停"
        }
    }

    private var statusSymbol: String {
        switch recorder.state {
        case .idle: "location.circle"
        case .requestingPermission: "location.circle"
        case .recording: "location.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    private struct FocusedEntry: Identifiable {
        let day: RouteReviewDay
        let id: RouteReviewEntry.ID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let day {
                    Text(day.placeSequence { resolver.label(near: $0, names: names) } ?? "今天的行程")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("today-title")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(status, systemImage: statusSymbol).font(.headline)
                    Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    if !recorder.automaticEnabled {
                        Button(action: primaryAction) {
                            Label(primaryTitle, systemImage: primarySymbol)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(recorder.state == .requestingPermission || (recorder.isDeletingRoute && recorder.state != .recording))
                    }

                    if recorder.state == .paused, let route = recorder.activeRoute {
                        if route.pointCount > 0 {
                            NavigationLink {
                                RouteDetailView(route: route)
                            } label: {
                                Label("回看当前路线", systemImage: "map")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        Button("结束这次记录", action: recorder.finish)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(recorder.isDeletingRoute)
                        Button(role: .destructive) { routeToDiscard = route } label: {
                            Text("丢弃这次记录").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(!recorder.canDelete(route))
                    }
                }

                if day != nil || !stays.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(timeline) { row in
                            switch row {
                            case let .entry(entry):
                                if let day { entryButton(entry, in: day) }
                            case let .stay(stay, entries):
                                if let day, !entries.isEmpty {
                                    let expanded = expandedStays.contains(stay.id)
                                    Button {
                                        if expanded { expandedStays.remove(stay.id) }
                                        else { expandedStays.insert(stay.id) }
                                    } label: {
                                        HStack {
                                            stayLabel(stay)
                                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                                .font(.footnote.weight(.semibold))
                                                .accessibilityHidden(true)
                                        }
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityValue(expanded ? "已展开" : "已收起")
                                    .accessibilityIdentifier("today-place-stay")
                                    if expanded {
                                        ForEach(entries) { entry in entryButton(entry, in: day) }
                                            .padding(.leading, 16)
                                    }
                                } else {
                                    stayLabel(stay)
                                }
                            }
                        }
                    }
                } else if loading {
                    ProgressView("正在读取今天的行程")
                } else {
                    Text("今天还没有行程").foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("自动记录（试用）", isOn: Binding(
                        get: { recorder.automaticEnabled }, set: { recorder.setAutomatic($0) }
                    ))
                    .disabled(recorder.state != .idle || recorder.isDeletingRoute)
                    Text(recorder.state == .idle
                         ? "允许「使用 App 期间」定位后，可以锁屏自动记录。"
                         : "结束当前手动记录后可以开启。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if recorder.automaticNeedsSettings || (recorder.needsPreciseLocation && (recorder.state == .recording || recorder.automaticEnabled)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recorder.automaticNeedsSettings ? "请在定位设置中选择「使用 App 期间」。" : "开启精确位置后才能绘制详细路线。")
                            .font(.subheadline)
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .frame(minHeight: 44)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("今天")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { JournalLink(day: day).disabled(loading) }
        }
        .sheet(item: $focusedEntry) { entry in
            NavigationStack {
                RouteDayReviewView(day: entry.day, focus: entry.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { focusedEntry = nil }
                        }
                    }
            }
        }
        .confirmationDialog("丢弃这次记录？", isPresented: Binding(
            get: { routeToDiscard != nil },
            set: { if !$0 { routeToDiscard = nil } }
        ), titleVisibility: .visible, presenting: routeToDiscard) { route in
            Button("丢弃记录", role: .destructive) {
                Task {
                    do { try await recorder.delete(route) }
                    catch { discardFailed = true }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这条记录及其定位点将从手机中删除。")
        }
        .alert("暂时无法丢弃记录", isPresented: $discardFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请检查设备的可用存储空间后重试。")
        }
    }

    private enum Row: Identifiable {
        case entry(RouteReviewEntry)
        case stay(TodayPlaceStay, [RouteReviewEntry])

        var id: AnyHashable {
            switch self {
            case let .entry(entry): AnyHashable(entry.id)
            case let .stay(stay, _): AnyHashable(stay.id)
            }
        }

        var start: Date {
            switch self {
            case let .entry(entry): entry.startedAt
            case let .stay(stay, _): stay.startedAt
            }
        }
    }

    private var timeline: [Row] {
        var entries = day?.entries ?? []
        var rows = [Row]()
        for stay in stays {
            let end = stay.end ?? .distantFuture
            let covered = entries.filter { stay.startedAt <= $0.startedAt && $0.endedAt <= end }
            let ids = Set(covered.map(\.id))
            entries.removeAll { ids.contains($0.id) }
            rows.append(.stay(stay, covered))
        }
        return (rows + entries.map(Row.entry)).sorted { $0.start < $1.start }
    }

    private func stayLabel(_ stay: TodayPlaceStay) -> some View {
        TimelineView(.everyMinute) { tick in
            let end = stay.end ?? tick.date
            let start = min(stay.startedAt, end)
            let time = calendar.isDate(start, inSameDayAs: end)
                ? clockRange(start, end)
                : (start..<end).formatted(.interval.month().day().hour().minute())
            let status = stay.end == nil ? "可能仍在停留" : "可能停留"
            ReviewTextRow(title: stay.name.map { "\($0) · \(status)" } ?? status,
                          detail: nil, time: time)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func entryButton(_ entry: RouteReviewEntry, in day: RouteReviewDay) -> some View {
        Button { focusedEntry = FocusedEntry(day: day, id: entry.id) } label: {
            let name = day.title(for: entry) { resolver.label(near: $0, names: names) }
            ReviewTextRow(title: name, detail: nil, time: clockRange(entry.startedAt, entry.endedAt))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier(entry.stay == nil ? "today-entry" : "today-stop")
        if let stay = entry.stay { VisitMemoryLink(stay: stay) }
    }

    private var statusDetail: String {
        if recorder.automaticEnabled {
            if recorder.automaticNeedsSettings { return "授权后将自动开始监听。" }
            if recorder.locationUnavailable { return "正在等待可用的定位信号。" }
            if recorder.automaticTrips.route?.isFinished == false { return "路线正在保存到这台 iPhone 上。" }
            return "可以锁屏。检测到移动后会保存路线。"
        }
        return switch recorder.state {
        case .idle: "开始后可以锁屏。路线保存在这台 iPhone 上。"
        case .requestingPermission: "允许使用期间访问位置后，记录会自动开始。"
        case .recording:
            if recorder.locationUnavailable { "正在等待可用的定位信号。" }
            else if recorder.activeRoute?.pointCount == 0 { "正在寻找第一个定位点。" }
            else { "当前活动 · \(recorder.mode.title)" }
        case .paused:
            if recorder.recoveredUnfinishedRoute { "这条记录尚未结束。继续后会从新的位置开始一段路线。" }
            else { "已采集的定位点已保存。继续后会从新的位置开始一段路线。" }
        }
    }

    private var primaryTitle: String {
        switch recorder.state {
        case .idle, .requestingPermission: "开始记录"
        case .recording: "暂停记录"
        case .paused: "继续记录"
        }
    }

    private var primarySymbol: String {
        recorder.state == .recording ? "pause.fill" : "play.fill"
    }

    private func primaryAction() {
        if recorder.state == .recording { recorder.pause() } else { recorder.start() }
    }

}
