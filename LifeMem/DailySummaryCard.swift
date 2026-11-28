import SwiftUI

struct DailySummaryCard: View {
    let day: RouteReviewDay

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(RoutePlaceNames.self) private var placeNames

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当日概览").font(.headline).accessibilityAddTraits(.isHeader)
                .padding(.vertical, 4)
            if let start = day.entries.first?.startedAt, let end = day.entries.map(\.endedAt).max() {
                metric("记录跨度", clockRange(start, end), symbol: "clock")
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { movementMetrics }
            } else {
                HStack(spacing: 8) { movementMetrics }
            }
            stayDistribution
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var movementMetrics: some View {
        metric("移动里程", routeDistance(day.movingDistanceMeters), symbol: "point.topleft.down.to.point.bottomright.curvepath")
        metric("移动耗时", routeDuration(day.movingDuration), symbol: "timer")
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var stayDistribution: some View {
        let durations = day.stays.reduce(into: [PlaceCategory: TimeInterval]()) { result, stay in
            result[(stay.visitName == nil ? placeNames.category(for: stay.coordinate) : nil) ?? .other, default: 0] += stay.duration
        }
        let categories = PlaceCategory.allCases.filter { (durations[$0] ?? 0) > 0 }
        let total = durations.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            Text("停留分布").font(.subheadline).foregroundStyle(.secondary)
            if categories.isEmpty {
                Text("当天没有观测到持续停留").font(.footnote).foregroundStyle(.secondary)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(categories) { category in
                            Rectangle()
                                .fill(category.mapColor)
                                .frame(width: geometry.size.width * (durations[category, default: 0] / total))
                        }
                    }
                }
                .frame(height: 7)
                .clipShape(.capsule)
                .accessibilityHidden(true)
                ForEach(categories) { category in
                    HStack(alignment: .firstTextBaseline) {
                        Label(category == .other ? "其他停留" : category.title, systemImage: category.symbol)
                            .foregroundStyle(category == .other ? Color.secondary : Color.primary)
                        Spacer(minLength: 8)
                        Text(routeDuration(durations[category, default: 0])).monospacedDigit()
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}
