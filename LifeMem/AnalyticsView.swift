import Charts
import SwiftData
import SwiftUI

struct AnalyticsView: View {
    @Environment(\.calendar) private var calendar
    @Environment(RoutePlaceNames.self) private var names
    @Environment(PlaceResolver.self) private var resolver
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(filter: #Predicate<RecordedRoute> { $0.pointCount > 0 })
    private var routes: [RecordedRoute]

    @State private var review: RouteReview?
    @State private var period = Period.week
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var rank = RouteAnalytics.PlaceRanking.visits

    private enum Period: String, CaseIterable, Identifiable {
        case week = "本周"
        case month = "本月"
        case custom = "自定义"

        var id: Self { self }

        var interval: Calendar.Component? {
            switch self {
            case .week: .weekOfYear
            case .month: .month
            case .custom: nil
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                periodSelector
                if let review {
                    let data = RouteAnalytics(review: review, range: dateRange, category: names.category(for:))
                    if data.time.isEmpty {
                        ContentUnavailableView(
                            "这段时间暂无统计",
                            systemImage: "chart.bar.xaxis",
                            description: Text("记录到移动或持续停留后，这里会显示时间分配和常去地点。")
                        )
                    } else {
                        timeAllocation(data)
                        if !data.places.isEmpty { topPlaces(data) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("分析")
        .task(id: RouteReviewRevision(calendar: calendar, routes: routes)) {
            review = RouteReview(routes: routes, calendar: calendar)
        }
    }

    private var dateRange: ClosedRange<Date> {
        if let component = period.interval, let interval = calendar.dateInterval(of: component, for: .now) {
            return interval.start...calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        }
        return calendar.startOfDay(for: start)...calendar.startOfDay(for: max(start, end))
    }

    private var periodSelector: some View {
        VStack(spacing: 8) {
            let picker = Picker("统计周期", selection: $period) {
                ForEach(Period.allCases) { item in Text(item.rawValue).tag(item) }
            }
            if typeSize.isAccessibilitySize {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
            if period == .custom {
                DatePicker("开始日期", selection: $start, displayedComponents: .date)
                    .accessibilityIdentifier("analytics-start-date")
                    .onChange(of: start) { _, value in end = max(value, end) }
                DatePicker("结束日期", selection: $end, in: calendar.startOfDay(for: start)..., displayedComponents: .date)
                    .accessibilityIdentifier("analytics-end-date")
            }
        }
    }

    private func timeAllocation(_ data: RouteAnalytics) -> some View {
        analyticsCard("时间分配") {
            Chart(data.time) { item in
                SectorMark(angle: .value("记录时长", item.seconds),
                           innerRadius: .ratio(0.64), angularInset: 1.5)
                    .foregroundStyle(item.use.color)
                    .accessibilityLabel(item.use.title)
                    .accessibilityValue(routeDuration(item.seconds))
            }
            .frame(height: 170)
            ForEach(data.time) { item in
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(item.use.color).frame(width: 9, height: 9).accessibilityHidden(true)
                    Text(item.use.title)
                    Spacer(minLength: 8)
                    Text(routeDuration(item.seconds)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
            Divider()
            Text("逐日记录").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Chart(data.days) { day in
                ForEach(day.time) { item in
                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("小时", item.seconds / 3_600)
                    )
                    .foregroundStyle(by: .value("分类", item.use.title))
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，\(item.use.title)")
                    .accessibilityValue(routeDuration(item.seconds))
                }
            }
            .chartForegroundStyleScale(domain: RouteTimeUse.allCases.map(\.title), range: RouteTimeUse.allCases.map(\.color))
            .chartLegend(.hidden)
            .chartYAxisLabel("小时")
            .chartXScale(domain: dateRange.lowerBound...(calendar.date(byAdding: .day, value: 1, to: dateRange.upperBound) ?? dateRange.upperBound))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .frame(height: 160)
        }
    }

    private func topPlaces(_ data: RouteAnalytics) -> some View {
        let indices = Dictionary(uniqueKeysWithValues: data.places.enumerated().map { ($0.element.id, $0.offset + 1) })
        let top = data.topPlaces(by: rank)
        let maximum = top.map { rank == .visits ? Double($0.visits) : $0.seconds }.max() ?? 1
        return analyticsCard("常去地点") {
            Picker("排行方式", selection: $rank) {
                ForEach(RouteAnalytics.PlaceRanking.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            ForEach(top) { item in
                let coordinate = item.place.coordinate
                let title = resolver.label(near: coordinate, names: names) ?? "停留地点 \(indices[item.id, default: 1])"
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.medium))
                    GeometryReader { geometry in
                        Capsule().fill(names.category(for: coordinate)?.mapColor ?? .teal)
                            .frame(width: geometry.size.width * (rank == .visits ? Double(item.visits) : item.seconds) / maximum)
                    }
                    .frame(height: 7)
                    .accessibilityHidden(true)
                    Text("\(item.visits) 次到访 · \(routeDuration(item.seconds))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private func analyticsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
}

private extension RouteTimeUse {
    var color: Color {
        switch self {
        case .home: .teal
        case .work: .indigo
        case .moving: .blue
        case .leisure: .orange
        case .exercise: .green
        case .other: .gray
        }
    }
}
