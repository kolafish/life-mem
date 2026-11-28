import CoreLocation
import ImageIO
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PhotoMapRequest: Identifiable {
    let id = UUID()
    let entryID: RouteReviewEntry.ID
    let coordinate: CLLocationCoordinate2D?
}

struct DayPhotoActions {
    var pick: (RouteMemoryKey) -> Void = { _ in }
    var importing = false
    var entries: [RouteReviewEntry] = []
    var name: (RouteReviewEntry) -> String = { _ in "" }
    var showMap: (PhotoMapRequest) -> Void = { _ in }
}

private struct DayPhotoKey: EnvironmentKey {
    static let defaultValue = DayPhotoActions()
}
extension EnvironmentValues {
    var dayPhotoActions: DayPhotoActions {
        get { self[DayPhotoKey.self] }
        set { self[DayPhotoKey.self] = newValue }
    }
}

private struct ImportedImage: Transferable {
    let image: Data
    let thumbnail: Data
    let taken: Date?
    let coordinate: CLLocationCoordinate2D?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            try ImportedImage(url: file.file)
        }
    }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        func jpeg(edge: Int) throws -> Data {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                           kCGImageSourceThumbnailMaxPixelSize: edge]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, primary, options as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            let bytes = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(output, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
            return bytes as Data
        }
        image = try jpeg(edge: 2304)
        thumbnail = try jpeg(edge: 320)
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, primary, nil) as? [CFString: Any]
        let gps = metadata?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        if let lat = gps?[kCGImagePropertyGPSLatitude] as? Double, let lon = gps?[kCGImagePropertyGPSLongitude] as? Double,
           let ns = gps?[kCGImagePropertyGPSLatitudeRef] as? String, let ew = gps?[kCGImagePropertyGPSLongitudeRef] as? String {
            let point = CLLocationCoordinate2D(latitude: ns == "S" ? -lat : lat, longitude: ew == "W" ? -lon : lon)
            coordinate = CLLocationCoordinate2DIsValid(point) ? point : nil
        } else { coordinate = nil }
        let exif = metadata?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let zone = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            taken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap { formatter.date(from: $0 + zone) }
        } else {
            taken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap { formatter.date(from: $0) }
        }
    }
}

struct EntryPhotosView: View {
    @Environment(\.dayPhotoActions) private var actions
    let entry: RouteReviewEntry
    @Query private var attachments: [MemoryPhoto]
    let selected: Bool
    @State private var viewing: MemoryPhoto?
    @State private var mapRequest: PhotoMapRequest?

    init(entry: RouteReviewEntry, key: RouteMemoryKey, selected: Bool) {
        self.entry = entry
        self.selected = selected
        let value = key.value
        _attachments = Query(filter: #Predicate<MemoryPhoto> { !$0.hidden && $0.memory?.key == value })
    }

    private var photos: [MemoryPhoto] {
        attachments.sorted { ($0.taken ?? $0.added) < ($1.taken ?? $1.added) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !photos.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(photos.prefix(3))) { photo in
                        Button { viewing = photo } label: {
                            GeometryReader { area in
                                if let data = photo.thumbnail, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: area.size.width, height: area.size.height).clipped()
                                }
                            }
                            .frame(height: 78)
                            .clipShape(.rect(cornerRadius: 9))
                            .overlay(alignment: .bottomTrailing) {
                                if photos.count > 3 && photo.id == photos[2].id {
                                    Text("+\(photos.count - 3)").font(.caption.bold()).padding(4).foregroundStyle(.white).background(.black.opacity(0.65), in: .capsule)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看照片")
                    }
                }
            }
            if selected {
                Button {
                    if let key = entry.memoryKey { actions.pick(key) }
                } label: {
                    Label(actions.importing ? "正在添加照片" : "添加照片", systemImage: "photo.badge.plus")
                        .font(.subheadline).frame(minHeight: 44)
                }
                .disabled(actions.importing)
            }
        }
        .sheet(item: $viewing, onDismiss: {
            if let request = mapRequest { mapRequest = nil; actions.showMap(request) }
        }) { photo in
            MemoryPhotoViewer(entry: entry, photos: photos, first: photo) { request in
                mapRequest = request
                viewing = nil
            }
        }
    }
}

