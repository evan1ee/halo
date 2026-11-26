import HaloDesignSystem
import HaloDomain
import SwiftUI

/// Room media gallery for photos, videos, audio and files with share/export (M9 Gallery + Export).
public struct RoomMediaGalleryView: View {
    private let model: RoomDetailsViewModel
    @State private var filter: MediaFilter = .all
    @State private var exportingItemID: String?
    @State private var exportedURL: URL?

    private enum MediaFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case photos = "Photos & Videos"
        case files = "Files & Audio"
        var id: String { rawValue }
    }

    public init(model: RoomDetailsViewModel) { self.model = model }

    private var filteredItems: [RoomMediaItem] {
        switch filter {
        case .all:
            return model.galleryItems
        case .photos:
            return model.galleryItems.filter { $0.attachment.kind == .image || $0.attachment.kind == .video }
        case .files:
            return model.galleryItems.filter { $0.attachment.kind == .file || $0.attachment.kind == .audio }
        }
    }

    public var body: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let error = model.galleryError {
                Section {
                    Text(error).foregroundStyle(HaloColor.danger).font(HaloTypography.meta)
                }
            }
            if let exportedURL {
                Section {
                    ShareLink(item: exportedURL) {
                        Label("Share \(exportedURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                ForEach(filteredItems) { item in
                    HStack(spacing: 12) {
                        GalleryThumbnail(item: item) { await model.avatarData($0) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.attachment.body).font(.subheadline).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(item.senderName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let size = item.attachment.size {
                                    Text("· \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        if item.attachment.source != nil {
                            Button {
                                exportingItemID = item.id
                                Task {
                                    exportedURL = await model.exportMediaFile(item)
                                    exportingItemID = nil
                                }
                            } label: {
                                if exportingItemID == item.id {
                                    ProgressView()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Export \(item.attachment.body)")
                        }
                    }
                }
            }
        }
        .overlay {
            if model.isLoadingGallery && model.galleryItems.isEmpty {
                ProgressView()
            } else if filteredItems.isEmpty && model.galleryError == nil {
                ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle.angled")
            }
        }
        .navigationTitle("Media & Files")
        .task {
            if model.galleryItems.isEmpty {
                await model.loadGallery()
            }
        }
        .refreshable {
            await model.loadGallery()
        }
    }
}

private struct GalleryThumbnail: View {
    let item: RoomMediaItem
    let load: @MainActor (MediaRef) async -> Data?
    @State private var data: Data?

    private var previewRef: MediaRef? {
        switch item.attachment.kind {
        case .image: return item.attachment.source
        case .video: return item.attachment.thumbnail
        case .audio, .file: return nil
        }
    }

    private var symbol: String {
        switch item.attachment.kind {
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .file: "doc"
        }
    }

    var body: some View {
        Group {
            #if canImport(UIKit)
            DecodedImage(data, maxPixel: ImagePipeline.Size.listRow) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } placeholder: { placeholder }
            #else
            placeholder
            #endif
        }
        .task(id: previewRef) {
            data = nil
            guard let previewRef else { return }
            data = await load(previewRef)
        }
    }

    private var placeholder: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
