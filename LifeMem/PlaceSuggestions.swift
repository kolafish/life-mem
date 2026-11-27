import CoreLocation
import Foundation

struct PlaceSuggestion: Identifiable {
    let category: PlaceCategory
    let place: RoutePlace
    let observedDays: Int

    var id: PlaceCategory { category }
}

enum PlaceSuggestions {
    private static let minimumDays = 3
    private static let minimumWindowOverlap: TimeInterval = 30 * 60

    private struct Window {
        let category: PlaceCategory
        let startHour: Int
        let endHour: Int
        let weekdaysOnly: Bool
    }

    static func candidates(
        in places: [RoutePlace], calendar: Calendar, now: Date = .now,
        category: (CLLocationCoordinate2D) -> PlaceCategory?
    ) -> [PlaceSuggestion] {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -27, to: today) else { return [] }
        let windows = [
            Window(category: .home, startHour: 1, endHour: 6, weekdaysOnly: false),
            Window(category: .work, startHour: 10, endHour: 17, weekdaysOnly: true)
        ]
        var suggestions: [PlaceSuggestion] = []
        for window in windows {
            guard !places.contains(where: { category($0.coordinate) == window.category }) else { continue }
            let ranked = places.map { place in
                PlaceSuggestion(
                    category: window.category, place: place,
                    observedDays: observedDays(for: place, window: window, calendar: calendar, cutoff: cutoff, now: now)
                )
            }.sorted { $0.observedDays > $1.observedDays }
            guard let first = ranked.first, first.observedDays >= minimumDays,
                  ranked.dropFirst().first?.observedDays != first.observedDays,
                  category(first.place.coordinate) == nil,
                  !suggestions.contains(where: { $0.place.id == first.place.id }) else { continue }
            suggestions.append(first)
        }
        return suggestions
    }

    private static func observedDays(for place: RoutePlace, window: Window, calendar: Calendar, cutoff: Date, now: Date) -> Int {
        var qualifying: Set<Date> = []
        for visit in place.visits where visit.endedAt > cutoff && visit.startedAt < now {
            var day = calendar.startOfDay(for: max(cutoff, visit.startedAt))
            let last = min(now, visit.endedAt)
            while day < last, let next = calendar.dateInterval(of: .day, for: day)?.end {
                if (!window.weekdaysOnly || !calendar.isDateInWeekend(day)),
                   let start = calendar.date(bySettingHour: window.startHour, minute: 0, second: 0, of: day),
                   let end = calendar.date(bySettingHour: window.endHour, minute: 0, second: 0, of: day),
                   start < next, min(end, last).timeIntervalSince(max(start, visit.startedAt)) >= minimumWindowOverlap {
                    qualifying.insert(day)
                }
                day = next
            }
        }
        return qualifying.count
    }
}
