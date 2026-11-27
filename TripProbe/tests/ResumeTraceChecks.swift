import CoreLocation
import Foundation
import SwiftData

@main
struct ResumeTraceChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyJSON = #"{"beganAt":100,"waitingForMovement":false,"pauses":2,"resumes":2}"#
        let legacy = try JSONDecoder().decode(ResumeTrial.self, from: Data(legacyJSON.utf8))
        precondition(legacy.savedPoints == nil)
        let trace = try await ResumeTrace.open(directory: directory, trial: legacy)
        let start = legacy.beganAt

        func record(_ store: ResumeTrace, _ seconds: Double, _ stationary: Bool,
                    accuracy: Double = 5, mark: Date? = nil) async throws -> ResumeTrial? {
            let fix = CLLocation(coordinate: .init(latitude: 0, longitude: seconds / 100_000),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(seconds))
            return try await store.record(fix, stationary: stationary, receivedAt: fix.timestamp.addingTimeInterval(2),
                markedAt: mark, markWindow: 1800)
        }

        let initial = try await record(trace, 1, false)
        precondition(initial?.savedPoints == 1 && initial?.resumes == 2)
        let pause = try await record(trace, 1, true)
        precondition(pause?.pauses == 3 && pause?.waitingForMovement == true)
        let duplicate = try await record(trace, 2, true)
        precondition(duplicate == nil)
        let stale = try await record(trace, 0, false)
        let invalid = try await record(trace, 3, false, accuracy: -1)
        precondition(stale == nil && invalid == nil)

        // Reopen with old preferences as if the process died immediately after saving.
        let restored = try await ResumeTrace.open(directory: directory, trial: legacy)
        let checkpoint = await restored.checkpoint
        precondition(checkpoint.waitingForMovement && checkpoint.pauses == 3 && checkpoint.savedPoints == 2)
        let resume = try await record(restored, 6, false, mark: start.addingTimeInterval(4))
        precondition(resume?.resumes == 3 && resume?.lastMarkedDelay == 4)
        let repeated = try await record(restored, 6, false)
        precondition(repeated == nil)
        let nextPoint = try await record(restored, 7, false)
        precondition(nextPoint?.savedPoints == 4)
        _ = try await record(restored, 8, true)
        let unmarked = try await record(restored, 10, false)
        precondition(unmarked?.resumes == 4 && unmarked?.lastMarkedDelay == nil)

        let secondTrial = ResumeTrial(beganAt: start.addingTimeInterval(60))
        let separate = try await ResumeTrace.open(directory: directory, trial: secondTrial)
        let separateCheckpoint = await separate.checkpoint
        precondition(separateCheckpoint.savedPoints == 0 && separateCheckpoint.resumes == 0)
        _ = try await record(separate, 61, false)

        let configuration = ModelConfiguration(url: directory.appending(path: "trace.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: ResumeFix.self, configurations: configuration)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<ResumeFix>(
            sortBy: [SortDescriptor(\.trialBeganAt), SortDescriptor(\.sequence)]))
        precondition(rows.map(\.event) == ["point", "pause", "resume", "point", "pause", "resume", "point"])
        precondition(rows.map(\.sequence) == [1, 2, 3, 4, 5, 6, 1])
        precondition(rows[2].sampledAt == start.addingTimeInterval(6))
        precondition(rows[2].receivedAt == start.addingTimeInterval(8))
        precondition(rows[2].longitude == 6.0 / 100_000 && rows[2].horizontalAccuracy == 5)
        precondition(rows.last?.trialBeganAt == secondTrial.beganAt)
        let resources = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        precondition(resources.isExcludedFromBackup == true)
        print("Passed trace recording, transition, reopen, legacy upgrade and session isolation checks")
    }
}
