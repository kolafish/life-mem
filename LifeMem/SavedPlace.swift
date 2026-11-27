import CoreLocation
import Foundation
import Observation

enum PlaceCategory: String, CaseIterable, Codable, Identifiable {
    case home, work, dining, shopping, exercise, leisure, other

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "家"
        case .work: "工作／学习"
        case .dining: "餐饮"
        case .shopping: "购物"
        case .exercise: "运动"
        case .leisure: "休闲"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .dining: "fork.knife"
        case .shopping: "basket.fill"
        case .exercise: "figure.run"
        case .leisure: "cup.and.saucer.fill"
        case .other: "mappin.circle.fill"
        }
    }

    var defaultName: String { self == .work ? "公司" : title }
}

@MainActor
@Observable
final class RoutePlaceNames {
    private struct SavedPlace: Codable {
        var name: String
        var category: PlaceCategory?
        let latitude: Double
        let longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    private let file: URL
    private var names: [SavedPlace] = []
    private let loadError: Error?

    init(file: URL) {
        self.file = file
        do {
            names = try JSONDecoder().decode([SavedPlace].self, from: Data(contentsOf: file))
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loadError = nil
        } catch {
            loadError = error
        }
    }

    func name(for coordinate: CLLocationCoordinate2D) -> String? {
        matchingIndex(for: coordinate).map { names[$0].name }
    }

    func category(for coordinate: CLLocationCoordinate2D) -> PlaceCategory? {
        matchingIndex(for: coordinate).flatMap { names[$0].category }
    }

    func hasCategory(_ category: PlaceCategory) -> Bool {
        names.contains { $0.category == category }
    }

    func save(_ name: String?, category: PlaceCategory? = nil, for coordinate: CLLocationCoordinate2D) throws {
        if let loadError { throw loadError }
        var updated = names
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = matchingIndex(for: coordinate) {
            if trimmed.isEmpty {
                updated.remove(at: index)
            } else {
                updated[index].name = trimmed
                updated[index].category = category
            }
        } else if !trimmed.isEmpty {
            updated.append(SavedPlace(name: trimmed, category: category, latitude: coordinate.latitude, longitude: coordinate.longitude))
        } else {
            return
        }
        let data = try JSONEncoder().encode(updated)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        names = updated
    }

    private func matchingIndex(for coordinate: CLLocationCoordinate2D) -> Int? {
        let location = coordinate.location
        let nearest = names.indices.lazy
            .map { (index: $0, distance: self.names[$0].location.distance(from: location)) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= RouteReview.placeRadius else { return nil }
        return nearest.index
    }
}
