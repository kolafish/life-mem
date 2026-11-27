import SwiftUI

struct ReviewTextRow: View {
    let title: String
    let detail: String?
    var time: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let time {
                Text(time).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(title).font(.body.weight(.medium))
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

func clockRange(_ start: Date, _ end: Date) -> String {
    if Calendar.current.isDate(start, equalTo: end, toGranularity: .minute) {
        return start.formatted(.dateTime.hour().minute())
    }
    return (start..<end).formatted(.interval.hour().minute())
}

extension PlaceCategory {
    var mapColor: Color {
        switch self {
        case .home: .teal
        case .work: .indigo
        case .dining: .orange
        case .shopping: .pink
        case .exercise: .green
        case .leisure: .blue
        case .other: .gray
        }
    }
}

extension TravelMode {
    var mapColor: Color {
        switch self {
        case .walking: .green
        case .cycling: .orange
        case .automotive: .blue
        case .stationary: .teal
        case .unknown: .gray
        }
    }
}

func routeDuration(_ seconds: TimeInterval) -> String {
    if seconds == 0 { return "0 分钟" }
    if seconds < 60 { return "\(Int(seconds.rounded())) 秒" }
    return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

func routeDistance(_ meters: Double) -> String {
    if meters < 1_000 {
        return "\(meters.formatted(.number.precision(.fractionLength(0)))) 米"
    }
    return "\((meters / 1_000).formatted(.number.precision(.fractionLength(2)))) 公里"
}

extension RecordedRoute {
    var formattedDistance: String { routeDistance(distanceMeters) }
}
