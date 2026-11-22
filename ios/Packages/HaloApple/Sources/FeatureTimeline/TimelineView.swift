#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
import PhotosUI

public struct TimelineView: View {
    private let model: TimelineViewModel
    private let stickerPanel: (@MainActor () -> AnyView)?
    private let onOpenThread: (@MainActor (EventID) -> Void)?
    @State private var showsStickers = false
    @State private var viewerPhoto: TimelineViewModel.PhotoViewerItem?
    @State private var headerVisible = false
    /// History is only loaded after the opening scroll: rows prepended before it would push the landing row out of place.
    @State private var landed = false
    /// Whether the unread marker row and the newest row are on screen (the marker is above the viewport when it isn't, and the newest is).
    /// Off screen until the marker row reports itself visible: a lazy list never lays out a row it lands far below, so that
    /// row never reports going away either (with `true` here the pill never showed after 40 unread messages).
    @State private var markerVisible = UnreadPill.markerOnScreenAtOpen
    @State private var bottomVisible = false
    /// The list follows its newest row (also when older history arrives above it) until the user scrolls away themselves.
    @State private var pinnedToBottom = true
    /// The list is drawn once it has been placed at the newest row (a frame or two), so it never shows its top first and then
    /// jumps. No spinner: a short fallback timer shows it anyway if that never happens.
    @State private var listPlaced = false
    /// The list is being scrolled (a drag, a fling, an animated scroll): it is not following the newest row then.
    @State private var scrollMoving = false
    /// Automatic history paging only runs with the newest row on screen (a short room that needs filling) or once the user has
    /// scrolled; right after history lands above the newest row the "Load earlier" row is briefly visible and paging then would
    /// move the content again.
    private var pagingAllowed: Bool { bottomVisible || !pinnedToBottom }

    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter stickerPanel: the sticker panel for this room, made by the composition root (a feature never imports
    ///   another feature). Without it the composer has no sticker button.
    /// - Parameter onOpenThread: opens a focused thread sheet for the chosen root event (M10 Threads).
    public init(
        model: TimelineViewModel,
        stickerPanel: (@MainActor () -> AnyView)? = nil,
        onOpenThread: (@MainActor (EventID) -> Void)? = nil
    ) {
        self.model = model
        self.stickerPanel = stickerPanel
        self.onOpenThread = onOpenThread
    }

    public var body: some View {
        bodyContent.modifier(TimelineDropModifier(model: model))
    }

    private var bodyContent: some View {
        Group {
            switch model.content {
            case .opening:
                // No spinner when a room opens: it is normally there within a moment. Only a slow open (a poor network) gets one.
                DelayedProgressView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't open room", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.retry() } }.buttonStyle(.borderedProminent)
                }
            case .live(let rows, let isPaginating, let canLoadEarlier, let paginationError):
                ScrollViewReader { proxy in
                List {
                    if canLoadEarlier {
                        HStack {
                            Spacer()
                            if isPaginating {
                                ProgressView()
                            } else {
                                Button(paginationError ?? "Load earlier messages") { Task { await model.loadEarlier() } }
                                    .font(.footnote)
                            }
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        // History loads only while this row is on screen (the user is at the top), and continues until the
                        // screen is full or the start marker arrives; opening a room never loads it all.
                        .onAppear { headerVisible = true }
                        .onDisappear { headerVisible = false }
                        .task(id: PaginationTrigger(rows: rows.count, ready: headerVisible && landed && pagingAllowed)) { if headerVisible, landed, pagingAllowed, paginationError == nil { await model.loadEarlier() } }
                    }
                    ForEach(rows) { row in
                        RowView(
                            row: row,
                            model: model,
                            onOpenThread: onOpenThread,
                            onOpenPhoto: { rowID in
                                viewerPhoto = model.viewerPhotos.first(where: { $0.id == rowID })
                            }
                        )
                            .background(model.highlightedRowID == row.id ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))
                            .animation(.easeOut(duration: 0.4), value: model.highlightedRowID)
                            // The pill's target: whether the first row that was unread at open is on screen.
                            .onScrollVisibilityChange { if row.id == model.unreadMarkerID { markerVisible = $0 } }
                            // D6: a row counts as seen when at least half of it is on screen; the 0.5 s dwell is in the view model.
                            .onScrollVisibilityChange(threshold: 0.5) { model.rowVisibility(row, isVisible: $0) }
                            .onDisappear { model.rowVisibility(row, isVisible: false) }
                            .listRowSeparator(.hidden, edges: .all)
                            // Messages of one group sit close together; a new sender or a gap gets more room above. Stickers and
                            // photos have no bubble to separate them, so they keep a small gap even inside a group.
                            .listRowInsets(EdgeInsets(top: row.continuesRun ? (row.isSticker || row.image != nil ? 4 : 1) : 8, leading: 16, bottom: 1, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .opacity(listPlaced || rows.isEmpty ? 1 : 0)
                .task {
                    try? await Task.sleep(for: .milliseconds(600))
                    listPlaced = true
                }
                .environment(\.defaultMinListRowHeight, 0)  // rows are as tall as their content, so a group reads as one
                .listSectionSeparator(.hidden)
                .listRowSeparatorTint(.clear)
                .defaultScrollAnchor(.bottom)
                // "At the bottom" comes from the scroll geometry, not from one row's visibility: that flag could stay true after
                // rows were added above the newest row and then hide that the list had moved away from the bottom.
                // While the list follows the newest row and nothing is scrolling it, any change that leaves it short of the bottom
                // scrolls it back: history arriving above, a row that grows (a reaction), the keyboard, and a lazy list replacing
                // estimated row heights with real ones after the opening scroll (it then drifts up by itself; seen in S10 scroll
                // test). Any scroll movement — a drag, a fling, a tap on the status bar, an animated jump — stops the following.
                .onScrollGeometryChange(for: BottomGap.self) { geometry in
                    BottomGap(
                        contentHeight: geometry.contentSize.height, bottomInset: geometry.contentInsets.bottom,
                        visibleMaxY: geometry.visibleRect.maxY)
                } action: { _, value in
                    let atBottom = value.isAtBottom
                    if atBottom != bottomVisible {
                        bottomVisible = atBottom
                        if landed { model.setAtBottom(atBottom) }
                    }
                    if atBottom {
                        pinnedToBottom = true
                    } else if scrollMoving {
                        pinnedToBottom = false
                    } else if pinnedToBottom, let last = rows.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onScrollPhaseChange { _, phase in scrollMoving = phase == .interacting || phase == .decelerating || phase == .animating }
                .accessibilityIdentifier("timeline")
                // Opening a room: the newest row goes to the bottom. `.defaultScrollAnchor(.bottom)` already opens the list there, so
                // when that row is on screen nothing is scrolled and the list never visibly moves.
                // `.task(id:)` also runs for a value that was already set when this list first appeared (onChange wouldn't).
                .task(id: model.landingRow) {
                    guard let landing = model.landingRow else { return }
                    try? await Task.sleep(for: .milliseconds(80))  // let the list lay the rows out first
                    // A lazy list estimates the height of rows it hasn't laid out, so one jump to a row far below the visible
                    // part lands short; jumping again after each layout converges (at most ~2 s).
                    var confirmed = 0
                    for _ in 0..<16 {
                        if Task.isCancelled { return }
                        // Placed only when the newest row is still there one check later: right after the first scroll the list
                        // replaces estimated row heights with real ones and can move again.
                        if model.landingIsUnread ? markerVisible : bottomVisible {
                            confirmed += 1
                            if confirmed >= 2 { break }
                            try? await Task.sleep(for: .milliseconds(60))
                            continue
                        }
                        confirmed = 0
                        // Landing at the bottom means the newest row now: history can still be arriving in batches after
                        // the landing row was chosen (seen on a reopened room), and that row would leave the list mid-history.
                        let target = model.landingIsUnread ? landing : (model.lastRowID ?? landing)
                        proxy.scrollTo(target, anchor: model.landingIsUnread ? .top : .bottom)
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    listPlaced = true
                    // Settle first: `landingShown()` clears `landingRow`, which changes this task's id and cancels it.
                    try? await Task.sleep(for: .milliseconds(250))  // let the scroll settle before history may load
                    landed = true
                    model.landingShown()
                    model.setAtBottom(bottomVisible)
                }
                // A newer last row (own echo or incoming message) scrolls into view when the user is at the bottom. Earlier
                // history prepended at the top doesn't change the last row, so reading old messages isn't disturbed.
                .task(id: rows.last?.id) {
                    // A new last row scrolls into view when already at the bottom or when the user just sent it; when
                    // scrolled up reading history, stay put so the "↓ N new" pill lets the user jump down on their own (TIMELINE §6).
                    guard landed, let last = rows.last, model.isAtBottom || last.isOwn else { return }
                    for step in 0..<3 {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        try? await Task.sleep(for: .milliseconds(step == 0 ? 200 : 250))
                    }
                }
                .onChange(of: model.jumpRequest) { _, target in
                    guard let target else { return }
                    pinnedToBottom = false  // a reply jump leaves the bottom: new rows must not pull the reader back down
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    model.jumpHandled()
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        model.clearHighlight()
                    }
                }
                // FR-4: the marker is above the viewport once the user is at the bottom and the marker is out of sight.
                .overlay(alignment: .top) {
                    if let marker = model.unreadMarkerID,
                       UnreadPill.isShown(hasMarker: true, landed: landed, markerOnScreen: markerVisible, atBottom: bottomVisible) {
                        Button {
                            pinnedToBottom = false
                            withAnimation { proxy.scrollTo(marker, anchor: .top) }
                        } label: {
                            Label("Jump to unread", systemImage: "arrow.up")
                                .font(.footnote.bold()).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityIdentifier("jump-to-unread")
                    }
                }
                // TIMELINE §6: when scrolled up, offer a floating button (or "↓ N new" pill) to return to the newest row.
                .overlay(alignment: .bottomTrailing) {
                    if landed, !model.isAtBottom, let last = rows.last?.id {
                        Button {
                            model.setAtBottom(true)
                            pinnedToBottom = true
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        } label: {
                            if model.newSinceDetached > 0 {
                                Label("\(model.newSinceDetached) new", systemImage: "arrow.down")
                                    .font(.footnote.bold())
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.regularMaterial, in: Capsule())
                            } else {
                                Image(systemName: "arrow.down")
                                    .font(.footnote.bold())
                                    .frame(width: 34, height: 34)
                                    .background(.regularMaterial, in: Circle())
                            }
                        }
                                                .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .accessibilityLabel(model.newSinceDetached > 0 ? "\(model.newSinceDetached) new messages, jump to bottom" : "Jump to bottom")
                        .accessibilityIdentifier("jump-to-bottom")
                    }
                }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { Composer(model: model, onStickers: stickerPanel == nil ? nil : { showsStickers = true }) }
        .sheet(isPresented: $showsStickers) { stickerPanel?().presentationDetents([.medium, .large]) }
        #if canImport(UIKit)
        .sheet(item: Binding(get: { model.openedFile }, set: { if $0 == nil { model.closeFile() } })) { QuickLookView(url: $0.url).ignoresSafeArea() }
        .fullScreenCover(item: $viewerPhoto) { photo in
            photoViewer(initial: photo)
        }
        #else
        .sheet(item: $viewerPhoto) { photo in
            photoViewer(initial: photo)
        }
        #endif
        .alert("Can't open file", isPresented: Binding(get: { model.openFileError != nil }, set: { if !$0 { model.dismissOpenFileError() } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.openFileError ?? "") }
        .sheet(isPresented: Binding(get: { model.editHistory != nil }, set: { if !$0 { model.closeEditHistory() } })) {
            EditHistoryView(state: model.editHistory ?? .loading)
        }
        .sheet(isPresented: Binding(get: { model.reactionTarget != nil }, set: { if !$0 { model.cancelReactionPicker() } })) {
            ReactionPicker(model: model).presentationDetents([.medium])
        }
        .task { await model.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in model.setActive(phase == .active) }
        .onDisappear { model.setActive(false); Task { await model.stop() } }
    }

    private func photoViewer(initial: TimelineViewModel.PhotoViewerItem) -> some View {
        let all = model.viewerPhotos
        let photos = all.isEmpty ? [initial] : all
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let items = photos.map {
            PagedMediaItem(id: $0.id, title: $0.sender ?? "Photo", caption: $0.caption, fallbackSymbol: "photo", isImage: true)
        }
        return PagedPhotoViewer(
            items: items,
            initialID: initial.id,
            loadImageData: { item in
                guard let target = byID[item.id] else { return nil }
                return await model.fullImageData(for: target.image)
            },
            exportItem: { item in
                guard let target = byID[item.id] else { return nil }
                return await model.exportViewerPhoto(target)
            }
        )
    }
}

struct Composer: View {
    @Bindable var model: TimelineViewModel
    let onStickers: (() -> Void)?
    @State private var picked: [PhotosPickerItem] = []
    @State private var choosingFile = false
    @State private var showingEmojiPicker = false

    var body: some View {
        VStack(spacing: 4) {
            if let typing = model.typingText { Text(typing).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            if let error = model.sendError {
                HStack(spacing: 8) {
                    Text(error).font(HaloTypography.caption).foregroundStyle(HaloColor.danger)
                    Spacer()
                    Button { model.dismissSendError() } label: { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
            }
            if model.isSendingImage { ProgressView("Sending photo…").font(.caption) }
            if model.isSendingFile { ProgressView("Sending file…").font(.caption) }
            if model.editing != nil {
                HStack {
                    Label("Editing message", systemImage: "pencil").font(.caption)
                    Spacer()
                    Button("Cancel") { model.cancelEdit() }.font(.caption)
                }
            }
            if let target = model.replyingTo {
                HStack {
                    Label("Replying to \(target.sender ?? "message")", systemImage: "arrowshape.turn.up.left").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Cancel") { model.cancelReply() }.font(.caption)
                }
            }
            ForEach(model.mentionSuggestions) { member in
                Button { model.pickMention(member) } label: {
                    HStack {
                        Text(member.mentionName)
                        Spacer()
                        Text(member.user.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mention-suggestion")
            }
            if !model.emojiSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.emojiSuggestions) { entry in
                            Button { model.pickEmojiSuggestion(entry) } label: {
                                HStack(spacing: 4) {
                                    Text(entry.emoji)
                                    Text(":\(entry.shortcode):").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("emoji-suggestion")
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            if !model.pendingPhotos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(model.pendingPhotos.enumerated()), id: \.offset) { index, photo in
                                ZStack(alignment: .topTrailing) {
                                    #if canImport(UIKit)
                                    if let image = UIImage(data: photo.data) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 56, height: 56)
                                            .clipShape(.rect(cornerRadius: 8))
                                    }
                                    #else
                                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.2)).frame(width: 56, height: 56)
                                    #endif
                                    Button { model.removePendingPhoto(at: index) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(HaloColor.mediaOverlayForeground, HaloColor.mediaOverlayBackground)
                                    }
                                    .offset(x: 4, y: -4)
                                    .accessibilityLabel("Remove photo")
                                    .accessibilityIdentifier("remove-photo")
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    Text(model.pendingPhotos.count == 1
                         ? "Photo ready. Add a caption below, or send as is."
                         : "\(model.pendingPhotos.count) photos ready. Add a caption below, or send as is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 14) {
                if model.canSendImages {
                    PhotosPicker(
                        selection: $picked,
                        maxSelectionCount: max(1, TimelineViewModel.maxPendingPhotos - model.pendingPhotos.count),
                        matching: .images
                    ) { Image(systemName: "photo").composerIcon() }
                        .disabled(model.isSendingImage || model.pendingPhotos.count >= TimelineViewModel.maxPendingPhotos)
                        .accessibilityLabel("Send photos")
                        .accessibilityIdentifier("photo-button")
                }
                Button { choosingFile = true } label: { Image(systemName: "paperclip").composerIcon() }
                    .disabled(model.isSendingFile)
                    .accessibilityLabel("Send a file")
                    .accessibilityIdentifier("file-button")
                Button { showingEmojiPicker = true } label: { Image(systemName: "face.smiling").composerIcon() }
                    .accessibilityLabel("Emoji")
                    .accessibilityIdentifier("emoji-button")
                if let onStickers {
                    Button(action: onStickers) { Image(systemName: "sparkles.rectangle.stack").composerIcon() }
                        .accessibilityLabel("Stickers")
                        .accessibilityIdentifier("sticker-button")
                }
                // Messages-style field: a rounded pill with the send arrow inside it, shown once there is something to send.
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Message", text: $model.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 8)
                        .padding(.leading, 14)
                        .padding(.trailing, model.canSend ? 0 : 14)
                        .accessibilityIdentifier("composer")
                    if model.canSend {
                        Button { Task { await model.send() } } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title2).symbolRenderingMode(.palette)
                                .foregroundStyle(HaloColor.onAccent, HaloColor.accent)
                        }
                        .padding(3)
                        .accessibilityLabel("Send")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(minHeight: 36)
                .background(.background, in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
                .animation(.snappy(duration: 0.2), value: model.canSend)
            }
        }
        .padding(8)
        .background(.bar)
        .sheet(isPresented: $showingEmojiPicker) {
            NavigationStack {
                NativeEmojiPicker(
                    recents: model.recentEmoji,
                    onPick: { emoji in model.insertEmoji(emoji) }
                )
                .navigationTitle("Emoji")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingEmojiPicker = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                // The picked file lives outside the app's sandbox: access is granted only while this scope is open.
                let opened = url.startAccessingSecurityScopedResource()
                defer { if opened { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                // Checked before reading, so a huge file never gets loaded into memory.
                guard size <= OutgoingFile.maximumBytes else { model.reportFileTooLarge(); return }
                guard let data = try? Data(contentsOf: url) else { model.reportFileUnreadable(); return }
                let type = UTType(filenameExtension: url.pathExtension)
                await model.sendFile(data: data, filename: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var loaded: [(data: Data, filename: String)] = []
                for (index, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        loaded.append((data: data, filename: item.itemIdentifier ?? "photo-\(index + 1)"))
                    }
                }
                await model.attachPhotos(loaded)
            }
        }
    }
}


/// TIMELINE FR-4 and D95: the "Jump to unread" pill shows once the room has landed at the newest message and the first
/// unread message is above the screen.
enum UnreadPill {
    /// The marker row counts as off screen until it reports itself visible.
    static let markerOnScreenAtOpen = false

    static func isShown(hasMarker: Bool, landed: Bool, markerOnScreen: Bool, atBottom: Bool) -> Bool {
        hasMarker && landed && !markerOnScreen && atBottom
    }
}

/// How far the end of the list is below its visible part (≤ 0 at the bottom), and the content height, so a change of either
/// reaches the scroll-geometry action. The visible rect reaches under the composer, so the end is the content plus the bottom
/// inset; measured against the content alone, the newest row could sit half behind the composer and count as at the bottom.
struct BottomGap: Equatable {
    let gap: Double
    let contentHeight: Double

    init(contentHeight: Double, bottomInset: Double, visibleMaxY: Double) {
        gap = contentHeight + bottomInset - visibleMaxY
        self.contentHeight = contentHeight
    }

    var isAtBottom: Bool { gap <= 8 }
}

struct PaginationTrigger: Hashable {
    let rows: Int
    let ready: Bool
}

/// A spinner that appears only when the wait passes one second.
private struct DelayedProgressView: View {
    @State private var shown = false

    var body: some View {
        ProgressView()
            .opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(1))
                shown = true
            }
    }
}

/// "View source" for a text message: who sent it, which event, and the plain and HTML bodies exactly as received.

#endif
