import Contacts
import CoreLocation
import Foundation
import MapKit
import Observation

struct MapPlaceSuggestion: Codable {
    struct NearbyPoint {
        let name: String
        let distance: CLLocationDistance
        let isLandmark: Bool
    }

    struct Address {
        var street: String?
        var district: String?
        var city: String?
        var detailed: String?
    }

    private struct RankedNames: Codable {
        let label: String?
        let choices: [String]
    }

    static let landmarkRadius: CLLocationDistance = 200
    let pointOfInterestNames: [String]
    let streetOrArea: String?
    let district: String?
    let city: String?
    private var rankedNames: RankedNames?

    init(pointOfInterestNames: [String], streetOrArea: String?, district: String?, city: String?) {
        self.pointOfInterestNames = pointOfInterestNames
        self.streetOrArea = streetOrArea
        self.district = district
        self.city = city
    }

    static func ranked(points: [NearbyPoint], address: Address) -> Self {
        let ordered = points.filter { (0...landmarkRadius).contains($0.distance) && !$0.name.isEmpty }
            .sorted { $0.distance == $1.distance ? $0.name < $1.name : $0.distance < $1.distance }
        var seen: Set<String> = []
        let close = ordered.filter { $0.distance <= 50 && seen.insert($0.name).inserted }
        seen.removeAll()
        let landmarks = ordered.filter { $0.isLandmark && seen.insert($0.name).inserted }
        let trustedPoint: String?
        if let first = close.first, close.count == 1 || close[1].distance - first.distance >= 12 {
            trustedPoint = first.name
        } else {
            trustedPoint = nil
        }
        let street = usableName(address.street) ?? usableName(address.district)
        let label = (trustedPoint ?? street ?? landmarks.first?.name ?? usableName(address.city)).map(nearbyLabel)
        let choices = [label, usableName(address.detailed), street.map(nearbyLabel)].compactMap { $0 } +
            close.prefix(5).map(\.name) + landmarks.prefix(3).map { nearbyLabel($0.name) }
        seen.removeAll()
        var result = Self(pointOfInterestNames: [], streetOrArea: nil, district: nil, city: nil)
        result.rankedNames = RankedNames(label: label, choices: choices.filter { seen.insert($0).inserted })
        return result
    }

    private static func nearbyLabel(_ name: String) -> String {
        name.hasSuffix("附近") ? name : "\(name)附近"
    }

    private static func usableName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    var candidates: [String] {
        if let rankedNames { return rankedNames.choices }
        var seen: Set<String> = []
        let nearby = (streetOrArea ?? district ?? city).map { "\($0)附近" }
        return (pointOfInterestNames + [nearby].compactMap { $0 }).filter { seen.insert($0).inserted }
    }

    var displayName: String? {
        if let rankedNames { return rankedNames.label }
        if let poi = pointOfInterestNames.first { return "\(poi)附近" }
        return candidates.first
    }
}

@MainActor
@Observable
final class PlaceResolver {
    private static let automaticPreference = "automaticPlaceLookup"
    private static let prefetchPreference = "prefetchPlaceNames"
    private static let introductionPreference = "dismissedAutomaticPlaceIntroduction"
    private static let cacheRadius: CLLocationDistance = 25

    private enum AutomaticMode {
        case off, review, prefetch
    }

    typealias DemandCheck = @MainActor () throws -> Void
    typealias Lookup = @MainActor (CLLocationCoordinate2D, DemandCheck) async throws -> LookupResponse

    struct LookupResponse {
        let suggestion: MapPlaceSuggestion?
        let shouldBackOff: Bool

        init(_ suggestion: MapPlaceSuggestion?, shouldBackOff: Bool = false) {
            self.suggestion = suggestion
            self.shouldBackOff = shouldBackOff
        }
    }

    private struct Entry: Codable {
        let latitude: Double
        let longitude: Double
        let suggestion: MapPlaceSuggestion

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    private struct Demand {
        let automaticRevision: UUID?
        let location: CLLocation
        let names: RoutePlaceNames?
        let cancellation: DemandCancellation
    }

    private final class DemandCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }

    private enum LookupOutcome {
        case completed(MapPlaceSuggestion?)
        case abandoned
    }

    private struct ActiveLookup {
        let id: UUID
        let location: CLLocation
        let task: Task<LookupOutcome, Never>
        var demands: [UUID: Demand]
    }

    private let file: URL
    private let defaults: UserDefaults
    private let lookup: Lookup
    private let clock = ContinuousClock()
    private let minimumInterval: Duration
    private let initialBackoff: Duration
    private var entries: [Entry]
    @ObservationIgnored private var active: ActiveLookup?
    @ObservationIgnored private var cacheRevision = UUID()
    @ObservationIgnored private var automaticRevision = UUID()
    @ObservationIgnored private var nextStart: ContinuousClock.Instant?
    @ObservationIgnored private var retryAfter: ContinuousClock.Instant?
    @ObservationIgnored private var backoff: Duration = .zero
    @ObservationIgnored private var prefetchedVisits: Set<RouteVisit.ID> = []
    private var automaticMode: AutomaticMode
    private(set) var hasSeenAutomaticIntroduction: Bool

