import SwiftUI

struct RouteInsightCards: View {
    let insights: RouteInsights
    let title: (RouteBehavior.RoutePattern, Int) -> String

    var body: some View {
        analyticsCard("本期洞察") {
            Text("首次记录到 \(insights.newPlaceCount) 个地点。")
            if let commute = insights.commute {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(commute.pattern, 0)).font(.subheadline.weight(.semibold))
                    Text("平均通勤 \(routeDuration(commute.average))，\(commuteChange(commute))。")
                    Text("本期 \(commute.sampleCount) 次，前一对应时段 \(commute.previousSampleCount) 次")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    let departure = commute.fastestSample.departedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                    Text("本期最快的一次于 \(departure) 出发，耗时 \(routeDuration(commute.fastestSample.duration))。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let home = insights.home {
                VStack(alignment: .leading, spacing: 4) {
                    let share = home.share.formatted(.percent.precision(.fractionLength(0)))
                    Text("居家占已记录时长的 \(share)。")
                    if let previous = home.previousShare {
                        Text(homeChange(current: home.share, previous: previous))
                    }
                    Text("记录覆盖 \(routeDuration(home.trackedDuration)) / \(routeDuration(home.elapsedDuration))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        if !insights.routes.isEmpty {
            analyticsCard("常走路线") {
                ForEach(Array(insights.routes.enumerated()), id: \.element.id) { index, route in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(route.pattern, index)).font(.subheadline.weight(.semibold))
                        Text("本期 \(route.count) 次，平均 \(routeDuration(route.average))")
                        Text("历史最短 \(routeDuration(route.fastest))，最长 \(routeDuration(route.slowest))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func homeChange(current: Double, previous: Double) -> String {
        let difference = Int(((current - previous) * 100).rounded())
        guard difference != 0 else { return "与本期之前 30 天的已记录居家占比相近。" }
        return "比本期之前 30 天的已记录居家占比\(difference > 0 ? "高" : "低") \(abs(difference)) 个百分点。"
    }

    private func commuteChange(_ change: RouteInsights.CommuteChange) -> String {
        let delta = change.average - change.previousAverage
        guard abs(delta) >= 1 else { return "与前一对应时段相近" }
        return "比前一对应时段\(delta < 0 ? "少用" : "多用") \(routeDuration(abs(delta)))"
    }
}
