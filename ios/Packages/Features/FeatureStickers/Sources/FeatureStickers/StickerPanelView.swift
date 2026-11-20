import HaloDomain
import SwiftUI

/// The sticker panel: search, favourites, recents, then one section per pack. Tap sends; long-press offers favourite.
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
            .padding(8)
            if let error = model.sendError { Text(error).font(.caption).foregroundStyle(.red) }
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

    var body: some View {
        Button { Task { await model.tap(sticker) } } label: {
            Group {
                #if canImport(UIKit)
                if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() } else { placeholder }
                #else
                placeholder
                #endif
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sticker.body ?? sticker.shortcode)
        .contextMenu {
            Button(model.isFavourite(sticker) ? "Remove from favourites" : "Add to favourites", systemImage: model.isFavourite(sticker) ? "star.slash" : "star") {
                Task { await model.toggleFavourite(sticker) }
            }
            Button("Send", systemImage: "paperplane") { Task { await model.tap(sticker) } }
        }
        .task { data = await model.thumbnail(for: sticker) }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.15)).overlay { Text(sticker.shortcode).font(.caption2).lineLimit(1).padding(2) }
    }
}
