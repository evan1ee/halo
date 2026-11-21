import HaloDomain
import SwiftUI

/// The sticker panel: search, favourites, recents, then one section per pack. Tap sends; long-press previews (animated when motion is allowed) and offers send and favourite.
public struct StickerPanelView: View {
    let model: StickerPanelViewModel
    @State private var newPack: NewPackViewModel?

    public init(model: StickerPanelViewModel) { self.model = model }

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                TextField("Search stickers", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sticker-search")
                if model.canCreatePack {
                    Button { newPack = model.beginNewPack() } label: { Image(systemName: "plus.circle").font(.title2) }
                        .accessibilityLabel("New sticker pack")
                        .accessibilityIdentifier("new-pack")
                }
            }
            // Room for the sheet's drag indicator above the search field.
            .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 8)
            if let error = model.sendError { Text(error).font(.caption).foregroundStyle(.red) }
            if let notice = model.unavailableNotice {
                HStack(spacing: 8) {
                    Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("unavailable-packs")
                    Button("Remove") { Task { await model.removeUnavailablePacks() } }
                        .font(.caption.bold())
                        .accessibilityIdentifier("remove-unavailable-packs")
                }
            }
            if model.isIncomplete { Text("Some packs couldn't be loaded.").font(.caption).foregroundStyle(.secondary) }
            if let message = model.emptyMessage {
                Spacer()
                Text(message).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.isSearching {
                            grid(model.results)
                        } else {
                            section("Favourites", model.snapshot.favourites)
                            section("Recent", model.snapshot.recents)
                            ForEach(model.snapshot.packs) { pack in section(pack.displayName, pack.stickers) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        #if canImport(UIKit)
        .sheet(item: $newPack) { NewPackView(model: $0) }
        #endif
        .alert("Stickers aren't encrypted", isPresented: Binding(get: { model.pendingNotice != nil }, set: { if !$0 { model.cancelNotice() } })) {
            Button("Send anyway") { Task { await model.confirmNotice() } }
            Button("Cancel", role: .cancel) { model.cancelNotice() }
        } message: {
            Text("Your messages in this room are end-to-end encrypted, but this sticker's image is not. Sticker images are stored as ordinary media on your homeserver, so who can see them depends on the homeserver's media storage and access controls. This applies to sticker images only, not to your other messages.")
        }
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }

    @ViewBuilder private func section(_ title: String, _ stickers: [Sticker]) -> some View {
        if !stickers.isEmpty {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            grid(stickers)
        }
    }

    private func grid(_ stickers: [Sticker]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(stickers) { sticker in
                StickerCell(sticker: sticker, model: model)
            }
        }
    }
}

private struct StickerCell: View {
    let sticker: Sticker
    let model: StickerPanelViewModel
    @State private var data: Data?
    /// The full file of an animated sticker while its cell is on screen (FR-9); `nil` otherwise, so memory is freed on scroll.
    @State private var animated: Data?

    var body: some View {
        Button { Task { await model.tap(sticker) } } label: {
            Group {
                #if canImport(UIKit)
                // A UIKit view inside a button label takes the touch for itself, so the button never fired for animated stickers.
                if let animated { AnimatedStickerView(data: animated).allowsHitTesting(false) } else if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() } else { placeholder }
                #else
                placeholder
                #endif
            }
            .frame(width: 72, height: 72)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sticker.body ?? sticker.shortcode)
        .contextMenu(menuItems: {
            Button(model.isFavourite(sticker) ? "Remove from favourites" : "Add to favourites", systemImage: model.isFavourite(sticker) ? "star.slash" : "star") {
                Task { await model.toggleFavourite(sticker) }
            }
            Button("Send", systemImage: "paperplane") { Task { await model.tap(sticker) } }
        }, preview: { preview })
        .task { data = await model.thumbnail(for: sticker) }
        #if canImport(UIKit)
        .task(id: sticker.id) {
            // Autoplay only the visible cells, only when motion is allowed, and only small files (FR-9).
            guard StickerImage.motionAllowed, let full = await model.animatedContent(for: sticker) else { return }
            animated = full
        }
        .onDisappear { animated = nil }
        #endif
    }

    /// The long-press preview (FR-5): larger, animated when motion is allowed (FR-9); the full file loads while the thumbnail shows.
    private var preview: some View {
        StickerPreview(sticker: sticker, model: model, thumbnail: data)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.15)).overlay { Text(sticker.shortcode).font(.caption2).lineLimit(1).padding(2) }
    }
}

private struct StickerPreview: View {
    let sticker: Sticker
    let model: StickerPanelViewModel
    let thumbnail: Data?
    @State private var full: Data?

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let shown = full ?? thumbnail {
                AnimatedStickerView(data: shown)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.15))
            }
            #else
            RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.15))
            #endif
        }
        .frame(width: 240, height: 240)
        .padding()
        .task { full = await model.previewContent(for: sticker) }
    }
}
