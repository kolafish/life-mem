import Photos
import SwiftData
import SwiftUI

struct DayLibraryRevision: Equatable {
    struct Entry: Equatable {
        let key: RouteMemoryKey?
        let start: Date
        let end: Date
        let segments: Int
    }
    let date: Date
    let entries: [Entry]
    let enabled: Bool
    let active: Bool
    let revision: Int
}

@MainActor @Observable
final class DayPhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var matches: [RouteMemoryKey: [PHAsset]] = [:]
    private(set) var pending: [PHAsset] = []
    private(set) var available: [String: PHAsset] = [:]
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var revision = 0
    private var observing = false
    private var cachedDay: Date?
    private var cachedRevision = -1
    private var cachedAssets: [PHAsset] = []


    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.revision &+= 1 }
    }

    func observe(_ value: Bool) {
        guard value != observing else { return }
        observing = value
        if value { PHPhotoLibrary.shared().register(self) }
        else {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
            cachedDay = nil
            cachedAssets = []
        }
    }

    func refresh(_ day: RouteReviewDay, enabled: Bool) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != authorization {
            cachedDay = nil
            available = [:]; matches = [:]; pending = []
        }
        authorization = status
        guard enabled, authorization == .authorized || authorization == .limited,
              let interval = Calendar.current.dateInterval(of: .day, for: day.date) else {
            available = [:]; matches = [:]; pending = []
            observe(false)
            return
        }
        observe(true)
        let version = revision
        let assets: [PHAsset]
        if cachedDay == interval.start && cachedRevision == version {
            assets = cachedAssets
        } else {
            assets = await Self.fetchAssets(in: interval)
            guard !Task.isCancelled else { return }
            cachedDay = interval.start
            cachedRevision = version
            cachedAssets = assets
        }
        guard !Task.isCancelled else { return }
        var grouped: [RouteMemoryKey: [PHAsset]] = [:]
        var others: [PHAsset] = []
        for asset in assets {
            if let time = asset.creationDate, let key = day.memoryKey(forPhotoAt: time, coordinate: asset.location?.coordinate) {
                grouped[key, default: []].append(asset)
            } else { others.append(asset) }
        }
        available = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        matches = grouped
        pending = others
    }

    private static func fetchAssets(in interval: DateInterval) async -> [PHAsset] {
        await Task.detached {

            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", interval.start as NSDate, interval.end as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: .image, options: options)
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                if !asset.mediaSubtypes.contains(.photoScreenshot) && !asset.isHidden { assets.append(asset) }
            }
            return assets
        }.value
    }

}

private struct LibraryContextKey: EnvironmentKey {
    static let defaultValue = DayLibraryContext()
}

struct DayLibraryContext {
    var library: DayPhotoLibrary?
    var excluded: Set<String> = []
}

extension EnvironmentValues {
    var dayLibrary: DayLibraryContext {
        get { self[LibraryContextKey.self] }
        set { self[LibraryContextKey.self] = newValue }
    }
}

struct DayPhotoControls: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Environment(\.dayPhotoActions) private var actions
    @Environment(\.dayLibrary) private var libraryContext
    @Binding var enabled: Bool
    let library: DayPhotoLibrary
    @State private var choose = false
    @State private var permission = false
    @State private var denied = false
    @State private var failed = false

    private var pending: [PHAsset] {
        library.pending.filter { !libraryContext.excluded.contains($0.localIdentifier) }
    }

    var body: some View {
        HStack {
            if enabled && (library.authorization == .authorized || library.authorization == .limited) {
                Menu {
                    Button("关闭自动关联") { enabled = false }
                    if library.authorization == .limited {
                        Button("管理可见照片") { settings() }
                    }
                } label: {
                    Label(library.authorization == .limited ? "已关联可见照片" : "已关联当天照片", systemImage: "photo.on.rectangle")
                }
                Spacer()
                if !pending.isEmpty { Button("待选照片（\(pending.count)）") { choose = true } }
            } else {
                Button { permission = true } label: { Label("显示当天照片", systemImage: "photo.on.rectangle") }
            }
        }
        .font(.subheadline)
        .frame(minHeight: 44)
        .alert("关联当天拍摄的照片？", isPresented: $permission) {
            Button("取消", role: .cancel) {}
            Button("继续") {
                Task {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    if status == .authorized || status == .limited { enabled = true; library.revision &+= 1 }
                    else { denied = true }
                }
            }
        } message: { Text("Life Mem 在本机根据拍摄时间和可用的位置关联照片。你可以只允许部分照片，随时关闭。") }
        .alert("没有照片访问权限", isPresented: $denied) {
            Button("好", role: .cancel) {}
            Button("打开设置") { settings() }
        } message: { Text("仍可在停留或行程中手选照片。") }
        .sheet(isPresented: $choose) {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 92))], spacing: 8) {
                        ForEach(pending, id: \.localIdentifier) { asset in
                            Menu {
                                ForEach(actions.entries.filter { $0.memoryKey != nil }) { entry in
                                    Button(actions.name(entry) + " · " + clockRange(entry.startedAt, entry.endedAt)) {
                                        assign(asset, to: entry)
                                    }
                                }
                            } label: {
                                LibraryImage(asset: asset, fullSize: false)
                                    .frame(height: 88).clipShape(.rect(cornerRadius: 8))
                            }.accessibilityLabel("为照片选择记录")
                        }
                    }.padding()
                }
                .overlay { if pending.isEmpty { ContentUnavailableView("没有待选照片", systemImage: "photo") } }
                .navigationTitle("待选照片")
                .toolbar { Button("完成") { choose = false } }
                .alert("未能保存关联", isPresented: $failed) { Button("好") {} }
            }
        }
    }

    private func settings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func assign(_ asset: PHAsset, to entry: RouteReviewEntry) {
        guard let key = entry.memoryKey else { return }
        do {
            try key.update(in: context.container) { memory, writer in
                let photo = try memory.attachment(for: asset.localIdentifier, in: writer)
                photo.hidden = false
            }
        } catch { failed = true }
    }
}

struct LibraryImage: View {
    let asset: PHAsset
    let fullSize: Bool
    var fitPreview = false
    @State private var image: UIImage?
    @State private var unavailable = false
    @State private var request: PHImageRequestID?
    @State private var token = UUID()

    var body: some View {
        GeometryReader { geo in
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fullSize || fitPreview ? .fit : .fill)
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            } else {
                VStack {
                    Image(systemName: unavailable ? "icloud" : "photo")
                    if fullSize && unavailable { Text("原图在本机不可用，可在系统照片中下载后重试。").font(.footnote) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
            }
        }
        .onAppear { load() }
        .onChange(of: asset) { load() }
        .onDisappear { cancel() }
    }

    private func cancel() {
        token = UUID()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
        image = nil
    }

    private func load() {
        cancel()
        unavailable = false
        let current = token
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        let size = fullSize ? 2048 : 320
        request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size, height: size),
                                                         contentMode: fullSize || fitPreview ? .aspectFit : .aspectFill, options: options) { value, info in
            DispatchQueue.main.async {
                guard token == current else { return }
                if let value { image = value }
                if info?[PHImageResultIsDegradedKey] as? Bool != true { unavailable = value == nil }
            }
        }
    }
}
