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

struct RowView: View {
    let row: TimelineRow
    let model: TimelineViewModel
    let onOpenThread: ((EventID) -> Void)?
    let onOpenPhoto: ((String) -> Void)?
    @State private var showingSource = false
    @State private var showingReaders = false
    /// A sent message is removed for everyone and can't be brought back: ask first.
    @State private var confirmingDelete = false
    @State private var showingOriginal = false
    @State private var reactionHaptic = 0
    @State private var replyHaptic = 0

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
                                card: card,
                                state: { id in
                                    switch model.botRowState(bot: row.source?.sender, id: id) {
                                    case .open: .open
                                    case .pending: .pending
                                    case .completed: .completed
                                    case .noResponse: .noResponse
                                    case .unavailable: .unavailable
                                    }
                                },
                                tick: { id in Task { await model.tickBotTask(bot: row.source?.sender, id: id) } })
                            Button("Show original") { showingOriginal = true }.font(.caption2)
                        } else if let url = row.klipyURL, model.showsKlipyMedia {
                            KlipyMessageMedia(url: url, model: model)
                                .opacity(row.status == nil ? 1 : 0.6)
                        } else if row.isJumboEmoji {
                            Text(row.text)
                                .font(.largeTitle)
                                .padding(.vertical, HaloSpacing.xxs)
                                .opacity(row.status == nil ? 1 : 0.6)
                                .modifier(OptionalTextDragModifier(text: TimelineDragExtractor.text(for: row)))
                        } else if row.showsText {
                            Text(row.styled ?? AttributedString(row.text))
                                .padding(HaloSpacing.s)
                                .background(row.style == .ownMessage ? HaloColor.bubbleOwn : HaloColor.bubbleOther, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
                                .opacity(row.status == nil ? 1 : 0.6)
                                .modifier(OptionalTextDragModifier(text: TimelineDragExtractor.text(for: row)))
                            if row.card != nil { Button("Show card") { showingOriginal = false }.font(.caption2) }
                        }
                        if row.delivery != nil || (row.endsRun && row.time != nil) {
                            HStack(spacing: HaloSpacing.xs) {
                                if case .failed = row.delivery, let status = row.status {
                                    Text(status).font(.caption2).foregroundStyle(HaloColor.danger)
                                } else if row.endsRun, let time = row.time {
                                    Text(time).font(.caption2).foregroundStyle(HaloColor.textSecondary)
                                }
                                if let delivery = row.delivery {
                                    DeliveryIndicator(delivery: delivery, row: row, model: model) { showingReaders = true }
                                }
                            }
                        }
                        reactionBar
                    }
                    .frame(maxWidth: .infinity, alignment: row.style == .ownMessage ? .trailing : .leading)
                    .contextMenu {
                        if row.eventID != nil { actions } else if row.failedLocalID != nil { failedActions }
                    }
                    .accessibilityActions {
                        if row.eventID != nil {
                            Button("Reply") { model.beginReply(row) }
                            Button("React thumbs up") { Task { await model.toggleReaction(on: row, key: "👍") } }
                            Button("More reactions") { model.beginReactionPicker(row) }
                            if row.isOwn {
                                if row.canEdit { Button("Edit") { model.beginEdit(row) } }
                                Button("Delete") { confirmingDelete = true }
                            }
                        } else if row.failedLocalID != nil {
                            Button("Try again") { Task { await model.retry(row) } }
                            Button("Delete") { Task { await model.discard(row) } }
                        }
                    }
                }
                .padding(row.style == .ownMessage ? .leading : .trailing, 48)
            case .notice:
                VStack(alignment: .leading, spacing: 2) {
                    if let card = row.card, !showingOriginal {
                        BotCardView(
                            card: card,
                            state: { id in
                                switch model.botRowState(bot: row.source?.sender, id: id) {
                                case .open: .open
                                case .pending: .pending
                                case .completed: .completed
                                case .noResponse: .noResponse
                                case .unavailable: .unavailable
                                }
                            },
                            tick: { id in Task { await model.tickBotTask(bot: row.source?.sender, id: id) } })
                        Button("Show original") { showingOriginal = true }.font(.caption2)
                    } else {
                        Text(row.styled ?? AttributedString(row.text)).font(.callout).foregroundStyle(.secondary)
                            .modifier(OptionalTextDragModifier(text: TimelineDragExtractor.text(for: row)))
                        if row.card != nil { Button("Show card") { showingOriginal = false }.font(.caption2) }
                    }
                    reactionBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { if row.eventID != nil { actions } }
            case .emote:
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.text).italic()
                        .modifier(OptionalTextDragModifier(text: TimelineDragExtractor.text(for: row)))
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
        .onTapGesture(count: 2) {
            guard row.eventID != nil else { return }
            reactionHaptic += 1
            Task { await model.toggleReaction(on: row, key: "👍") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if row.eventID != nil {
                Button {
                    replyHaptic += 1
                    model.beginReply(row)
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .tint(HaloColor.accent)
            }
        }
        .haloFeedback(.reaction, trigger: reactionHaptic)
        .haloFeedback(.swipeThreshold, trigger: replyHaptic)
        .confirmationDialog("Delete this message for everyone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.delete(row) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It can't be undone.") }
    }
}

/// An image row's thumbnail; shows a neutral box while loading or if the download failed.
/// Photos fit within 240 pt; a sticker is shown in a fixed 200 pt box (the picture's own size is small and mustn't decide).

struct SenderAvatar: View {
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
struct ReadersView: View {
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

/// The state of an own message beside its time, the same for every kind of message (TIMELINE FR-6): a small spinner while it
/// is sending, a circle with a check once the server has it, the readers' pictures (tap for the list) once someone has read
/// it, and a warning while it isn't sent. Unconfirmed things look unconfirmed (AGENTS §4.4).
struct DeliveryIndicator: View {
    let delivery: TimelineRow.Delivery
    let row: TimelineRow
    let model: TimelineViewModel
    let showReaders: () -> Void
    private let size: CGFloat = 14

    var body: some View {
        switch delivery {
        case .sending:
            ProgressView()
                .controlSize(.mini)
                .frame(width: size, height: size)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sending")
                .accessibilityIdentifier("delivery-sending")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(HaloColor.danger)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.status ?? "Not sent")
                .accessibilityIdentifier("delivery-failed")
        case .sent:
            Image(systemName: "checkmark.circle")
                .font(.system(size: size))
                .foregroundStyle(HaloColor.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sent")
                .accessibilityIdentifier("delivery-sent")
        case .read:
            Button(action: showReaders) { ReceiptAvatars(row: row, model: model) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("delivery-read")
        }
    }
}

/// Up to three small pictures of the people who have read up to this message, and "+N" for the rest (TIMELINE FR-6).
struct ReceiptAvatars: View {
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

/// Wraps reaction chips onto multiple lines, aligned to the message's own side (leading for incoming, trailing for own).
struct ReactionFlowLayout: Layout {
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
#endif
