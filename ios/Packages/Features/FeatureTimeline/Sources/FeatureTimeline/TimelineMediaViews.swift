#if canImport(SwiftUI)
import HaloBotRendering
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ThumbnailSize: ViewModifier {
    let isSticker: Bool
    let aspectRatio: Double?

    func body(content: Content) -> some View {
        if isSticker {
            content.frame(width: 160, height: 160)  // FR-8 allows up to 256 pt; 160 keeps a sticker from filling the screen
        } else {
            content.aspectRatio(aspectRatio ?? 4 / 3, contentMode: .fit).frame(maxWidth: 240)
        }
    }
}

struct ThumbnailView: View {
    let image: TimelineRow.Image
    let model: TimelineViewModel
    var isSticker = false
    @State private var data: Data?
    /// An animated sticker's full file, played in place of the still thumbnail (STICKERS FR-8).
    @State private var animated: Data?
    /// The download finished without a usable picture (missing on the server, offline, not an image): no endless spinner.
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            #if canImport(UIKit)
            if !isSticker, !model.showsPreview(of: image) {
                // FR-7: the account's media preview setting asks for a tap first; nothing is downloaded until then.
                Button { model.revealPreview(of: image) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.title2)
                        Text("Tap to show photo").font(.footnote)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.secondary.opacity(0.15))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("show-photo")
            } else if let animated {
                AnimatedStickerView(data: animated).allowsHitTesting(false)
            } else if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().scaledToFit()
            } else if failed {
                Button { failed = false; attempt += 1 } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(isSticker ? "Sticker couldn't be loaded" : "Photo couldn't be loaded").font(.footnote)
                        Text("Tap to try again").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.secondary.opacity(0.15))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("media-failed")
            } else {
                ZStack {
                    if let hash = image.blurhash, let decoded = BlurHashDecoder.decode(hash, width: 24, height: 24) {
                        RGBAPlaceholderImage(width: decoded.width, height: decoded.height, rgba: decoded.rgba)
                    } else {
                        Rectangle().fill(.secondary.opacity(0.2))
                    }
                    ProgressView()
                }
            }
            #else
            Rectangle().fill(.secondary.opacity(0.2))
            #endif
        }
        .modifier(ThumbnailSize(isSticker: isSticker, aspectRatio: image.aspectRatio))
        .clipShape(.rect(cornerRadius: isSticker ? 0 : 12))
        .task(id: LoadKey(shown: model.showsPreview(of: image), attempt: attempt)) {
            guard isSticker || model.showsPreview(of: image) else { return }
            let loaded = await model.thumbnail(for: image)
            guard !Task.isCancelled else { return }
            data = loaded
            #if canImport(UIKit)
            failed = loaded.flatMap(UIImage.init(data:)) == nil
            // A sticker may be a GIF or animated WebP: fetch the whole file and play it, unless motion is reduced.
            if isSticker, !failed, StickerImage.motionAllowed, let full = await model.stickerContent(for: image), StickerImage.isAnimated(full) {
                animated = full
            }
            #endif
        }
    }

    private struct LoadKey: Equatable {
        let shown: Bool
        let attempt: Int
    }
}

/// Native emoji reaction picker: system emoji keyboard input + recent emoji + searchable categories.

struct FileTileView: View {
    let file: TimelineRow.FileTile
    let isOpening: Bool
    let model: TimelineViewModel
    let open: () -> Void

    private var symbol: String {
        switch file.kind {
        case .audio: "waveform"
        case .video: "play.rectangle"
        default: "doc"
        }
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
            if let thumbnail = file.thumbnail {
                ThumbnailView(image: thumbnail, model: model)
                    .overlay { Image(systemName: "play.circle.fill").font(.largeTitle).imageScale(.large).foregroundStyle(HaloColor.mediaOverlayForeground).shadow(radius: 4) }
            }
            HStack(spacing: 10) {
                if isOpening { ProgressView() } else { Image(systemName: symbol).font(.title2) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.subheadline).lineLimit(2)
                    if !file.detail.isEmpty { Text(file.detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            }
            .padding(10)
            .frame(maxWidth: 260, alignment: .leading)
            .background(.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .accessibilityLabel(file.name)
        .accessibilityHint("Opens the file")
    }
}

/// `.task(id:)` re-runs when either value changes: more rows (keep paginating until the screen is full) or becoming ready.
#endif
