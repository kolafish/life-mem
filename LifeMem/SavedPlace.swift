import CoreLocation
import Foundation
import Observation

enum PlaceCategory: String, CaseIterable, Codable, Identifiable, Sendable {
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

struct RoutePlaceSnapshot: Sendable {
    fileprivate struct SavedPlace: Codable, Sendable {
        var name: String
        var category: PlaceCategory?
        let latitude: Double
        let longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    let revision = UUID()
    fileprivate let places: [SavedPlace]

    func category(for coordinate: CLLocationCoordinate2D) -> PlaceCategory? {
        matchingIndex(for: coordinate).flatMap { places[$0].category }
    }

    func hasCategory(_ category: PlaceCategory) -> Bool {
        places.contains { $0.category == category }
    }

    fileprivate func matchingIndex(for coordinate: CLLocationCoordinate2D) -> Int? {
        let location = coordinate.location
        let nearest = places.indices.lazy
            .map { (index: $0, distance: places[$0].location.distance(from: location)) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= RouteReview.placeRadius else { return nil }
        return nearest.index
    }
}

@MainActor
@Observable
final class RoutePlaceNames {
    enum LoadIssue: Error {
        case unreadable, damaged
    }

    private typealias SavedPlace = RoutePlaceSnapshot.SavedPlace
    private let file: URL
    private(set) var snapshot = RoutePlaceSnapshot(places: [])
    private(set) var loadIssue: LoadIssue?

    init(file: URL) {
        self.file = file
        reload()
    }

    func reload() {
        do {
            let places = try JSONDecoder().decode([SavedPlace].self, from: Data(contentsOf: file))
            snapshot = RoutePlaceSnapshot(places: places)
            loadIssue = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            snapshot = RoutePlaceSnapshot(places: [])
            loadIssue = nil
        } catch {
            loadIssue = error is DecodingError ? .damaged : .unreadable
        }
    }

    func rebuildDamagedFile() throws {
        guard loadIssue == .damaged else { return }
        let original = try Data(contentsOf: file)
        if let recovered = try? JSONDecoder().decode([SavedPlace].self, from: original) {
            snapshot = RoutePlaceSnapshot(places: recovered)
            loadIssue = nil
            return
        }

        let stem = file.deletingPathExtension().lastPathComponent
        let backup = file.deletingLastPathComponent().appending(path: "\(stem)-damaged-\(UUID().uuidString).json")
        try original.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try write([])
        loadIssue = nil
    }

    func name(for coordinate: CLLocationCoordinate2D) -> String? {
        snapshot.matchingIndex(for: coordinate).map { snapshot.places[$0].name }
    }

    func category(for coordinate: CLLocationCoordinate2D) -> PlaceCategory? {
        snapshot.category(for: coordinate)
    }

    func save(_ name: String?, category: PlaceCategory? = nil, for coordinate: CLLocationCoordinate2D) throws {
        if let loadIssue { throw loadIssue }
        var updated = snapshot.places
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = snapshot.matchingIndex(for: coordinate) {
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
        try write(updated)
    }

    private func write(_ updated: [SavedPlace]) throws {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        snapshot = RoutePlaceSnapshot(places: updated)
    }
}
