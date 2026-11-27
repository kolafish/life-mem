import CoreLocation
import Foundation
import SwiftData

// The optional point count keeps build 8's running trial and its original counters readable.
struct ResumeTrial: Codable, Sendable {
    var beganAt: Date
    var lastTransition: Date?
    var waitingForMovement = false
    var pauses = 0
    var resumes = 0
    var lastMarkedDelay: Int?
    var savedPoints: Int?
}

@Model
final class ResumeFix {
    var trialBeganAt: Date
    var sequence: Int
    var sampledAt: Date
    var receivedAt: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var event: String

    // A checkpoint in the same transaction keeps the counters and track consistent on relaunch.
    var pauses: Int
    var resumes: Int
    var lastTransition: Date?
    var lastMarkedDelay: Int?

    init(fix: CLLocation, receivedAt: Date, event: String, trial: ResumeTrial) {
        trialBeganAt = trial.beganAt
        sequence = trial.savedPoints ?? 0
        sampledAt = fix.timestamp
        self.receivedAt = receivedAt
        latitude = fix.coordinate.latitude
        longitude = fix.coordinate.longitude
        horizontalAccuracy = fix.horizontalAccuracy
        self.event = event
        pauses = trial.pauses
        resumes = trial.resumes
        lastTransition = trial.lastTransition
        lastMarkedDelay = trial.lastMarkedDelay
    }
}

actor ResumeTrace: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    private var trial: ResumeTrial
    private var latestFix: Date?

    static func open(directory: URL, trial: ResumeTrial) async throws -> ResumeTrace {
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        let configuration = ModelConfiguration(url: directory.appending(path: "trace.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: ResumeFix.self, configurations: configuration)
        let trace = ResumeTrace(container: container, trial: trial)
        try await trace.restore()
        return trace
    }

    private init(container: ModelContainer, trial: ResumeTrial) {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.trial = trial
    }

    private func restore() throws {
        var restored = trial
        let start = trial.beganAt
        var query = FetchDescriptor<ResumeFix>(predicate: #Predicate { $0.trialBeganAt == start },
            sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        query.fetchLimit = 1
        if let last = try modelContext.fetch(query).first {
            latestFix = last.sampledAt
            restored.waitingForMovement = last.event == "pause"
            restored.pauses = last.pauses
            restored.resumes = last.resumes
            restored.lastTransition = last.lastTransition
            restored.lastMarkedDelay = last.lastMarkedDelay
            restored.savedPoints = last.sequence
        } else {
            latestFix = trial.lastTransition
            restored.savedPoints = 0
        }
        self.trial = restored
    }

    var checkpoint: ResumeTrial { trial }

    func record(_ fix: CLLocation, stationary: Bool, receivedAt: Date, markedAt: Date?,
                markWindow: TimeInterval) throws -> ResumeTrial? {
        try Task.checkCancellation()
        let changesState = stationary != trial.waitingForMovement
        guard CLLocationCoordinate2DIsValid(fix.coordinate), fix.horizontalAccuracy >= 0,
              fix.timestamp >= trial.beganAt, fix.timestamp <= receivedAt,
              fix.timestamp >= (latestFix ?? .distantPast),
              changesState || (!stationary && fix.timestamp != latestFix) else { return nil }

        var next = trial
        next.savedPoints = (trial.savedPoints ?? 0) + 1
        var event = "point"
        if changesState {
            next.waitingForMovement = stationary
            next.lastTransition = fix.timestamp
            if stationary {
                event = "pause"
                next.pauses += 1
            } else {
                event = "resume"
                next.resumes += 1
                next.lastMarkedDelay = nil
                if let markedAt, fix.timestamp >= markedAt {
                    let delay = receivedAt.timeIntervalSince(markedAt)
                    if (0..<markWindow).contains(delay) { next.lastMarkedDelay = Int(delay) }
                }
            }
        }
        modelContext.insert(ResumeFix(fix: fix, receivedAt: receivedAt, event: event, trial: next))
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        latestFix = fix.timestamp
        trial = next
        return next
    }
}