    var isAutomaticEnabled: Bool { automaticMode != .off }
    var isPrefetchEnabled: Bool { automaticMode == .prefetch }

    init(
        file: URL,
        defaults: UserDefaults = .standard,
        minimumInterval: Duration = .seconds(2),
        initialBackoff: Duration = .seconds(15),
        lookup: Lookup? = nil
    ) {
        self.file = file
        self.defaults = defaults
        self.minimumInterval = minimumInterval
        self.initialBackoff = initialBackoff
        self.lookup = lookup ?? Self.systemLookup
        if defaults.bool(forKey: Self.automaticPreference) {
            automaticMode = defaults.bool(forKey: Self.prefetchPreference) ? .prefetch : .review
        } else {
            automaticMode = .off
        }
        hasSeenAutomaticIntroduction = defaults.bool(forKey: Self.introductionPreference)
        let data = try? Data(contentsOf: file)
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func dismissAutomaticIntroduction() {
        hasSeenAutomaticIntroduction = true
        defaults.set(true, forKey: Self.introductionPreference)
    }

    func setAutomaticEnabled(_ enabled: Bool, includesPrefetch: Bool = false) {
        let mode: AutomaticMode = enabled ? (includesPrefetch ? .prefetch : .review) : .off
        guard automaticMode != mode else { return }
        automaticMode = mode
        defaults.set(enabled, forKey: Self.automaticPreference)
        defaults.set(mode == .prefetch, forKey: Self.prefetchPreference)
        automaticRevision = UUID()
        prefetchedVisits.removeAll()
        if let demands = active?.demands {
            active?.demands = demands.filter { $0.value.automaticRevision == nil }
            cancelWithoutDemand()
        }
    }

    func clearCache() throws {
        try Data("[]".utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        entries = []
        cacheRevision = UUID()
        prefetchedVisits.removeAll()
        active?.demands.removeAll()
        cancelWithoutDemand()
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
        _ = await resolve(near: coordinate, automatic: true, names: names)
    }

    func resolveAutomatically(near coordinates: [CLLocationCoordinate2D], names: RoutePlaceNames) async {
        let cache = cacheRevision
        let permission = automaticRevision
        for coordinate in coordinates {
            guard !Task.isCancelled, cache == cacheRevision, permission == automaticRevision else { return }
            await resolveAutomatically(near: coordinate, names: names)
        }
    }

    func prefetch(_ visits: [RouteVisit], names: RoutePlaceNames) async {
        let cache = cacheRevision
        let permission = automaticRevision
        var remaining = 4
        for visit in visits {
            guard isPrefetchEnabled, names.loadIssue == nil, remaining > 0, !Task.isCancelled,
                  cache == cacheRevision, permission == automaticRevision else { return }
            if let retryAfter, clock.now < retryAfter { return }
            guard !prefetchedVisits.contains(visit.id), names.name(for: visit.coordinate) == nil,
                  cached(near: visit.coordinate) == nil else { continue }
            await resolveAutomatically(near: visit.coordinate, names: names)
            guard !Task.isCancelled, cache == cacheRevision, permission == automaticRevision else { return }
            if let retryAfter, clock.now < retryAfter { return }
            prefetchedVisits.insert(visit.id)
            remaining -= 1
        }
    }

    func resolve(near coordinate: CLLocationCoordinate2D, automatic: Bool, names: RoutePlaceNames? = nil) async -> MapPlaceSuggestion? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let cancellation = DemandCancellation()
        let demand = Demand(
            automaticRevision: automatic ? automaticRevision : nil,
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            names: names,
            cancellation: cancellation
        )
        let id = UUID()
        let revision = cacheRevision
        return await withTaskCancellationHandler {
            while !Task.isCancelled, revision == cacheRevision, isEligible(demand) {
                if let cached = cached(near: coordinate) { return cached }
                if let retryAfter, clock.now < retryAfter { return nil }
                let task: Task<LookupOutcome, Never>
                if let active {
                    task = active.task
                    guard !task.isCancelled, active.location.distance(from: demand.location) <= Self.cacheRadius else {
                        _ = await task.value
                        continue
                    }
                    self.active?.demands[id] = demand
                } else {
                    task = Task { await performLookup(id: id, coordinate: coordinate) }
                    active = ActiveLookup(id: id, location: demand.location, task: task, demands: [id: demand])
                }
                if case let .completed(result) = await task.value {
                    return !Task.isCancelled && revision == cacheRevision && isEligible(demand) ? result : nil
                }
            }
            return nil
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.active?.demands.removeValue(forKey: id)
                self?.cancelWithoutDemand()
            }
        }
    }

    private func isEligible(_ demand: Demand) -> Bool {
        guard !demand.cancellation.isCancelled else { return false }
        guard let revision = demand.automaticRevision else { return true }
        return isAutomaticEnabled && revision == automaticRevision &&
            demand.names?.loadIssue == nil &&
            demand.names?.name(for: demand.location.coordinate) == nil
    }

