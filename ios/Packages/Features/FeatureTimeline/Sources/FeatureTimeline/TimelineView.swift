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
    @State private var markerVisible = true
    @State private var bottomVisible = false

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
        Group {
            switch model.content {
            case .opening:
                ProgressView()
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
                        .task(id: PaginationTrigger(rows: rows.count, ready: headerVisible && landed)) { if headerVisible, landed, paginationError == nil { await model.loadEarlier() } }
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
                            .onScrollVisibilityChange(threshold: 0.5) {
                                model.rowVisibility(row, isVisible: $0)
                                if row.id == rows.last?.id {
                                    bottomVisible = $0
                                    if landed { model.setAtBottom($0) }
                                }
                            }
                            .onDisappear { model.rowVisibility(row, isVisible: false) }
                            .listRowSeparator(.hidden, edges: .all)
                            // Messages of one group sit close together; a new sender or a gap gets more room above. Stickers and
                            // photos have no bubble to separate them, so they keep a small gap even inside a group.
                            .listRowInsets(EdgeInsets(top: row.continuesRun ? (row.isSticker || row.image != nil ? 4 : 1) : 8, leading: 16, bottom: 1, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)  // rows are as tall as their content, so a group reads as one
                .listSectionSeparator(.hidden)
                .listRowSeparatorTint(.clear)
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("timeline")
                // A newer last row (own echo or incoming message) scrolls into view. Earlier history prepended at the
                // top doesn't change the last row, so reading old messages isn't disturbed.
                // Opening a room: the first unread message goes to the top of the screen, else the newest row to the bottom.
                // `.task(id:)` also runs for a value that was already set when this list first appeared (onChange wouldn't).
                .task(id: model.landingRow) {
                    guard let landing = model.landingRow else { return }
                    try? await Task.sleep(for: .milliseconds(150))  // let the list lay the rows out first
                    // A lazy list estimates the height of rows it hasn't laid out, so one jump to a row far below the visible
                    // part lands short (seen in the simulator with 14 unread messages); jumping again after each layout converges.
                    for _ in 0..<4 {
                        // Landing at the bottom means the newest row now: history can still be arriving in batches after
                        // the landing row was chosen (seen on a reopened room), and that row would leave the list mid-history.
                        let target = model.landingIsUnread ? landing : (model.lastRowID ?? landing)
                        proxy.scrollTo(target, anchor: model.landingIsUnread ? .top : .bottom)
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    model.landingShown()
                    try? await Task.sleep(for: .milliseconds(250))  // let the scroll settle before history may load
                    landed = true
                    model.setAtBottom(bottomVisible)
                }
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
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    model.jumpHandled()
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        model.clearHighlight()
                    }
                }
                // FR-4: the marker is above the viewport once the user is at the bottom and the marker is out of sight.
                .overlay(alignment: .top) {
                    if let marker = model.unreadMarkerID, landed, !markerVisible, bottomVisible {
                        Button { withAnimation { proxy.scrollTo(marker, anchor: .top) } } label: {
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
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
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
            let all = model.viewerPhotos
            TimelinePhotoViewer(initialPhoto: photo, photos: all.isEmpty ? [photo] : all, model: model)
        }
        #else
        .sheet(item: $viewerPhoto) { photo in
            let all = model.viewerPhotos
            TimelinePhotoViewer(initialPhoto: photo, photos: all.isEmpty ? [photo] : all, model: model)
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
}

private struct Composer: View {
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
                    Text(error).font(.caption).foregroundStyle(.red)
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
                                            .foregroundStyle(.white, .black.opacity(0.65))
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
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 8)
                        .padding(.leading, 14)
                        .padding(.trailing, model.canSend ? 0 : 14)
                        .accessibilityIdentifier("composer")
                    if model.canSend {
                        Button { Task { await model.send() } } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .tint)
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

private struct RowView: View {
    let row: TimelineRow
    let model: TimelineViewModel
    let onOpenThread: ((EventID) -> Void)?
    let onOpenPhoto: ((String) -> Void)?
    @State private var showingSource = false
    @State private var showingReaders = false
    /// A sent message is removed for everyone and can't be brought back: ask first.
    @State private var confirmingDelete = false
    @State private var showingOriginal = false

    /// Long-press menu for confirmed messages: quick reactions, and edit/delete for own messages.
    @ViewBuilder private var actions: some View {
        // One row of quick reactions, as in Messages, rather than a full-width row each.
        ControlGroup {
            ForEach(TimelineViewModel.quickReactions, id: \.self) { key in
                Button(key) { Task { await model.toggleReaction(on: row, key: key) } }
            }
            Button("More reactions", systemImage: "face.smiling") { model.beginReactionPicker(row) }
        }
        .controlGroupStyle(.compactMenu)
        Button("Reply", systemImage: "arrowshape.turn.up.left") { model.beginReply(row) }
        if let onOpenThread, let eventID = row.eventID {
            Button("Reply in thread", systemImage: "bubble.left.and.text.bubble.right") { onOpenThread(eventID) }
        }
        #if canImport(UIKit)
        if row.file == nil, !row.isSticker, let text = row.source?.body ?? (row.showsText ? row.text : nil) {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
        #endif
        if row.isEdited { Button("View edit history", systemImage: "clock.arrow.circlepath") { Task { await model.showEditHistory(row) } } }
        if row.source != nil { Button("View source", systemImage: "chevron.left.forwardslash.chevron.right") { showingSource = true } }
        if row.isOwn {
            if row.canEdit { Button("Edit", systemImage: "pencil") { model.beginEdit(row) } }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
    }

    /// Menu for an own message that couldn't be sent.
    @ViewBuilder private var failedActions: some View {
        Button("Try again", systemImage: "arrow.clockwise") { Task { await model.retry(row) } }
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.discard(row) } }
    }

    /// The icon for a placeholder row, from its wording (set by the view model).
    static func placeholderSymbol(_ text: String) -> String {
        if text == "Message deleted" { return "trash" }
        if text == "Unsupported event" || text.hasPrefix("Sticker (") { return "questionmark.square.dashed" }
        return "lock"
    }

    @ViewBuilder private var reactionBar: some View {
        if !row.reactions.isEmpty {
            ReactionFlowLayout(alignment: row.style == .ownMessage ? .trailing : .leading) {
                ForEach(row.reactions) { chip in
                    Button { Task { await model.toggleReaction(on: row, key: chip.key) } } label: {
                        Text("\(chip.key) \(chip.count)").font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(chip.reactedByMe ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var body: some View {
        Group {
            switch row.style {
            case .message, .ownMessage:
                HStack(alignment: .top, spacing: 6) {
                    if row.style == .message {
                        if row.continuesRun { Color.clear.frame(width: 28, height: 1) } else { SenderAvatar(name: row.sender ?? "?", ref: row.avatar, model: model) }
                    }
                    VStack(alignment: row.style == .ownMessage ? .trailing : .leading, spacing: 2) {
                        if let sender = row.sender, row.style == .message, !row.continuesRun { Text(sender).font(.caption).foregroundStyle(.secondary) }
                        if let reply = row.reply {
                            VStack(alignment: .leading, spacing: 0) {
                                if let name = reply.sender { Text(name).font(.caption2.bold()) }
                                Text(reply.snippet ?? "Original message unavailable").font(.caption).lineLimit(2)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                            .overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await model.jumpToReplyOriginal(from: row) } }
                            .accessibilityAddTraits(.isButton)
                        }
                        if let image = row.image {
                            ThumbnailView(image: image, model: model, isSticker: row.isSticker)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if !row.isSticker, model.showsPreview(of: image) {
                                        onOpenPhoto?(row.id)
                                    }
                                }
                                .accessibilityLabel(row.isSticker ? row.text : "Image")
                        }
                        if let file = row.file { FileTileView(file: file, isOpening: model.openingRow == row.id, model: model) { Task { await model.openFile(row) } } }
                        if let card = row.card, !showingOriginal {
                            BotCardView(
                                card: card, state: { model.botRowState(bot: row.source?.sender, id: $0) },
                                tick: { id in Task { await model.tickBotTask(bot: row.source?.sender, id: id) } })
                            Button("Show original") { showingOriginal = true }.font(.caption2)
                        } else if row.isJumboEmoji {
                            Text(row.text)
                                .font(.system(size: 48))
                                .padding(.vertical, 2)
                                .opacity(row.status == nil ? 1 : 0.6)
                        } else if row.showsText {
                            Text(row.styled ?? AttributedString(row.text))
                                .padding(8)
                                .background(row.style == .ownMessage ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
                                .opacity(row.status == nil ? 1 : 0.6)
                            if row.card != nil { Button("Show card") { showingOriginal = false }.font(.caption2) }
                        }
                        if let status = row.status {
                            Text(status).font(.caption2).foregroundStyle(.secondary)
                        } else if row.endsRun, let time = row.time {
                            Text(time).font(.caption2).foregroundStyle(.secondary)
                        }
                        if row.status == nil, !row.readers.isEmpty { Button { showingReaders = true } label: { ReceiptAvatars(row: row, model: model) }.buttonStyle(.plain) }
                        reactionBar
                    }
                    .frame(maxWidth: .infinity, alignment: row.style == .ownMessage ? .trailing : .leading)
                    .contextMenu {
                        if row.eventID != nil { actions } else if row.failedLocalID != nil { failedActions }
                    }
                }
                .padding(row.style == .ownMessage ? .leading : .trailing, 48)
            case .notice:
                VStack(alignment: .leading, spacing: 2) {
                    if let card = row.card, !showingOriginal {
                        BotCardView(
                            card: card, state: { model.botRowState(bot: row.source?.sender, id: $0) },
                            tick: { id in Task { await model.tickBotTask(bot: row.source?.sender, id: id) } })
                        Button("Show original") { showingOriginal = true }.font(.caption2)
                    } else {
                        Text(row.styled ?? AttributedString(row.text)).font(.callout).foregroundStyle(.secondary)
                        if row.card != nil { Button("Show card") { showingOriginal = false }.font(.caption2) }
                    }
                    reactionBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { if row.eventID != nil { actions } }
            case .emote:
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.text).italic()
                    reactionBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { if row.eventID != nil { actions } }
            case .placeholder:
                // A deleted, unreadable or unknown message still belongs to its sender: a quiet outlined bubble on their side,
                // with their name, instead of a full-width line of italics.
                VStack(alignment: row.isOwn ? .trailing : .leading, spacing: 2) {
                    if !row.isOwn, !row.continuesRun, let sender = row.sender { Text(sender).font(.caption).foregroundStyle(.secondary) }
                    Label(row.text, systemImage: Self.placeholderSymbol(row.text))
                        .font(.footnote).italic().foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.4)))
                }
                .frame(maxWidth: .infinity, alignment: row.isOwn ? .trailing : .leading)
                .padding(row.isOwn ? .leading : .trailing, 48)
            case .state, .marker:
                Text(row.text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            case .divider:
                Text(row.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingReaders) { ReadersView(row: row, model: model) }
        .sheet(isPresented: $showingSource) { if let source = row.source { MessageSourceView(source: source) } }
        .confirmationDialog("Delete this message for everyone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.delete(row) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It can't be undone.") }
    }
}

/// An image row's thumbnail; shows a neutral box while loading or if the download failed.
/// Photos fit within 240 pt; a sticker is shown in a fixed 200 pt box (the picture's own size is small and mustn't decide).
private struct ThumbnailSize: ViewModifier {
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

private struct ThumbnailView: View {
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
private struct ReactionPicker: View {
    let model: TimelineViewModel

    var body: some View {
        NativeEmojiPicker(
            recents: model.recentEmoji,
            onPick: { key in Task { await model.pickReaction(key) } }
        )
        .accessibilityIdentifier("reactionPicker")
    }
}

/// Reusable native emoji picker supporting:
/// 1. Direct input from the iOS system Emoji keyboard (any Unicode emoji, skin tone, flag, or new iOS emoji),
/// 2. Recently used emoji, and
/// 3. Searchable categorised Unicode emoji grid.
private struct NativeEmojiPicker: View {
    let recents: [String]
    let onPick: (String) -> Void
    @State private var search = ""

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible()), count: 8) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search emoji", text: $search)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("emoji-search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))

                #if canImport(UIKit)
                NativeEmojiKeyboardField(placeholder: "😀+") { emoji in
                    onPick(emoji)
                }
                .frame(width: 64, height: 36)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
                .accessibilityIdentifier("emoji-keyboard-input")
                #endif
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !recents.isEmpty {
                            sectionHeader("Recent")
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(recents, id: \.self) { emoji in
                                    emojiButton(emoji)
                                }
                            }
                        }
                        ForEach(NativeEmoji.Category.allCases) { category in
                            let items = NativeEmoji.catalog.filter { $0.category == category }
                            if !items.isEmpty {
                                sectionHeader(category.rawValue)
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(items) { entry in
                                        emojiButton(entry.emoji)
                                    }
                                }
                            }
                        }
                    } else {
                        let hits = NativeEmoji.search(search)
                        if hits.isEmpty {
                            if let direct = NativeEmoji.firstEmoji(in: search) {
                                sectionHeader("Use emoji")
                                emojiButton(direct)
                            } else {
                                Text("No matching emoji. Tap 😀+ to use the iOS emoji keyboard.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 12)
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(hits) { entry in
                                    emojiButton(entry.emoji)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func emojiButton(_ emoji: String) -> some View {
        Button(emoji) { onPick(emoji) }
            .font(.title2)
            .buttonStyle(.plain)
    }
}

#if canImport(UIKit)
/// A `UITextField` subclass that prefers the iOS system Emoji keyboard (`primaryLanguage == "emoji"`)
/// and emits every native emoji grapheme cluster typed into it.
private final class EmojiUITextField: UITextField {
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

private struct NativeEmojiKeyboardField: UIViewRepresentable {
    let placeholder: String
    let onEmoji: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEmoji: onEmoji) }

    func makeUIView(context: Context) -> EmojiUITextField {
        let field = EmojiUITextField()
        field.placeholder = placeholder
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 18)
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ uiView: EmojiUITextField, context: Context) {
        context.coordinator.onEmoji = onEmoji
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onEmoji: (String) -> Void
        init(onEmoji: @escaping (String) -> Void) { self.onEmoji = onEmoji }

        @objc func textChanged(_ sender: UITextField) {
            guard let text = sender.text, !text.isEmpty else { return }
            if let emoji = NativeEmoji.firstEmoji(in: text) {
                sender.text = ""
                onEmoji(emoji)
            } else {
                sender.text = ""
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
#endif

/// A file, audio or video attachment: icon, name and details; tapping downloads it and opens Quick Look (which plays audio and
/// video and offers sharing and saving).
private struct FileTileView: View {
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
                    .overlay { Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white).shadow(radius: 4) }
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
private struct PaginationTrigger: Hashable {
    let rows: Int
    let ready: Bool
}

/// "View source" for a text message: who sent it, which event, and the plain and HTML bodies exactly as received.
private struct EditHistoryView: View {
    let state: TimelineViewModel.EditHistoryState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading: ProgressView()
                case .failed(let text): ContentUnavailableView("Edit history unavailable", systemImage: "clock.badge.exclamationmark", description: Text(text))
                case .loaded(let versions):
                    List(versions) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.text.isEmpty ? "(no text)" : version.text)
                            Text([version.isCurrent ? "Current" : nil, version.time].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MessageSourceView: View {
    let source: TimelineRow.Source
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                if let sender = source.sender { LabeledContent("Sender", value: sender) }
                if let eventID = source.eventID { LabeledContent("Event", value: eventID) }
                Section("Body") { Text(source.body).textSelection(.enabled) }
                if let formatted = source.formattedBody {
                    Section("Formatted body (HTML)") { Text(formatted).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                }
                #if canImport(UIKit)
                Section {
                    Button {
                        UIPasteboard.general.string = source.formattedText
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy source", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("copyMessageSource")
                }
                #endif
            }
            .navigationTitle("Message source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ShareLink(item: source.formattedText) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

/// A bot message as a native card (BOT_MESSAGES FR-2). Read-only: ticking tasks needs the interaction protocol (FR-3).
private struct BotCardView: View {
    let card: BotCard
    let state: (String) -> TimelineViewModel.BotRowState
    let tick: (String) -> Void

    /// One list row: a checkbox the user can tick, then the text, the bot's number and what is going on with it.
    private func todoRow(_ row: BotCard.TodoRow) -> some View {
        let rowState = row.isDone ? .completed : state(row.id)
        let done = rowState == .completed
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button { tick(row.id) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : (rowState == .pending ? "clock" : "circle"))
                    .foregroundStyle(done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(rowState != .open && rowState != .noResponse)
            .accessibilityLabel(done ? "Done" : "Mark done")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(row.text).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                    Text("#\(row.id)").font(.caption2).foregroundStyle(.secondary)
                }
                switch rowState {
                case .pending: Text("Waiting for bot…").font(.caption2).foregroundStyle(.secondary)
                case .noResponse: Text("No response from bot. Tap to try again.").font(.caption2).foregroundStyle(.orange)
                case .unavailable where !row.isDone: Text("Not available").font(.caption2).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch card {
            case .todoList(let title, let rows):
                Label(title, systemImage: "checklist").font(.subheadline.bold())
                ForEach(rows, id: \.id) { row in todoRow(row) }
            case .taskAdded(let id, let owner, let title):
                Label("Task #\(id) added", systemImage: "plus.circle").font(.subheadline.bold())
                Text(title)
                if let owner { Text("for \(owner)").font(.caption).foregroundStyle(.secondary) }
            case .reminderSet(let id, let when, let title):
                Label("Reminder #\(id)", systemImage: "alarm").font(.subheadline.bold())
                Text(title)
                if let when { Text(when).font(.caption).foregroundStyle(.secondary) }
            case .taskDone(let title):
                Label("Done: \(title)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .taskDeleted(let title):
                Label("Deleted: \(title)", systemImage: "trash").foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("bot-card")
    }
}
/// The small round picture beside someone else's message (their initial until the image loads).
private struct SenderAvatar: View {
    let name: String
    let ref: MediaRef?
    let model: TimelineViewModel
    var size: CGFloat = 28
    @State private var data: Data?

    var body: some View {
        AvatarCircle(name: name, imageData: data, size: size)
            .accessibilityHidden(true)
            .task(id: ref) {
                data = nil
                guard let ref else { return }
                data = await model.avatarData(ref)
            }
    }
}
/// Everyone who has read up to a message (TIMELINE FR-6), behind a tap on the avatars.
private struct ReadersView: View {
    let row: TimelineRow
    let model: TimelineViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(row.allReaders) { reader in
                HStack(spacing: 12) {
                    SenderAvatar(name: reader.name, ref: reader.avatar, model: model, size: 32)
                    Text(reader.name)
                }
                .accessibilityElement(children: .combine)
            }
            .navigationTitle("Seen by")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// Up to three small pictures of the people who have read up to this message, and "+N" for the rest (TIMELINE FR-6).
private struct ReceiptAvatars: View {
    let row: TimelineRow
    let model: TimelineViewModel

    var body: some View {
        HStack(spacing: -4) {
            ForEach(row.readers) { reader in
                SenderAvatar(name: reader.name, ref: reader.avatar, model: model, size: 16)
                    .overlay(Circle().stroke(.background, lineWidth: 1))
            }
            if row.seenBy > row.readers.count {
                Text("+\(row.seenBy - row.readers.count)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seen by \(row.readers.map(\.name).joined(separator: ", "))" + (row.seenBy > row.readers.count ? " and \(row.seenBy - row.readers.count) more" : ""))
    }
}

private extension Image {
    /// The attachment buttons beside the composer: one size, centred on a one-line field.
    func composerIcon() -> some View { font(.title3).frame(height: 36) }
}

/// Wraps reaction chips onto multiple lines, aligned to the message's own side (leading for incoming, trailing for own).
private struct ReactionFlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = rows(for: subviews, maxWidth: maxWidth)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + max(0, CGFloat(lines.count - 1)) * spacing
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = alignment == .trailing ? bounds.maxX - line.width : bounds.minX
            for (index, size) in line.items {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var result: [Line] = []
        var current = Line()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, nextWidth > maxWidth {
                result.append(current)
                current = Line()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { result.append(current) }
        return result
    }
}

/// Full-screen zoomable + swipeable photo viewer for timeline images (MEDIA_ATTACHMENTS FR-1).
private struct TimelinePhotoViewer: View {
    let photos: [TimelineViewModel.PhotoViewerItem]
    let model: TimelineViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @State private var exportedURL: URL?
    @State private var isExporting = false

    init(initialPhoto: TimelineViewModel.PhotoViewerItem, photos: [TimelineViewModel.PhotoViewerItem], model: TimelineViewModel) {
        self.photos = photos
        self.model = model
        _currentID = State(initialValue: initialPhoto.id)
    }

    private var currentIndex: Int {
        photos.firstIndex(where: { $0.id == currentID }) ?? 0
    }

    private var currentPhoto: TimelineViewModel.PhotoViewerItem {
        photos[currentIndex]
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                TabView(selection: $currentID) {
                    ForEach(photos) { item in
                        TimelinePhotoPage(item: item, model: model)
                            .tag(item.id)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif

                if let caption = currentPhoto.caption {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.6))
                }
            }
            .navigationTitle(photos.count > 1 ? "\(currentIndex + 1) of \(photos.count)" : (currentPhoto.sender ?? "Photo"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("photo-viewer-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let exportedURL {
                        ShareLink(item: exportedURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share photo")
                    } else {
                        Button {
                            let target = currentPhoto
                            isExporting = true
                            Task {
                                let url = await model.exportViewerPhoto(target)
                                if currentID == target.id { exportedURL = url }
                                isExporting = false
                            }
                        } label: {
                            if isExporting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .disabled(isExporting)
                        .accessibilityLabel("Export photo")
                    }
                }
            }
            .onChange(of: currentID) {
                exportedURL = nil
                isExporting = false
            }
        }
    }
}

private struct TimelinePhotoPage: View {
    let item: TimelineViewModel.PhotoViewerItem
    let model: TimelineViewModel
    @State private var data: Data?
    @State private var isLoading = false

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let data, let image = UIImage(data: data) {
                ZoomableImageView(image: image)
            } else if isLoading {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
            #else
            Image(systemName: "photo")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            data = nil
            isLoading = true
            data = await model.fullImageData(for: item.image)
            isLoading = false
        }
    }
}
#endif
