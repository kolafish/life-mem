import SwiftUI
import UIKit

struct RecordView: View {
    let recorder: RouteRecorder
    @Environment(\.openURL) private var openURL

    private var status: String {
        switch recorder.state {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 42))
                        .foregroundStyle(.indigo)
                        .accessibilityHidden(true)
                    Text(status)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let route = recorder.activeRoute {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { metrics(for: route) }
                            VStack(alignment: .leading, spacing: 12) { metrics(for: route) }
                        }
                        .padding(.top, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))

                VStack(spacing: 10) {
                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: primarySymbol)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(recorder.state == .requestingPermission)

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
                    }
                }

                if recorder.needsPreciseLocation && recorder.state == .recording {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("开启精确位置后才能绘制详细路线。")
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
        .navigationTitle("记录")
    }

    private var statusDetail: String {
        switch recorder.state {
        case .idle: "开始后可以锁屏。路线保存在这台 iPhone 上。"
        case .requestingPermission: "允许使用期间访问位置后，记录会自动开始。"
        case .recording:
            if recorder.locationUnavailable { "正在等待可用的定位信号。" }
            else if recorder.activeRoute?.pointCount == 0 { "正在寻找第一个定位点。" }
            else { "当前活动 · \(recorder.mode.title)" }
        case .paused: "已采集的定位点已保存。继续后会从新的位置开始一段路线。"
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

    @ViewBuilder
    private func metrics(for route: RecordedRoute) -> some View {
        metric(label: "已记录距离", value: route.formattedDistance)
        metric(label: "采集点", value: route.pointCount.formatted())
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
