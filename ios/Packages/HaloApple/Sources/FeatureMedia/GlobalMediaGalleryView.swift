#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// Global Media Gallery screen opened from the preset non-Matrix room entry in the room list (D34, D83).
public struct GlobalMediaGalleryView: View {
    @Bindable private var model: GlobalMediaGalleryViewModel
    private let onJumpToMessage: (RoomID, EventID) -> Void
    @State private var selectedItem: GlobalMediaItem?

    public init(
        model: GlobalMediaGalleryViewModel,
        onJumpToMessage: @escaping (RoomID, EventID) -> Void = { _, _ in }
    ) {
        self.model = model
        self.onJumpToMessage = onJumpToMessage
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

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
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                Picker("Media filter", selection: $model.filter) {
                    ForEach(GlobalMediaFilter.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 6)

                if let error = model.error {
                    Text(error)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.danger)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }
            .background(.bar)
        }
        .navigationTitle("Media Gallery")
        .searchable(text: $model.searchText, prompt: "Search photos, files, rooms")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                roomFilterMenu
            }
            #else
            ToolbarItem(placement: .primaryAction) {
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
                loadImageData: { media in
                    guard let target = byID[media.id], let source = target.item.attachment.source else { return nil }
                    return await model.fullImageData(source)
                },
                exportItem: { media in
                    guard let target = byID[media.id] else { return nil }
                    return await model.exportMediaFile(target)
                },
                onJumpToMessage: { media in
                    guard let target = byID[media.id] else { return }
                    selectedItem = nil
                    onJumpToMessage(target.roomID, target.item.eventID)
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
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter by room")
        .accessibilityIdentifier("global-media-room-filter")
    }

    private var mediaGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
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
                                    GlobalMediaGridTile(entry: entry) { ref in
                                        await model.thumbnailData(ref, size: 240)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(entry.item.attachment.body), \(entry.roomName)")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("global-media-grid")
    }

    private var filesList: some View {
        List {
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
                    }
                }
            }
        }
        .accessibilityIdentifier("global-media-files")
    }
}

private struct GlobalMediaGridTile: View {
    let entry: GlobalMediaItem
    let load: @MainActor (MediaRef) async -> Data?
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
        ZStack {
            Color.secondary.opacity(0.12)
            #if canImport(UIKit)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
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
            guard let previewRef else { return }
            data = await load(previewRef)
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
