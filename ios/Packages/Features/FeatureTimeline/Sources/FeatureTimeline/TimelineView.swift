#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
import PhotosUI

public struct TimelineView: View {
    private let model: TimelineViewModel
    private let stickerPanel: (@MainActor () -> AnyView)?
    @State private var showsStickers = false
    @State private var headerVisible = false
    /// History is only loaded after the opening scroll: rows prepended before it would push the landing row out of place.
    @State private var landed = false
    /// Whether the unread marker row and the newest row are on screen (the marker is above the viewport when it isn't, and the newest is).
    @State private var markerVisible = true
    @State private var bottomVisible = false

    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter stickerPanel: the sticker panel for this room, made by the composition root (a feature never imports
    ///   another feature). Without it the composer has no sticker button.
    public init(model: TimelineViewModel, stickerPanel: (@MainActor () -> AnyView)? = nil) {
        self.model = model
        self.stickerPanel = stickerPanel
    }

    public var body: some View {
        Group {
            switch model.content {
            case .opening:
                ProgressView()
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
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
                        RowView(row: row, model: model)
                            // The pill's target: whether the first row that was unread at open is on screen.
                            .onScrollVisibilityChange { if row.id == model.unreadMarkerID { markerVisible = $0 } }
                            // D6: a row counts as seen when at least half of it is on screen; the 0.5 s dwell is in the view model.
                            .onScrollVisibilityChange(threshold: 0.5) {
                                model.rowVisibility(row, isVisible: $0)
                                if row.id == rows.last?.id { bottomVisible = $0 }
                            }
                            .onDisappear { model.rowVisibility(row, isVisible: false) }
                            .listRowSeparator(.hidden, edges: .all)
                            // Messages of one group sit close together; a new sender or a gap gets more room above.
                            .listRowInsets(EdgeInsets(top: row.continuesRun ? 1 : 8, leading: 16, bottom: 1, trailing: 16))
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
                        proxy.scrollTo(landing, anchor: model.landingIsUnread ? .top : .bottom)
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    model.landingShown()
                    try? await Task.sleep(for: .milliseconds(250))  // let the scroll settle before history may load
                    landed = true
                }
                .task(id: rows.last?.id) {
                    // A new last row scrolls into view. A tall row (a photo) isn't measured yet at the first jump and would land
                    // just below the screen (seen in the simulator), so the jump is repeated after the layout settles.
                    guard landed, let last = rows.last?.id else { return }
                    for step in 0..<3 {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        try? await Task.sleep(for: .milliseconds(step == 0 ? 200 : 250))
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
                }
            }
        }
        .safeAreaInset(edge: .bottom) { Composer(model: model, onStickers: stickerPanel == nil ? nil : { showsStickers = true }) }
        .sheet(isPresented: $showsStickers) { stickerPanel?().presentationDetents([.medium, .large]) }
        #if canImport(UIKit)
        .sheet(item: Binding(get: { model.openedFile }, set: { if $0 == nil { model.closeFile() } })) { QuickLookView(url: $0.url).ignoresSafeArea() }
        #endif
        .alert("Can't open file", isPresented: Binding(get: { model.openFileError != nil }, set: { if !$0 { model.dismissOpenFileError() } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.openFileError ?? "") }
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
    @State private var picked: PhotosPickerItem?
    @State private var choosingFile = false

    var body: some View {
        VStack(spacing: 4) {
            if let typing = model.typingText { Text(typing).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            if let error = model.sendError { Text(error).font(.caption).foregroundStyle(.red) }
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
            if let photo = model.pendingPhoto {
                HStack(spacing: 10) {
                    #if canImport(UIKit)
                    if let image = UIImage(data: photo.data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 8)) }
                    #endif
                    Text("Photo ready. Add a caption below, or send as is.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.removePendingPhoto() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Remove photo")
                        .accessibilityIdentifier("remove-photo")
                }
            }
            HStack(alignment: .bottom) {
                if model.canSendImages {
                    PhotosPicker(selection: $picked, matching: .images) { Image(systemName: "photo").font(.title2) }
                        .disabled(model.isSendingImage)
                        .accessibilityLabel("Send a photo")
                        .accessibilityIdentifier("photo-button")
                }
                Button { choosingFile = true } label: { Image(systemName: "paperclip").font(.title2) }
                    .disabled(model.isSendingFile)
                    .accessibilityLabel("Send a file")
                    .accessibilityIdentifier("file-button")
                if let onStickers {
                    Button(action: onStickers) { Image(systemName: "face.smiling").font(.title2) }
                        .accessibilityLabel("Stickers")
                        .accessibilityIdentifier("sticker-button")
                }
                TextField("Message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("composer")
                Button { Task { await model.send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(!model.canSend)
                    .accessibilityLabel("Send")
            }
        }
        .padding(8)
        .background(.bar)
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
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await model.attachPhoto(data: data, filename: item.itemIdentifier ?? "photo")
            }
        }
    }
}

private struct RowView: View {
    let row: TimelineRow
    let model: TimelineViewModel
    @State private var showingSource = false
    @State private var showingOriginal = false

    /// Long-press menu for confirmed messages: quick reactions, and edit/delete for own messages.
    @ViewBuilder private var actions: some View {
        ForEach(TimelineViewModel.quickReactions, id: \.self) { key in
            Button(key) { Task { await model.toggleReaction(on: row, key: key) } }
        }
        Button("More reactions…", systemImage: "face.smiling") { model.beginReactionPicker(row) }
        Button("Reply", systemImage: "arrowshape.turn.up.left") { model.beginReply(row) }
        if row.source != nil { Button("View source", systemImage: "chevron.left.forwardslash.chevron.right") { showingSource = true } }
        if row.isOwn {
            if row.style == .ownMessage && row.image == nil { Button("Edit", systemImage: "pencil") { model.beginEdit(row) } }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(row) } }
        }
    }

    /// Menu for an own message that couldn't be sent.
    @ViewBuilder private var failedActions: some View {
        Button("Try again", systemImage: "arrow.clockwise") { Task { await model.retry(row) } }
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.discard(row) } }
    }

    var body: some View {
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
                }
                if let image = row.image { ThumbnailView(image: image, model: model, isSticker: row.isSticker).accessibilityLabel(row.isSticker ? row.text : "Image") }
                if let file = row.file { FileTileView(file: file, isOpening: model.openingRow == row.id, model: model) { Task { await model.openFile(row) } } }
                if let card = row.card, !showingOriginal {
                    BotCardView(
                        card: card, state: { model.botRowState(bot: row.source?.sender, id: $0) },
                        tick: { id in Task { await model.tickBotTask(bot: row.source?.sender, id: id) } })
                    Button("Show original") { showingOriginal = true }.font(.caption2)
                } else if row.showsText { Text(row.styled ?? AttributedString(row.text))
                    .padding(8)
                    .background(row.style == .ownMessage ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
                    .opacity(row.status == nil ? 1 : 0.6) }
                if let status = row.status { Text(status).font(.caption2).foregroundStyle(.secondary) }
                if !row.reactions.isEmpty {
                    HStack {
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
            .frame(maxWidth: .infinity, alignment: row.style == .ownMessage ? .trailing : .leading)
            .contextMenu {
                if row.eventID != nil { actions } else if row.failedLocalID != nil { failedActions }
            }
            .sheet(isPresented: $showingSource) { if let source = row.source { MessageSourceView(source: source) } }
            }
        case .notice:
            Text(row.text).font(.callout).foregroundStyle(.secondary)
        case .emote:
            Text(row.text).italic()
        case .placeholder:
            Text(row.text).italic().foregroundStyle(.secondary)
        case .state, .marker:
            Text(row.text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .divider:
            Text(row.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
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
                Rectangle().fill(.secondary.opacity(0.2)).overlay(ProgressView())
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
            #endif
        }
    }

    private struct LoadKey: Equatable {
        let shown: Bool
        let attempt: Int
    }
}

/// A grid of emoji; tapping one reacts to the message the picker was opened for.
private struct ReactionPicker: View {
    let model: TimelineViewModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                ForEach(TimelineViewModel.pickerEmoji, id: \.self) { key in
                    Button(key) { Task { await model.pickReaction(key) } }
                        .font(.title2)
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .accessibilityIdentifier("reactionPicker")
    }
}

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
private struct MessageSourceView: View {
    let source: TimelineRow.Source
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let sender = source.sender { LabeledContent("Sender", value: sender) }
                if let eventID = source.eventID { LabeledContent("Event", value: eventID) }
                Section("Body") { Text(source.body).textSelection(.enabled) }
                if let formatted = source.formattedBody {
                    Section("Formatted body (HTML)") { Text(formatted).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                }
            }
            .navigationTitle("Message source")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
    @State private var data: Data?

    var body: some View {
        AvatarCircle(name: name, imageData: data, size: 28)
            .accessibilityHidden(true)
            .task(id: ref) {
                data = nil
                guard let ref else { return }
                data = await model.avatarData(ref)
            }
    }
}
#endif
