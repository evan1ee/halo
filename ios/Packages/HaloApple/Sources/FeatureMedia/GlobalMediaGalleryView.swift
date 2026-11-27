#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// Global Media Gallery screen opened from the preset non-Matrix room entry in the room list (D34, D83).
public struct GlobalMediaGalleryView: View {
    @Bindable private var model: GlobalMediaGalleryViewModel
    private let onJumpToMessage: (RoomID, EventID) -> Void
    private let onSaveAsSticker: (@MainActor (Data, String) -> Void)?
    @State private var selectedItem: GlobalMediaItem?
    @State private var visibleSectionIDs: Set<String> = []

    public init(
        model: GlobalMediaGalleryViewModel,
        onJumpToMessage: @escaping (RoomID, EventID) -> Void = { _, _ in },
        onSaveAsSticker: (@MainActor (Data, String) -> Void)? = nil
    ) {
        self.model = model
        self.onJumpToMessage = onJumpToMessage
        self.onSaveAsSticker = onSaveAsSticker
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    private var currentDateTitle: String {
        if let active = model.sections.first(where: { visibleSectionIDs.contains($0.id) }) {
            return active.title
        }
        return model.sections.first?.title ?? "Media"
    }

    public var body: some View {
        Group {
            if model.filter == .files {
                filesList
            } else {
                mediaGrid
            }
        }
        .overlay {
            if model.isLoading && model.items.isEmpty {
                ProgressView("Loading media…")
            } else if model.filteredItems.isEmpty && model.error == nil {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(emptyDescription)
                )
            }
        }
        .navigationTitle("")
        .searchable(text: $model.searchText, prompt: "Search photos, files, rooms")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(currentDateTitle)
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: currentDateTitle)
                    .padding(.horizontal, HaloSpacing.m)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                fileTypeFilterMenu
                roomFilterMenu
            }
            #else
            ToolbarItemGroup(placement: .primaryAction) {
                fileTypeFilterMenu
                roomFilterMenu
            }
            #endif
        }
        .sheet(item: $selectedItem) { entry in
            let list = model.filteredItems.isEmpty ? [entry] : model.filteredItems
            let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            let items = list.map { item -> PagedMediaItem in
                let symbol: String = switch item.item.attachment.kind {
                case .image: "photo"
                case .video: "video.fill"
                case .audio: "waveform"
                case .file: "doc.fill"
                }
                return PagedMediaItem(
                    id: item.id,
                    title: item.item.attachment.body,
                    caption: "\(item.roomName) · \(item.item.senderName)",
                    fallbackSymbol: symbol,
                    isImage: item.item.attachment.kind == .image
                )
            }
            PagedPhotoViewer(
                items: items,
                initialID: entry.id,
                loadImageFile: { media in
                    guard let target = byID[media.id] else { return nil }
                    return await model.fullImageFile(target)
                },
                exportItem: { media in
                    guard let target = byID[media.id] else { return nil }
                    return await model.exportMediaFile(target)
                },
                onJumpToMessage: { media in
                    guard let target = byID[media.id] else { return }
                    selectedItem = nil
                    onJumpToMessage(target.roomID, target.item.eventID)
                },
                onSaveAsSticker: onSaveAsSticker.map { save in
                    { data, filename in
                        selectedItem = nil
                        save(data, filename)
                    }
                }
            )
        }
        .task {
            if model.items.isEmpty {
                await model.load()
            }
        }
        .refreshable {
            await model.load()
        }
        .onDisappear {
            Task { await model.closeSessions() }
        }
    }

    private var emptyTitle: String {
        switch model.filter {
        case .all: "No media yet"
        case .photos: "No photos yet"
        case .videos: "No videos yet"
        case .files: "No files or audio yet"
        }
    }

    private var emptyDescription: String {
        if model.selectedRoomID != nil {
            return "Try switching the room filter or pulling to refresh."
        }
        return "Photos, videos, and files from your rooms will appear here."
    }

    @ViewBuilder
    private var fileTypeFilterMenu: some View {
        Menu {
            ForEach(GlobalMediaFilter.allCases) { kind in
                Button {
                    model.filter = kind
                } label: {
                    if model.filter == kind {
                        Label(kind.rawValue, systemImage: "checkmark")
                    } else {
                        Label(kind.rawValue, systemImage: Self.filterSymbol(for: kind))
                    }
                }
            }
        } label: {
            Image(systemName: Self.filterButtonSymbol(for: model.filter))
                .foregroundStyle(model.filter == .all ? HaloColor.textPrimary : HaloColor.accent)
        }
        .accessibilityLabel("Filter by type")
        .accessibilityIdentifier("global-media-type-filter")
    }

    private static func filterSymbol(for kind: GlobalMediaFilter) -> String {
        switch kind {
        case .all: "photo.on.rectangle.angled"
        case .photos: "photo"
        case .videos: "video"
        case .files: "doc"
        }
    }

    private static func filterButtonSymbol(for kind: GlobalMediaFilter) -> String {
        switch kind {
        case .all: "photo.on.rectangle.angled"
        case .photos: "photo.fill"
        case .videos: "video.fill"
        case .files: "doc.fill"
        }
    }

    @ViewBuilder
    private var roomFilterMenu: some View {
        Menu {
            Button {
                model.selectedRoomID = nil
            } label: {
                if model.selectedRoomID == nil {
                    Label("All Rooms", systemImage: "checkmark")
                } else {
                    Text("All Rooms")
                }
            }
            if !model.availableRooms.isEmpty {
                Divider()
                ForEach(model.availableRooms, id: \.id) { room in
                    Button {
                        model.selectedRoomID = room.id
                    } label: {
                        if model.selectedRoomID == room.id {
                            Label(room.name, systemImage: "checkmark")
                        } else {
                            Text(room.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: model.selectedRoomID == nil
                ? "bubble.left.and.bubble.right"
                : "bubble.left.and.bubble.right.fill")
                .foregroundStyle(model.selectedRoomID == nil ? HaloColor.textPrimary : HaloColor.accent)
        }
        .accessibilityLabel("Filter by room")
        .accessibilityIdentifier("global-media-room-filter")
    }

    private var mediaGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let error = model.error {
                    Text(error)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.danger)
                        .padding(.horizontal)
                }
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                            .padding(.horizontal)
                        LazyVGrid(columns: gridColumns, spacing: 2) {
                            ForEach(section.items) { entry in
                                Button {
                                    selectedItem = entry
                                } label: {
                                    GlobalMediaGridTile(entry: entry) {
                                        await model.thumbnailData(for: entry.item.attachment, size: 400)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(entry.item.attachment.body), \(entry.roomName)")
                            }
                        }
                    }
                    .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                        if isVisible {
                            visibleSectionIDs.insert(section.id)
                        } else {
                            visibleSectionIDs.remove(section.id)
                        }
                    }
                }
                if model.hasMore {
                    HStack {
                        Spacer()
                        if model.isLoadingMore {
                            ProgressView()
                                .accessibilityLabel("Loading more media")
                        } else {
                            Button("Load more") {
                                Task { await model.loadMore() }
                            }
                            .accessibilityIdentifier("global-media-load-more")
                        }
                        Spacer()
                    }
                    .padding(.vertical, HaloSpacing.m)
                    .onAppear {
                        Task { await model.loadMore() }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        #if os(iOS)
        .scrollEdgeEffectHidden(true, for: .top)
        #endif
        .accessibilityIdentifier("global-media-grid")
    }

    private var filesList: some View {
        List {
            if let error = model.error {
                Section {
                    Text(error)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.danger)
                }
            }
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { entry in
                        Button {
                            selectedItem = entry
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.item.attachment.kind == .audio ? "waveform" : "doc.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, height: 40)
                                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.item.attachment.body)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(entry.roomName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text("· \(entry.item.senderName)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let size = entry.item.attachment.size {
                                            Text("· \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear { visibleSectionIDs.insert(section.id) }
                        .onDisappear { visibleSectionIDs.remove(section.id) }
                    }
                }
            }
            if model.hasMore {
                Section {
                    HStack {
                        Spacer()
                        if model.isLoadingMore {
                            ProgressView()
                                .accessibilityLabel("Loading more media")
                        } else {
                            Button("Load more") {
                                Task { await model.loadMore() }
                            }
                            .accessibilityIdentifier("global-media-files-load-more")
                        }
                        Spacer()
                    }
                    .onAppear {
                        Task { await model.loadMore() }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollEdgeEffectHidden(true, for: .top)
        #endif
        .accessibilityIdentifier("global-media-files")
    }
}

private struct GlobalMediaGridTile: View {
    let entry: GlobalMediaItem
    let load: @MainActor () async -> Data?
    @State private var data: Data?

    private var previewRef: MediaRef? {
        switch entry.item.attachment.kind {
        case .image: entry.item.attachment.thumbnail ?? entry.item.attachment.source
        case .video: entry.item.attachment.thumbnail
        case .audio, .file: nil
        }
    }

    private var symbol: String {
        switch entry.item.attachment.kind {
        case .image: "photo"
        case .video: "video.fill"
        case .audio: "waveform"
        case .file: "doc.fill"
        }
    }

    var body: some View {
        HaloColor.bgSecondary
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                #if canImport(UIKit)
                DecodedImage(data, maxPixel: ImagePipeline.Size.gridCell) { image in
                    image.resizable().scaledToFill()
                } placeholder: { placeholder }
                #else
                placeholder
                #endif
            }
            .clipped()
            .contentShape(.rect)
            .overlay(alignment: .bottomTrailing) {
                if entry.item.attachment.kind == .video {
                    Image(systemName: "video.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HaloColor.mediaOverlayForeground)
                        .padding(4)
                        .background(HaloColor.mediaOverlayBackground, in: RoundedRectangle(cornerRadius: HaloRadius.small))
                        .padding(4)
                }
            }
            .task(id: previewRef) {
                data = nil
                guard previewRef != nil else { return }
                data = await load()
            }
    }

    private var placeholder: some View {
        ZStack {
            if let hash = entry.item.attachment.blurhash,
               let decoded = BlurHashDecoder.decode(hash, width: 24, height: 24) {
                RGBAPlaceholderImage(width: decoded.width, height: decoded.height, rgba: decoded.rgba)
            }
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if entry.item.attachment.kind == .file || entry.item.attachment.kind == .audio {
                    Text(entry.item.attachment.body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
            }
        }
    }
}
#endif
