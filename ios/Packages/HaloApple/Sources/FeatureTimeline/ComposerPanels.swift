#if canImport(UIKit)
import HaloDesignSystem
import HaloDomain
import PhotosUI
import SwiftUI
import UIKit

/// The panel under the composer: the expression panel (GIFs · Stickers · Emoji) or attachments
/// (docs/features/COMPOSER_PANELS.md §4–§7). Panels never touch the composer: they insert or send through the view model.
struct ComposerPanelContent: View {
    let panel: ComposerPanel
    let model: TimelineViewModel
    let input: ComposerInputController
    let gifPanel: (@MainActor () -> AnyView)?
    let stickerPanel: (@MainActor () -> AnyView)?
    @Binding var choosingFile: Bool

    var body: some View {
        switch panel {
        case .expression:
            ExpressionPanel(model: model, input: input, gifPanel: gifPanel, stickerPanel: stickerPanel)
        case .attachments:
            AttachmentPanel(model: model, input: input, choosingFile: $choosingFile)
        }
    }
}

// MARK: - Expression panel

/// GIFs, stickers and emoji behind one floating tab pill; the last tab is remembered, as in the system keyboard.
struct ExpressionPanel: View {
    enum Tab: String, Hashable, Identifiable {
        case gifs, stickers, emoji
        var id: String { rawValue }
    }

    let model: TimelineViewModel
    let input: ComposerInputController
    let gifPanel: (@MainActor () -> AnyView)?
    let stickerPanel: (@MainActor () -> AnyView)?
    @AppStorage("halo.composer.expressionTab") private var stored = Tab.stickers.rawValue

    private var tabs: [Tab] {
        var tabs: [Tab] = []
        if gifPanel != nil { tabs.append(.gifs) }
        if stickerPanel != nil { tabs.append(.stickers) }
        tabs.append(.emoji)
        return tabs
    }

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: stored).flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first ?? .emoji },
            set: { stored = $0.rawValue }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab.wrappedValue {
                case .gifs: gifPanel?()
                case .stickers: stickerPanel?()
                case .emoji: EmojiPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // The pill hides while a panel's search field has the keyboard up.
            if tabs.count > 1, !input.state.panelSearching {
                HStack(alignment: .center) {
                    PanelTabPill(
                        items: tabs.map { tab in
                            switch tab {
                            case .gifs: .init(tab: tab, title: "GIFs", identifier: "panel-tab-gifs")
                            case .stickers: .init(tab: tab, title: "Stickers", identifier: "panel-tab-stickers")
                            case .emoji: .init(tab: tab, title: "Emoji", identifier: "panel-tab-emoji")
                            }
                        },
                        selection: tab
                    )
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if tab.wrappedValue == .emoji {
                        ComposerCircleButton(systemImage: "delete.left", label: "Delete") { model.deleteBackward() }
                            .padding(.trailing, HaloSpacing.m)
                            .accessibilityIdentifier("emoji-delete")
                    }
                }
                .padding(.bottom, HaloSpacing.s)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Emoji panel

/// The full emoji set (`EmojiKeyboard`): recently used first, a category strip to jump, and search. Tapping inserts at the
/// end of the draft and keeps the panel open.
struct EmojiPanel: View {
    let model: TimelineViewModel
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 42), spacing: HaloSpacing.xs)]

    private static func symbol(_ section: EmojiKeyboard.Section) -> String {
        switch section {
        case .smileys: "face.smiling"
        case .nature: "leaf"
        case .food: "fork.knife"
        case .activity: "soccerball"
        case .travel: "car"
        case .objects: "lightbulb"
        case .symbols: "heart"
        case .flags: "flag"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelSearchField(text: $search, placeholder: "Search emoji", identifier: "emoji-search")
                .padding(.horizontal, HaloSpacing.m)
                .padding(.top, HaloSpacing.s)
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    categoryStrip(proxy)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HaloSpacing.s) {
                        if search.trimmingCharacters(in: .whitespaces).isEmpty {
                            if !model.recentEmoji.isEmpty {
                                section("Recently used", model.recentEmoji).id("recent")
                            }
                            ForEach(EmojiKeyboard.Section.allCases) { section in
                                self.section(section.rawValue, EmojiKeyboard.emoji(in: section)).id(section.id)
                            }
                        } else {
                            let hits = EmojiKeyboard.search(search)
                            if hits.isEmpty {
                                Text("No emoji found").font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary)
                                    .frame(maxWidth: .infinity).padding(.top, HaloSpacing.l)
                            } else {
                                grid(hits)
                            }
                        }
                    }
                    .padding(.horizontal, HaloSpacing.m)
                    .padding(.bottom, 72)
                }
                .scrollDismissesKeyboard(.immediately)
                }
            }
        }
    }

    private func categoryStrip(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            if !model.recentEmoji.isEmpty {
                categoryButton("clock", label: "Recently used") { proxy.scrollTo("recent", anchor: .top) }
            }
            ForEach(EmojiKeyboard.Section.allCases) { section in
                categoryButton(Self.symbol(section), label: section.rawValue) { proxy.scrollTo(section.id, anchor: .top) }
            }
        }
        .padding(.horizontal, HaloSpacing.s)
    }

    private func categoryButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(HaloTypography.body)
                .foregroundStyle(HaloColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func section(_ title: String, _ emoji: [String]) -> some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            Text(title.uppercased())
                .font(HaloTypography.captionEmphasis)
                .foregroundStyle(HaloColor.textSecondary)
                .padding(.top, HaloSpacing.s)
                .accessibilityAddTraits(.isHeader)
            grid(emoji)
        }
    }

    private func grid(_ emoji: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: HaloSpacing.xs) {
            ForEach(emoji, id: \.self) { item in
                Button { model.insertEmoji(item) } label: {
                    Text(item)
                        .font(HaloTypography.title)
                        .frame(minWidth: 42, minHeight: 42)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(EmojiKeyboard.name(of: item) ?? item)
            }
        }
    }
}

