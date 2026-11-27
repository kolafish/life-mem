import CoreLocation
import Foundation
import MapKit
import Observation

struct MapPlaceSuggestion: Codable {
    let pointOfInterestNames: [String]
    let streetOrArea: String?
    let district: String?
    let city: String?

    var candidates: [String] {
        var seen: Set<String> = []
        let nearby = (streetOrArea ?? district ?? city).map { "\($0)附近" }
        return (pointOfInterestNames + [nearby].compactMap { $0 }).filter { seen.insert($0).inserted }
    }

    var displayName: String? {
        if let poi = pointOfInterestNames.first { return "\(poi)附近" }
        return candidates.first
    }
}

@MainActor
@Observable
final class PlaceResolver {
    private static let automaticPreference = "automaticPlaceLookup"
    private static let searchRadius: CLLocationDistance = 50
    private static let cacheRadius: CLLocationDistance = 25

    private struct Entry: Codable {
        let latitude: Double
        let longitude: Double
        let suggestion: MapPlaceSuggestion

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    private let file: URL
    private let defaults: UserDefaults
    private let lookup: (CLLocationCoordinate2D) async -> MapPlaceSuggestion?
    private var entries: [Entry]
    private(set) var isAutomaticEnabled: Bool

    init(
        file: URL,
        defaults: UserDefaults = .standard,
        lookup: ((CLLocationCoordinate2D) async -> MapPlaceSuggestion?)? = nil
    ) {
        self.file = file
        self.defaults = defaults
        self.lookup = lookup ?? Self.systemLookup
        isAutomaticEnabled = defaults.bool(forKey: Self.automaticPreference)
        let data = try? Data(contentsOf: file)
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        isAutomaticEnabled = enabled
        defaults.set(enabled, forKey: Self.automaticPreference)
    }

    func cached(near coordinate: CLLocationCoordinate2D) -> MapPlaceSuggestion? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let nearest = entries.lazy.map { (suggestion: $0.suggestion, distance: $0.location.distance(from: location)) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= Self.cacheRadius else { return nil }
        return nearest.suggestion
    }

    func label(near coordinate: CLLocationCoordinate2D, names: RoutePlaceNames) -> String? {
        names.name(for: coordinate) ?? cached(near: coordinate)?.displayName
    }

    func resolveAutomatically(near coordinate: CLLocationCoordinate2D, names: RoutePlaceNames) async {
        guard names.name(for: coordinate) == nil else { return }
        _ = await resolve(near: coordinate, automatic: true)
    }

    func resolve(near coordinate: CLLocationCoordinate2D, automatic: Bool) async -> MapPlaceSuggestion? {
        guard !Task.isCancelled, !automatic || isAutomaticEnabled else { return nil }
        if let cached = cached(near: coordinate) { return cached }
        guard let suggestion = await lookup(coordinate), suggestion.displayName != nil,
              !Task.isCancelled, !automatic || isAutomaticEnabled else { return nil }
        if let cached = cached(near: coordinate) { return cached }
        entries.append(Entry(latitude: coordinate.latitude, longitude: coordinate.longitude, suggestion: suggestion))
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return suggestion
    }

    private static func systemLookup(near coordinate: CLLocationCoordinate2D) async -> MapPlaceSuggestion? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: searchRadius)
        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return nil }
        let nearby = response?.mapItems.compactMap { item -> (name: String, distance: CLLocationDistance)? in
            guard let name = item.name, !name.isEmpty else { return nil }
            let position: CLLocation?
            if #available(iOS 26.0, macOS 26.0, *) {
                position = item.location
            } else {
                position = item.placemark.location
            }
            guard let position else { return nil }
            let distance = position.distance(from: location)
            guard distance <= searchRadius else { return nil }
            return (name, distance)
        }.sorted { $0.distance < $1.distance } ?? []

        let result = (try? await reverseGeocode(location)) ?? MapPlaceSuggestion(
            pointOfInterestNames: [], streetOrArea: nil, district: nil, city: nil
        )
        var seen: Set<String> = []
        let names = (result.pointOfInterestNames + nearby.map(\.name))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return MapPlaceSuggestion(pointOfInterestNames: Array(names.prefix(5)), streetOrArea: result.streetOrArea,
                                  district: result.district, city: result.city)
    }

    private static func reverseGeocode(_ location: CLLocation) async throws -> MapPlaceSuggestion? {
        if #available(iOS 26.0, macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try await request.mapItems.first else { return nil }
            let poi = item.pointOfInterestCategory != nil ? item.name : nil
            return MapPlaceSuggestion(
                pointOfInterestNames: [poi].compactMap { $0 },
                streetOrArea: item.address?.shortAddress,
                district: nil,
                city: item.addressRepresentations?.cityName
            )
        } else {
            guard let place = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            return MapPlaceSuggestion(
                pointOfInterestNames: place.areasOfInterest ?? [],
                streetOrArea: place.thoroughfare,
                district: place.subLocality,
                city: place.locality
            )
        }
    }
}
