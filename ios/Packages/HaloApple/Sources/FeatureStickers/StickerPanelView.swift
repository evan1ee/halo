import HaloDomain
import HaloDesignSystem
import SwiftUI

/// The sticker panel: search, favourites, recents, then one section per pack. Tap sends; long-press previews (animated when motion is allowed) and offers send and favourite.
///
/// `embedded`: shown inside the composer's expression panel (COMPOSER_PANELS §5) instead of a sheet; sending keeps the panel
/// open like the keyboard, and the list leaves room at the bottom for the panel's tab pill.
public struct StickerPanelView: View {
    let model: StickerPanelViewModel
    let embedded: Bool
    @State private var newPack: NewPackViewModel?
    @Environment(\.dismiss) private var dismiss

    public init(model: StickerPanelViewModel, embedded: Bool = false) {
        self.model = model
        self.embedded = embedded
    }

    /// After a send: a sheet closes, an embedded panel stays.
    private func sent() { if !embedded { dismiss() } }

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search stickers", text: $model.query, axis: .vertical)
                        .lineLimit(1...2)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("sticker-search")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
                if model.canCreatePack {
                    Button { newPack = model.beginNewPack() } label: {
                        Image(systemName: "plus.circle")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("New sticker pack")
                    .accessibilityIdentifier("new-pack")
                }
            }
            // Room for the sheet's drag indicator above the search field.
            .padding(.horizontal, 12).padding(.top, embedded ? 8 : 28).padding(.bottom, 8)
            if let error = model.sendError {
                HStack(spacing: 8) {
                    Text(error).font(HaloTypography.caption).foregroundStyle(HaloColor.danger)
                    Spacer()
                    Button { model.dismissSendError() } label: { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            if let notice = model.unavailableNotice {
                HStack(spacing: 8) {
                    Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("unavailable-packs")
                    Button("Remove") { Task { await model.removeUnavailablePacks() } }
                        .font(.caption.bold())
                        .accessibilityIdentifier("remove-unavailable-packs")
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            if model.isIncomplete {
                Text("Some packs couldn't be loaded.").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            if model.isLoading {
                Spacer()
                ProgressView("Loading stickers…")
                Spacer()
            } else if model.emptyMessage != nil {
                if model.isSearching {
                    ContentUnavailableView.search(text: model.query)
                } else if model.snapshot.phase == .failed {
                    ContentUnavailableView {
                        Label("Couldn't load stickers", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Try again") { Task { await model.retryLoad() } }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No sticker packs yet", systemImage: "face.smiling")
                    } description: {
                        Text("Create a pack to send stickers here.")
                    } actions: {
                        if model.canCreatePack {
                            Button("New sticker pack") { newPack = model.beginNewPack() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                List {
                    if model.isSearching {
                        grid(model.results)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                    } else {
                        section("Favourites", model.snapshot.favourites)
                        section("Recent", model.snapshot.recents)
                        ForEach(model.snapshot.packs) { pack in section(pack.displayName, pack.stickers) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .contentMargins(.bottom, embedded ? 72 : 0, for: .scrollContent)
            }
        }
        .background(embedded ? Color.clear : HaloColor.bgPrimary)
        .presentationBackground(HaloColor.bgPrimary)
        #if canImport(UIKit)
        .sheet(item: $newPack) { NewPackView(model: $0) }
        #endif
        .alert("Stickers aren't encrypted", isPresented: Binding(get: { model.pendingNotice != nil }, set: { if !$0 { model.cancelNotice() } })) {
            Button("Send anyway") {
                Task { if await model.confirmNotice() { sent() } }
            }
            Button("Cancel", role: .cancel) { model.cancelNotice() }
        } message: {
            Text("Your messages in this room are end-to-end encrypted, but this sticker's image is not. Sticker images are stored as ordinary media on your homeserver, so who can see them depends on the homeserver's media storage and access controls. This applies to sticker images only, not to your other messages.")
        }
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }

    @ViewBuilder private func section(_ title: String, _ stickers: [Sticker]) -> some View {
        if !stickers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(HaloColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                grid(stickers)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(embedded ? Color.clear : HaloColor.bgPrimary)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
        }
    }

    private func grid(_ stickers: [Sticker]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(stickers) { sticker in
                StickerCell(sticker: sticker, model: model) { sent() }
            }
        }
    }
}

private struct StickerCell: View {
    let sticker: Sticker
    let model: StickerPanelViewModel
    let onSent: () -> Void
    @State private var data: Data?
    /// The full file of an animated sticker while its cell is on screen (FR-9); `nil` otherwise, so memory is freed on scroll.
    @State private var animated: Data?
    @State private var animationCell = UUID()

    var body: some View {
        Button { Task { if await model.tap(sticker) { onSent() } } } label: {
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
        .disabled(model.isSending)
        .accessibilityLabel(sticker.body ?? sticker.shortcode)
        .contextMenu(menuItems: {
            Button(model.isFavourite(sticker) ? "Remove from favourites" : "Add to favourites", systemImage: model.isFavourite(sticker) ? "star.slash" : "star") {
                Task { await model.toggleFavourite(sticker) }
            }
            Button("Send", systemImage: "paperplane") { Task { if await model.tap(sticker) { onSent() } } }
        }, preview: { preview })
        .task { data = await model.thumbnail(for: sticker) }
        #if canImport(UIKit)
        .task(id: sticker.id) {
            model.releaseAnimation(for: animationCell)
            animated = nil
            // Autoplay only the visible cells, only when motion is allowed, only small files, and at most 12 at once (FR-9, §5).
            guard StickerImage.motionAllowed, let full = await model.animatedContent(for: sticker, cell: animationCell) else { return }
            animated = full
        }
        .onDisappear {
            animated = nil
            model.releaseAnimation(for: animationCell)
        }
        #endif
    }

    /// The long-press preview (FR-5): larger, animated when motion is allowed (FR-9); the full file loads while the thumbnail shows.
    private var preview: some View {
        StickerPreview(sticker: sticker, model: model, thumbnail: data)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.secondary.opacity(0.15))
            .overlay {
                Text(sticker.shortcode)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(2)
            }
            .accessibilityHidden(true)
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
