// Excerpted from TripLibre HHTCore Models/Records.swift.
import Foundation

/// One observation from the device (never modified after insert).
public struct RawPoint: Equatable, Sendable {
    public var id: Int64?
    public var timestamp: Date
    public var coordinate: Coordinate
    public var horizontalAccuracy: Double?
    public var altitude: Double?
    public var verticalAccuracy: Double?
    public var speed: Double?          // m/s, nil if invalid
    public var speedAccuracy: Double?
    public var course: Double?
    public var source: String          // gps | visit_arrival | visit_departure | significant_change | region_exit | imported
    public var collectorMode: String?  // moving | stationary
    public var timeZone: String?

    public init(id: Int64? = nil, timestamp: Date, coordinate: Coordinate, horizontalAccuracy: Double? = 10,
                altitude: Double? = nil, verticalAccuracy: Double? = nil, speed: Double? = nil,
                speedAccuracy: Double? = nil, course: Double? = nil, source: String = "gps",
                collectorMode: String? = nil, timeZone: String? = TimeZone.current.identifier) {
        self.id = id
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.source = source
        self.collectorMode = collectorMode
        self.timeZone = timeZone
    }
}

/// A CoreMotion activity classification sample (start of an activity episode).
public struct MotionSample: Equatable, Sendable {
    public enum Activity: String, Sendable { case stationary, walking, running, cycling, automotive, unknown }
    public var timestamp: Date
    public var activity: Activity
    public var confidence: Int   // 0 low, 1 medium, 2 high
    public init(timestamp: Date, activity: Activity, confidence: Int) {
        self.timestamp = timestamp
        self.activity = activity
        self.confidence = confidence
    }
}
