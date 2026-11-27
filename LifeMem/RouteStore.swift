import Foundation
import SwiftData

@MainActor
enum RouteStore {
    static func open(directory: URL) throws -> ModelContainer {
        let schema = Schema([RecordedRoute.self, RoutePoint.self])
        var directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appending(path: "routes.store"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }
}