    private func hasOriginDemand(_ request: ActiveLookup) -> Bool {
        request.demands.values.contains {
            $0.location.coordinate.latitude == request.location.coordinate.latitude &&
            $0.location.coordinate.longitude == request.location.coordinate.longitude && isEligible($0)
        }
    }

    private func hasEligibleDemand(_ request: ActiveLookup) -> Bool {
        request.demands.values.contains(where: isEligible)
    }

    private func cancelWithoutDemand() {
        if let active, !hasEligibleDemand(active) { active.task.cancel() }
    }

    private func performLookup(id: UUID, coordinate: CLLocationCoordinate2D) async -> LookupOutcome {
        defer { active = nil }
        if let nextStart, clock.now < nextStart {
            do {
                try await clock.sleep(until: nextStart)
            } catch {
                return .abandoned
            }
        }
        guard !Task.isCancelled, let active, active.id == id, hasOriginDemand(active) else { return .abandoned }
        nextStart = clock.now.advanced(by: minimumInterval)
        let result: LookupResponse
        do {
            result = try await lookup(coordinate) {
                // A new network request at the original coordinate still needs an eligible caller there.
                guard !Task.isCancelled, let current = self.active, current.id == id, self.hasOriginDemand(current) else {
                    throw CancellationError()
                }
            }
        } catch is CancellationError {
            return .abandoned
        } catch {
            guard !Task.isCancelled, let current = self.active, current.id == id, hasEligibleDemand(current) else { return .abandoned }
            backOff()
            return .completed(nil)
        }
        guard !Task.isCancelled, let current = self.active, current.id == id, hasEligibleDemand(current) else { return .abandoned }
        if result.shouldBackOff {
            backOff()
        } else {
            backoff = .zero
            retryAfter = nil
        }
        guard let suggestion = result.suggestion, !suggestion.candidates.isEmpty else { return .completed(nil) }
        entries.append(Entry(latitude: coordinate.latitude, longitude: coordinate.longitude, suggestion: suggestion))
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return .completed(suggestion)
    }

    private func backOff() {
        backoff = min(.seconds(60), max(initialBackoff, backoff * 2))
        retryAfter = clock.now.advanced(by: backoff)
    }

    private static func systemLookup(
        near coordinate: CLLocationCoordinate2D,
        checkDemand: DemandCheck
    ) async throws -> LookupResponse {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: MapPlaceSuggestion.landmarkRadius)
        let items: [MKMapItem]
        var lookupError: Error?
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .loadingThrottled {
            throw error
        } catch let error as MKError where error.code == .placemarkNotFound {
            items = []
        } catch {
            items = []
            lookupError = error
        }
        let nearby = items.compactMap { item -> MapPlaceSuggestion.NearbyPoint? in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let position: CLLocation?
            if #available(iOS 26.0, macOS 26.0, *) {
                position = item.location
            } else {
                position = item.placemark.location
            }
            guard let position else { return nil }
            return .init(name: name, distance: position.distance(from: location),
                         isLandmark: isLandmark(item.pointOfInterestCategory, name: name))
        }

        let address: MapPlaceSuggestion.Address?
        do {
            try checkDemand()
            address = try await reverseGeocode(location)
        } catch is CancellationError {
            let partial = MapPlaceSuggestion.ranked(points: nearby, address: .init())
            guard !Task.isCancelled, partial.displayName != nil else { throw CancellationError() }
            return LookupResponse(partial)
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            address = nil
        } catch let error as MKError where error.code == .placemarkNotFound {
            address = nil
        } catch {
            lookupError = error
            address = nil
        }
        let suggestion = MapPlaceSuggestion.ranked(points: nearby, address: address ?? .init())
        if !suggestion.candidates.isEmpty { return LookupResponse(suggestion, shouldBackOff: lookupError != nil) }
        if let lookupError { throw lookupError }
        return LookupResponse(nil)
    }

    private static func isLandmark(_ category: MKPointOfInterestCategory?, name: String) -> Bool {
        if let category, [.museum, .nationalPark, .park, .amusementPark, .stadium].contains(category) { return true }
        if #available(iOS 18.0, macOS 15.0, *), let category,
           [.landmark, .nationalMonument, .castle, .fairground].contains(category) { return true }
        // MapKit has no dedicated shopping-center category.
        let normalized = name.lowercased()
        return ["购物中心", "购物广场", "商业中心", "商业广场", "商场", " mall", "shopping center", "shopping centre"]
            .contains { normalized.hasSuffix($0) }
    }

    private static func reverseGeocode(_ location: CLLocation) async throws -> MapPlaceSuggestion.Address? {
        if #available(iOS 26.0, macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try await request.mapItems.first else { return nil }
            return .init(
                street: item.address?.shortAddress,
                city: item.addressRepresentations?.cityName,
                detailed: item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true) ?? item.address?.fullAddress
            )
        } else {
            guard let place = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            return .init(
                street: place.thoroughfare,
                district: place.subLocality,
                city: place.locality,
                detailed: place.postalAddress?.street
            )
        }
    }
}
