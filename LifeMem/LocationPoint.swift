import CoreLocation
import Foundation

struct LocationPoint<ID: Hashable> {
    let id: ID
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let accuracy: CLLocationAccuracy
    let mode: TravelMode
    let startsNewSegment: Bool
    let startsRecordingRun: Bool?
}

struct StoredCoordinate: Codable, Sendable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

extension CLLocationCoordinate2D {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

enum TravelMode: String, CaseIterable, Codable, Sendable {
    case unknown, walking, automotive, cycling, stationary

    static func estimated(metersPerSecond: CLLocationSpeed) -> Self {
        switch metersPerSecond * 3.6 {
        case 0..<7: .walking
        case 7...25: .cycling
        default: .automotive
        }
    }

    var title: String {
        switch self {
        case .unknown: "识别中"
        case .walking: "步行"
        case .automotive: "乘车"
        case .cycling: "骑行"
        case .stationary: "静止"
        }
    }

    var recordedTitle: String {
        switch self {
        case .unknown: "未分类"
        case .stationary: "停留"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "location"
        case .walking: "figure.walk"
        case .automotive: "car"
        case .cycling: "bicycle"
        case .stationary: "pause.circle"
        }
    }
}

struct LocationSampling {
    static let maximumGap: TimeInterval = 90
    static let accuracyLimit: CLLocationAccuracy = 50
    static let speedLimit: CLLocationSpeed = 200 / 3.6

    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    let maximumAccuracy: CLLocationAccuracy
    let maximumTravelSpeed: CLLocationSpeed

    init(mode: TravelMode) {
        switch mode {
        case .walking:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 8
            maximumAccuracy = 35
            maximumTravelSpeed = 12
        case .automotive:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 30
            maximumAccuracy = Self.accuracyLimit
            maximumTravelSpeed = Self.speedLimit
        case .cycling:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 15
            maximumAccuracy = 40
            maximumTravelSpeed = 30
        case .stationary:
            desiredAccuracy = kCLLocationAccuracyHundredMeters
            distanceFilter = kCLDistanceFilterNone
            maximumAccuracy = Self.accuracyLimit
            maximumTravelSpeed = Self.speedLimit
        case .unknown:
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            distanceFilter = 10
            maximumAccuracy = 45
            maximumTravelSpeed = Self.speedLimit
        }
    }

    func assess(_ location: CLLocation, after previous: CLLocation?, mode: TravelMode, previousMode: TravelMode? = nil) -> RouteStep? {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              (0...maximumAccuracy).contains(location.horizontalAccuracy) else { return nil }
        guard let previous else { return .newSegment }
        let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
        guard seconds > 0 else { return nil }
        if seconds > Self.maximumGap { return .newSegment }
        let meters = location.distance(from: previous)
        guard meters / seconds <= maximumTravelSpeed else { return nil }
        if mode == .stationary {
            if previousMode != .stationary { return .newSegment }
            return seconds >= 30 ? .continuation(distance: 0) : nil
        }
        if previousMode == .stationary { return .newSegment }
        let noiseAllowance = (location.horizontalAccuracy + previous.horizontalAccuracy) * 0.35
        if meters >= max(distanceFilter, noiseAllowance) { return .continuation(distance: meters) }
        if mode == .unknown, seconds >= 30 { return .continuation(distance: 0) }
        return nil
    }
}

enum RouteStep {
    case newSegment
    case continuation(distance: CLLocationDistance)

    var distance: CLLocationDistance {
        switch self {
        case .newSegment: 0
        case let .continuation(distance): distance
        }
    }

    var startsNewSegment: Bool {
        if case .newSegment = self { return true }
        return false
    }
}
