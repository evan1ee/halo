#if canImport(UIKit)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// A KLIPY grid (GIFs, or KLIPY stickers) inside the composer's expression panel (docs/features/COMPOSER_PANELS.md §6).
/// KLIPY's rules: the search field reads "Search KLIPY", results keep KLIPY's order in their own grid, media loads from
/// KLIPY's URLs.
public struct KlipyPanelView: View {
    let model: KlipyPanelModel
    /// Space kept free at the bottom for the panel's floating tab pill.
    let bottomInset: CGFloat

    public init(model: KlipyPanelModel, bottomInset: CGFloat = 72) {
        self.model = model
        self.bottomInset = bottomInset
    }

    private var isGIF: Bool { model.kind == .gifs }

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PanelSearchField(text: $model.query, placeholder: "Search KLIPY", identifier: isGIF ? "gif-search" : "klipy-sticker-search")
                .padding(.horizontal, HaloSpacing.m)
                .padding(.top, HaloSpacing.s)
                .padding(.bottom, HaloSpacing.xs)
            if let error = model.sendError {
                HaloBanner(
                    tone: .danger,
                    icon: "exclamationmark.triangle.fill",
                    message: error,
                    onDismiss: { model.dismissSendError() }
                )
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HaloSpacing.m) {
                    section("Favourites", model.favourites, id: "fav")
                    section("Recent", model.recents, id: "recent")
                    if !model.isSearching, !model.items.isEmpty {
                        header("Trending")
                    }
                    results
                    Text("Powered by KLIPY")
                        .font(HaloTypography.caption)
                        .foregroundStyle(HaloColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, HaloSpacing.s)
                }
                .padding(.horizontal, HaloSpacing.m)
                .padding(.bottom, bottomInset)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .task { await model.start() }
    }

    @ViewBuilder private var results: some View {
        switch model.phase {
        case .idle:
            LoadingState(.grid(columns: isGIF ? 3 : 4, count: isGIF ? 9 : 8))
        case .loading where model.items.isEmpty:
            LoadingState(.grid(columns: isGIF ? 3 : 4, count: isGIF ? 9 : 8))
        case .failed:
            ErrorState(
                icon: "wifi.exclamationmark",
                title: isGIF ? "Couldn't load GIFs" : "Couldn't load stickers",
                message: "Check your connection and try again."
            ) {
                Task { await model.retry() }
            }
        default:
            if model.items.isEmpty, model.isSearching {
                ContentUnavailableView.search(text: model.query)
            } else {
                grid(model.items, id: "results")
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [KlipyItem], id: String) -> some View {
        if !items.isEmpty {
            header(title)
            grid(items, id: id)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(HaloTypography.captionEmphasis)
            .foregroundStyle(HaloColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, HaloSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private var columns: [GridItem] {
        isGIF
            ? Array(repeating: GridItem(.flexible(), spacing: HaloSpacing.xs), count: 3)
            : [GridItem(.adaptive(minimum: 76), spacing: HaloSpacing.s)]
    }

    private func grid(_ items: [KlipyItem], id: String) -> some View {
        LazyVGrid(columns: columns, spacing: isGIF ? HaloSpacing.xs : HaloSpacing.s) {
            ForEach(items) { item in
                KlipyCell(item: item, model: model, isGIF: isGIF)
                    .id("\(id)-\(item.id)")
                    .task { if id == "results" { await model.loadMoreIfNeeded(after: item) } }
            }
        }
    }
}

private struct KlipyCell: View {
    let item: KlipyItem
    let model: KlipyPanelModel
    let isGIF: Bool

    var body: some View {
        Button { Task { await model.tap(item) } } label: {
            AsyncAnimatedImage(id: item.preview.url, maxPixelSize: isGIF ? 330 : 240, fills: isGIF, load: model.loader(for: item.preview)) {
                RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous)
                    .fill(HaloColor.textSecondary.opacity(0.12))
            }
            .frame(maxWidth: .infinity)
            .frame(height: isGIF ? 96 : 76)
            .clipShape(.rect(cornerRadius: isGIF ? HaloRadius.small : 0, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.isSending)
        .accessibilityLabel(item.title.isEmpty ? (isGIF ? "GIF" : "Sticker") : item.title)
        .accessibilityHint("Sends it")
        .accessibilityIdentifier(isGIF ? "klipy-gif-item" : "klipy-sticker-item")
        .contextMenu {
            Button("Send", systemImage: "paperplane") { Task { await model.tap(item) } }
            Button(model.isFavourite(item) ? "Remove from favourites" : "Add to favourites",
                   systemImage: model.isFavourite(item) ? "star.slash" : "star") {
                Task { await model.toggleFavourite(item) }
            }
        } preview: {
            AsyncAnimatedImage(id: item.shared.url, maxPixelSize: 600, load: model.loader(for: item.shared)) {
                ProgressView()
            }
            .frame(width: 260, height: 260 / max(0.4, min(2.5, item.shared.aspectRatio)))
            .padding(HaloSpacing.s)
        }
    }
}

#endif
