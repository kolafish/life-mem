import SwiftData
import SwiftUI

struct JournalLink: View {
    let day: RouteReviewDay?
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: { Label("当日日记", systemImage: "book.pages") }
            .accessibilityIdentifier("open-journal")
            .sheet(isPresented: $presented) {
                NavigationStack {
                    Group {
                        if let day { DailyJournal(day: day) }
                        else {
                            ContentUnavailableView("今天的日记还是空白", systemImage: "book",
                                                   description: Text("有了第一段轨迹，就会在这里生成今天的日记。"))
                        }
                    }
                    .navigationTitle("当日日记").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presented = false } } }
                }
            }
    }
}

private struct DailyJournal: View {
    let day: RouteReviewDay
    @Environment(\.currentRouteReview) private var review
    @Environment(RoutePlaceNames.self) private var names
    @Environment(PlaceResolver.self) private var resolver
    @State private var library = DayPhotoLibrary()
    @AppStorage("matchDayPhotos") private var matchPhotos = false
    @State private var playback = MemoPlayback()
    @State private var mapFocus = UUID()

    var body: some View {
        let dates = day.journalAttachmentDays(in: review?.days ?? [day])
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(day.date.formatted(.dateTime.year().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(day.date.formatted(.dateTime.month(.wide).day().locale(Locale(identifier: "zh_CN"))))
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(day.journalSummary { resolver.label(near: $0, names: names) })
                        .font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    RouteMapContainer(entries: day.entries, selected: nil, focusRequest: mapFocus) { _ in }
                        .labelStyle(.iconOnly)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .frame(height: 172).clipShape(.rect(cornerRadius: 12))
                        .padding(.top, 2)
                }.padding(.bottom, 24)
                ForEach(day.entries) { entry in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 7) {
                            Divider()
                            Text(clockRange(entry.startedAt, entry.endedAt))
                                .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                                .padding(.top, 10)
                            Text(day.title(for: entry) { resolver.label(near: $0, names: names) })
                                .font(.system(.title3, design: .serif, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let key = entry.memoryKey {
                            JournalMemories(key: key, day: day.date, dates: dates[key] ?? [day.date], playback: playback)
                        }
                    }
                    .padding(.bottom, 18)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .modifier(DayPhotoSource(day: day, library: library, enabled: matchPhotos))
        .modifier(MemoPlaybackLifecycle(playback: playback))
    }
}

private struct JournalMemories: View {
    let key: RouteMemoryKey
    let day: Date
    let dates: [Date]
    let playback: MemoPlayback
    @Query private var memories: [RouteMemory]
    @Query private var attachments: [MemoryPhoto]
    @Environment(\.dayLibrary) private var library
    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var scheme
    @State private var selectedPhoto: GalleryPhoto?

    init(key: RouteMemoryKey, day: Date, dates: [Date], playback: MemoPlayback) {
        self.key = key
        self.day = day
        self.dates = dates
        self.playback = playback
        let value = key.value
        _memories = Query(filter: #Predicate<RouteMemory> { $0.key == value })
        _attachments = Query(filter: #Predicate<MemoryPhoto> { !$0.hidden && $0.memory?.key == value })
    }

    var body: some View {
        if let text = memories.first?.text, !text.isEmpty {
            Text(text).font(.body).lineSpacing(5).textSelection(.enabled).padding(.top, 8)
        }
        let photos = GalleryPhoto.visible(attachments: attachments, key: key, libraryContext: library)
        ForEach(photos.filter { RouteReviewDay.journalDay(for: $0.taken, on: dates, calendar: calendar) == day }, id: \.journalID) { photo in
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    playback.stop()
                    selectedPhoto = photo
                } label: {
                    photo.journalImage
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder((scheme == .dark ? Color.white : .black).opacity(0.10)) }
                }
                .buttonStyle(.plain).accessibilityLabel("查看照片和语音留言")
                if let saved = photo.saved, let duration = saved.voiceDuration {
                    MemoPlayButton(playback: playback, id: saved.id.uuidString, duration: duration) { saved.voiceAudio }
                    if let words = saved.voiceTranscript, !words.isEmpty {
                        Text(words).font(.body).lineSpacing(4).textSelection(.enabled)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) { Capsule().fill(.tint.opacity(0.38)).frame(width: 2) }
                            .accessibilityLabel("语音转写，\(words)")
                    }
                }
            }.padding(.top, 12)
        }
        .sheet(item: $selectedPhoto) { photo in PhotoVoiceEditor(photo: photo, key: key) }
    }
}

private extension GalleryPhoto {
    var journalID: String { saved?.id.uuidString ?? id }

    @ViewBuilder var journalImage: some View {
        if let asset {
            let ratio = CGFloat(asset.pixelWidth) / CGFloat(max(1, asset.pixelHeight))
            Color.clear.aspectRatio(min(2, max(0.8, ratio)), contentMode: .fit)
                .overlay { LibraryImage(asset: asset, fullSize: false, previewPixels: 1200) }.clipped()
        } else if let data = saved?.image, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Label("照片当前不可用", systemImage: "photo")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
                .background(Color(uiColor: .secondarySystemBackground))
        }
    }
}