// MARK: - Attachment panel

/// Photos (an inline, privacy-preserving system picker: no photo-library permission is needed), a file from Files, and a
/// pasted image. Picked photos join the composer's pending strip; a caption typed in the field goes with the first.
struct AttachmentPanel: View {
    let model: TimelineViewModel
    let input: ComposerInputController
    @Binding var choosingFile: Bool
    @State private var selection: [PhotosPickerItem] = []
    /// Picker item identifiers in the order their photos were attached, to mirror deselection.
    @State private var attached: [String] = []

    private var remaining: Int { max(1, TimelineViewModel.maxPendingPhotos - model.pendingPhotos.count + attached.count) }

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.canSendImages {
                PhotosPicker(
                    selection: $selection,
                    maxSelectionCount: remaining,
                    selectionBehavior: .continuousAndOrdered,
                    matching: .images,
                    preferredItemEncoding: .current,
                    photoLibrary: .shared()
                ) {
                    Text("Photos")
                }
                .photosPickerStyle(.inline)
                .photosPickerDisabledCapabilities([.stagingArea, .selectionActions])
                .photosPickerAccessoryVisibility(.hidden, edges: .all)
                .accessibilityIdentifier("photo-button")
            } else {
                ContentUnavailableView("Photos can't be sent here", systemImage: "photo.badge.exclamationmark")
            }

            HStack(spacing: HaloSpacing.s) {
                attachmentButton("File", symbol: "doc", identifier: "file-button") { choosingFile = true }
                    .disabled(model.isSendingFile)
                if model.canSendImages, UIPasteboard.general.hasImages {
                    attachmentButton("Paste", symbol: "doc.on.clipboard", identifier: "paste-image-button") { pasteImage() }
                }
            }
            .padding(HaloSpacing.xs)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, HaloSpacing.s)
        }
        .onChange(of: selection) { old, new in Task { await sync(from: old, to: new) } }
        .onChange(of: model.pendingPhotos.count) { _, count in
            // Sent, or a photo removed from the strip: the picker's checkmarks can no longer be matched, so they reset.
            if count < attached.count {
                attached = []
                selection = []
            }
        }
    }

    private func attachmentButton(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(HaloTypography.bodyEmphasis)
                .foregroundStyle(HaloColor.textPrimary)
                .padding(.horizontal, HaloSpacing.l)
                .frame(minHeight: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image, let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else { return }
        Task { await model.attachPhoto(data: data, filename: "pasted") }
    }

    /// Mirrors the picker's selection into the pending photos: newly checked photos are prepared and attached in order,
    /// unchecked ones are removed again.
    private func sync(from old: [PhotosPickerItem], to new: [PhotosPickerItem]) async {
        let newIDs = new.compactMap(\.itemIdentifier)
        // Picked photos sit after any attached another way (pasted, dropped), in the order they were picked.
        let base = max(0, model.pendingPhotos.count - attached.count)
        for (offset, id) in attached.enumerated().reversed() where !newIDs.contains(id) {
            model.removePendingPhoto(at: base + offset)
            attached.remove(at: offset)
        }
        for (index, item) in new.enumerated() {
            let id = item.itemIdentifier ?? "item-\(index)"
            guard !attached.contains(id) else { continue }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let before = model.pendingPhotos.count
            await model.attachPhoto(data: data, filename: id.components(separatedBy: "/").first ?? "photo")
            if model.pendingPhotos.count > before { attached.append(id) }
        }
    }
}
#endif