// Keep the picker on the visible presentation, independent of recycled timeline rows.
struct DayPhotoPicker: ViewModifier {
    @Environment(\.modelContext) private var context
    @State private var destination: RouteMemoryKey?
    @State private var showing = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .transformEnvironment(\.dayPhotoActions) { actions in
                actions.importing = importing
                actions.pick = { key in
                    destination = key
                    showing = true
                }
            }
            .photosPicker(isPresented: $showing, selection: $picked, maxSelectionCount: nil,
                          selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current,
                          photoLibrary: .shared())
            .onChange(of: picked) { _, items in
                guard !items.isEmpty, !importing, let destination else { return }
                importing = true
                Task { await add(items, to: destination) }
            }
            .alert("照片未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: { Text(error ?? "") }
    }

    @MainActor private func add(_ items: [PhotosPickerItem], to key: RouteMemoryKey) async {
        defer { picked = []; importing = false }
        var failures = 0
        for item in items {
            do {
                guard let imported = try await item.loadTransferable(type: ImportedImage.self) else { throw CocoaError(.fileReadUnknown) }
                try key.update(in: context.container) { memory, writer in
                    let photo = try memory.attachment(for: item.itemIdentifier, in: writer)
                    photo.hidden = false
                    photo.image = imported.image
                    photo.thumbnail = imported.thumbnail
                    photo.taken = imported.taken
                    photo.latitude = imported.coordinate?.latitude
                    photo.longitude = imported.coordinate?.longitude
                }
            } catch { failures += 1 }
        }
        if failures > 0 { error = "有 \(failures) 张照片未能添加，请检查照片是否可读取及手机可用空间，然后重新选择。" }
    }
}

private struct MemoryPhotoViewer: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dayPhotoActions) private var actions
    @Environment(\.dismiss) private var dismiss
    let entry: RouteReviewEntry
    let photos: [MemoryPhoto]
    let onMap: (PhotoMapRequest) -> Void
    @State private var selection: UUID
    @State private var moving = false
    @State private var closeAfterMove = false
    @State private var failed = false

    init(entry: RouteReviewEntry, photos: [MemoryPhoto], first: MemoryPhoto, onMap: @escaping (PhotoMapRequest) -> Void) {
        self.entry = entry
        self.photos = photos
        self.onMap = onMap
        _selection = State(initialValue: first.id)
    }

    var body: some View {
        NavigationStack {
            VStack {
                TabView(selection: $selection) {
                    ForEach(photos) { item in
                        Group {
                            if let data = item.id == selection ? item.image : item.thumbnail, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("照片")
                            } else { ContentUnavailableView("照片不可用", systemImage: "photo") }
                        }.tag(item.id)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
                if let i = photos.firstIndex(where: { $0.id == selection }) {
                    let photo = photos[i]
                    Text("\(i + 1) / \(photos.count)").font(.caption.monospacedDigit())
                    if let taken = photo.taken { Text(taken.formatted()).font(.caption).foregroundStyle(.secondary) }
                    Button(photo.coordinate == nil ? "在地图上看这段记录" : "在地图上看拍摄位置") {
                        onMap(.init(entryID: entry.id, coordinate: photo.coordinate))
                    }.frame(minHeight: 44)
                }
            }
            .navigationTitle(actions.name(entry)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("移到其他记录") { moving = true }
                        Button("从记录中隐藏") { change(to: nil) }
                    } label: { Label("照片选项", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $moving, onDismiss: { if closeAfterMove { dismiss() } }) {
                NavigationStack {
                    List(actions.entries.filter { $0.memoryKey != nil && $0.memoryKey != entry.memoryKey }) { other in
                        Button { change(to: other.memoryKey) } label: {
                            ReviewTextRow(title: actions.name(other), detail: clockRange(other.startedAt, other.endedAt))
                        }
                    }
                    .overlay {
                        if !actions.entries.contains(where: { $0.memoryKey != nil && $0.memoryKey != entry.memoryKey }) {
                            ContentUnavailableView("当天没有其他可选记录", systemImage: "list.bullet")
                        }
                    }
                    .navigationTitle("移到哪段记录")
                    .toolbar { Button("取消") { moving = false } }
                }
            }
            .alert("未能更新照片，请检查可用空间后重试", isPresented: $failed) { Button("好") {} }
        }
    }

    private func change(to target: RouteMemoryKey?) {
        guard let selected = photos.first(where: { $0.id == selection }), let key = target ?? entry.memoryKey else { return }
        let id = selected.id
        do {
            try key.update(in: context.container) { destination, writer in
                guard let photo = try writer.fetch(FetchDescriptor<MemoryPhoto>(predicate: #Predicate { $0.id == id })).first
                else { throw VisitCorrection.Failure.sourceUnavailable }
                if target != nil { try photo.move(to: destination, in: writer) }
                else { photo.hide(in: writer) }
            }
            if moving { closeAfterMove = true; moving = false } else { dismiss() }
        } catch { failed = true }
    }
}
