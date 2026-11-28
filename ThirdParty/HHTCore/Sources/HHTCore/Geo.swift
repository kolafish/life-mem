// Excerpted from TripLibre HHTCore Geo/Geo.swift.
import Foundation

/// WGS84 coordinate in decimal degrees.
public struct Coordinate: Equatable, Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
    public init(latitude: Double, longitude: Double) { self.init(latitude, longitude) }
}

public enum Geo {
    /// Mean Earth radius (IUGG), metres.
    public static let earthRadius = 6_371_008.8

    /// Great-circle (haversine) distance in metres. Error vs. the WGS84 ellipsoid is < 0.5%,
    /// which is well below GPS noise for trip distances.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Arithmetic centroid, optionally weighted. Fine for the small extents of a stay cluster
    /// (not for antimeridian-spanning sets).
    public static func centroid(_ coords: [Coordinate], weights: [Double]? = nil) -> Coordinate? {
        guard !coords.isEmpty else { return nil }
        var lat = 0.0, lon = 0.0, wsum = 0.0
        for (i, c) in coords.enumerated() {
            let w = weights?[i] ?? 1
            lat += c.latitude * w; lon += c.longitude * w; wsum += w
        }
        guard wsum > 0 else { return nil }
        return Coordinate(lat / wsum, lon / wsum)
    }
}
