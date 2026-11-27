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
    private(set) var isAutomaticEnabled: Bool

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
        isAutomaticEnabled = defaults.bool(forKey: Self.automaticPreference)
        let data = try? Data(contentsOf: file)
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        guard enabled != isAutomaticEnabled else { return }
        isAutomaticEnabled = enabled
        defaults.set(enabled, forKey: Self.automaticPreference)
        automaticRevision = UUID()
        if !enabled, let demands = active?.demands {
            active?.demands = demands.filter { $0.value.automaticRevision == nil }
            cancelWithoutOriginDemand()
        }
    }

    func clearCache() throws {
        try Data("[]".utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        entries = []
        cacheRevision = UUID()
        active?.demands.removeAll()
        cancelWithoutOriginDemand()
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
                self?.cancelWithoutOriginDemand()
            }
        }
    }

    private func isEligible(_ demand: Demand) -> Bool {
        guard !demand.cancellation.isCancelled else { return false }
        guard let revision = demand.automaticRevision else { return true }
        return isAutomaticEnabled && revision == automaticRevision &&
            demand.names?.name(for: demand.location.coordinate) == nil
    }

    private func hasOriginDemand(_ request: ActiveLookup) -> Bool {
        request.demands.values.contains {
            $0.location.coordinate.latitude == request.location.coordinate.latitude &&
            $0.location.coordinate.longitude == request.location.coordinate.longitude && isEligible($0)
        }
    }

    private func cancelWithoutOriginDemand() {
        if let active, !hasOriginDemand(active) { active.task.cancel() }
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
                guard !Task.isCancelled, let current = self.active, self.hasOriginDemand(current) else {
                    throw CancellationError()
                }
            }
        } catch is CancellationError {
            return .abandoned
        } catch {
            guard !Task.isCancelled else { return .abandoned }
            backOff()
            return .completed(nil)
        }
        guard !Task.isCancelled, let current = self.active, hasOriginDemand(current) else { return .abandoned }
        if result.shouldBackOff {
            backOff()
        } else {
            backoff = .zero
            retryAfter = nil
        }
        guard let suggestion = result.suggestion, suggestion.displayName != nil else { return .completed(nil) }
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
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: searchRadius)
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
        let nearby = items.compactMap { item -> (name: String, distance: CLLocationDistance)? in
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
        }.sorted { $0.distance < $1.distance }

        let result: MapPlaceSuggestion?
        try checkDemand()
        do {
            result = try await reverseGeocode(location)
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            result = nil
        } catch let error as MKError where error.code == .placemarkNotFound {
            result = nil
        } catch {
            lookupError = error
            result = nil
        }
        var seen: Set<String> = []
        let names = ((result?.pointOfInterestNames ?? []) + nearby.map(\.name))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let suggestion = MapPlaceSuggestion(pointOfInterestNames: Array(names.prefix(5)), streetOrArea: result?.streetOrArea,
                                            district: result?.district, city: result?.city)
        if suggestion.displayName != nil { return LookupResponse(suggestion, shouldBackOff: lookupError != nil) }
        if let lookupError { throw lookupError }
        return LookupResponse(nil)
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
