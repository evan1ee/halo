#if canImport(SwiftUI)
import HaloBotRendering
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import PhotosUI
import ImageIO
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
            // The box has the announced shape (4:3 when the event has none) whether the placeholder or the picture is in it, so a
            // row never changes height when its picture loads: a lazy list that has to re-measure a row while it is being scrolled
            // to the newest message drops its measurements and lands near the top of the room (seen in S10).
            Color.clear
                .aspectRatio(aspectRatio ?? 4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { content }
                .contentShape(.rect)
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

    init(image: TimelineRow.Image, model: TimelineViewModel, isSticker: Bool = false) {
        self.image = image
        self.model = model
        self.isSticker = isSticker
        // A rebuilt view (scrolled back into view, list reset) paints the picture already loaded, on its first frame.
        _data = State(initialValue: model.cachedThumbnail(for: image))
    }

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
            } else if let data {
                // A photo fills its box (cropped when the event announced no size; the viewer shows all of it); a sticker fits.
                DecodedImage(data, maxPixel: isSticker ? ImagePipeline.Size.sticker : ImagePipeline.Size.timeline) { rendered in
                    if UIDevice.current.userInterfaceIdiom == .pad,
                       TimelineDragExtractor.allowsPhotoDrag(isSticker: isSticker, hasImageData: true) {
                        rendered.resizable().aspectRatio(contentMode: .fill)
                            .draggable(rendered)
                    } else {
                        rendered.resizable().aspectRatio(contentMode: isSticker ? .fit : .fill)
                    }
                } placeholder: { Rectangle().fill(.secondary.opacity(0.2)) }
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
            // A failed reload never blanks a picture that is already showing.
            if let loaded { data = loaded }
            #if canImport(UIKit)
            failed = data.flatMap(UIImage.init(data:)) == nil
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
    let cancel: () -> Void

    private var symbol: String {
        switch file.kind {
        case .audio: "waveform"
        case .video: "play.rectangle"
        default: "doc"
        }
    }

    private var openingDetail: String {
        if let size = file.size {
            return "Opening… · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
        return "Opening…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumbnail = file.thumbnail {
                Button(action: open) {
                    ThumbnailView(image: thumbnail, model: model)
                        .overlay {
                            if isOpening {
                                ProgressView()
                                    .tint(HaloColor.mediaOverlayForeground)
                                    .padding(HaloSpacing.s)
                                    .background(HaloColor.mediaOverlayBackground, in: .circle)
                            } else {
                                Image(systemName: "play.circle.fill")
                                    .font(.largeTitle)
                                    .imageScale(.large)
                                    .foregroundStyle(HaloColor.mediaOverlayForeground)
                                    .shadow(radius: 4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(isOpening)
                .accessibilityLabel(file.name)
                .accessibilityHint("Opens the file")
            }
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        if isOpening { ProgressView() } else { Image(systemName: symbol).font(.title2) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.subheadline).lineLimit(2)
                            if isOpening {
                                Text(openingDetail).font(.caption).foregroundStyle(.secondary)
                            } else if !file.detail.isEmpty {
                                Text(file.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isOpening)
                .accessibilityLabel(file.name)
                .accessibilityHint(isOpening ? "Opening file" : "Opens the file")

                if isOpening {
                    Spacer(minLength: 4)
                    Button(action: cancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel opening \(file.name)")
                    .accessibilityIdentifier("cancel-open-file")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
        .modifier(OptionalFileDragModifier(file: file, model: model))
    }
}

private struct OptionalFileDragModifier: ViewModifier {
    let file: TimelineRow.FileTile
    let model: TimelineViewModel

    func body(content: Content) -> some View {
        if TimelineDragExtractor.allowsFileDrag(size: file.size) {
            content.draggable(DraggedTimelineFile(filename: file.name) {
                try await model.downloadFileToTemp(file)
            })
        } else {
            content
        }
    }
}

/// `.task(id:)` re-runs when either value changes: more rows (keep paginating until the screen is full) or becoming ready.
#if canImport(UIKit)
/// A KLIPY GIF or sticker sent as a link (COMPOSER_PANELS §6, D98): played inline without a bubble, at most 220 pt,
/// loaded straight from KLIPY. Until it loads (or if it can't) the link is shown as text.
struct KlipyMessageMedia: View {
    let url: URL
    let model: TimelineViewModel
    @State private var aspect: Double?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        AsyncAnimatedImage(id: "\(url.absoluteString)#\(attempt)", maxPixelSize: 660, load: { [model, url] in await model.klipyMedia(url) }) {
            RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous)
                .fill(HaloColor.textSecondary.opacity(0.12))
                .overlay {
                    if failed {
                        // Tap to try again; a plain Button lets vertical list scrolls pass through without blocking.
                        Button { failed = false; attempt += 1 } label: {
                            Label("GIF didn't load. Tap to retry", systemImage: "arrow.clockwise")
                                .font(HaloTypography.caption)
                                .foregroundStyle(HaloColor.textSecondary)
                                .padding(HaloSpacing.s)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProgressView()
                    }
                }
        }
        .frame(width: 220, height: 220 / max(0.5, min(2, aspect ?? 1)))
        .clipShape(.rect(cornerRadius: HaloRadius.medium, style: .continuous))
        .task(id: attempt) {
            guard let data = await model.klipyMedia(url) else { failed = true; return }
            aspect = KlipyMessageMedia.aspectRatio(data)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "GIF from KLIPY, didn't load" : "GIF from KLIPY")
        .accessibilityIdentifier("klipy-message-media")
        .accessibilityValue(aspect != nil ? "loaded" : failed ? "failed" : "loading")
        .accessibilityAddTraits(failed ? .isButton : [])
    }

    /// Reads the size from the same file (the catalog's memory cache serves both, so it is downloaded once).
    static func aspectRatio(_ data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0
        else { return nil }
        return width / height
    }
}
#endif
#endif
