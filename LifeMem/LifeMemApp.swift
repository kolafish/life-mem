import Foundation
import SwiftData
import SwiftUI

@main
struct LifeMemApp: App {
    private static let storageDirectory = URL.applicationSupportDirectory.appending(path: "LifeMem", directoryHint: .isDirectory)
    private let storage: Result<ModelContainer, Error>
    @State private var placeNames = RoutePlaceNames(file: LifeMemApp.storageDirectory.appending(path: "place-names.json"))

    @State private var placeResolver = PlaceResolver(file: LifeMemApp.storageDirectory.appending(path: "place-suggestions.json"))

    init() {
        storage = Result {
            let schema = Schema([RecordedRoute.self, RoutePoint.self])
            var directory = Self.storageDirectory
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

    var body: some Scene {
        WindowGroup {
            switch storage {
            case let .success(container):
                RootView(context: container.mainContext)
                    .modelContainer(container)
                    .environment(placeNames)
                    .environment(placeResolver)
            case .failure:
                ContentUnavailableView(
                    "暂时无法打开路线存储",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("请检查可用存储空间，再重新打开 Life Mem。")
                )
            }
        }
    }
}

private struct RootView: View {
    @State private var recorder: RouteRecorder

    init(context: ModelContext) {
        _recorder = State(initialValue: RouteRecorder(context: context))
    }

    var body: some View {
        TabView {
            NavigationStack {
                RecordView(recorder: recorder)
            }
            .tabItem { Label("记录", systemImage: "location.circle") }

            NavigationStack {
                RouteHistoryView()
            }
            .tabItem { Label("回顾", systemImage: "calendar") }
        }
        .tint(.indigo)
        .alert("Life Mem", isPresented: Binding(
            get: { recorder.notice != nil },
            set: { if !$0 { recorder.notice = nil } }
        )) {
            Button("好") { recorder.notice = nil }
        } message: {
            Text(recorder.notice ?? "")
        }
    }
}
