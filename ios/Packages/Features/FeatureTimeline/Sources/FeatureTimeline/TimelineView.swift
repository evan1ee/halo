#if canImport(SwiftUI)
import HaloDomain
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct TimelineView: View {
    private let model: TimelineViewModel

    public init(model: TimelineViewModel) { self.model = model }

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
                        // Re-runs whenever rows change, so loading continues until the start marker arrives.
                        .task(id: rows.count) { if paginationError == nil { await model.loadEarlier() } }
                    }
                    ForEach(rows) { row in RowView(row: row, model: model).listRowSeparator(.hidden) }
                }
                .listStyle(.plain)
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("timeline")
                // A newer last row (own echo or incoming message) scrolls into view. Earlier history prepended at the
                // top doesn't change the last row, so reading old messages isn't disturbed.
                .onChange(of: rows.last?.id) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { Composer(model: model) }
        .sheet(isPresented: Binding(get: { model.reactionTarget != nil }, set: { if !$0 { model.cancelReactionPicker() } })) {
            ReactionPicker(model: model).presentationDetents([.medium])
        }
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }
}

private struct Composer: View {
    @Bindable var model: TimelineViewModel

    var body: some View {
        VStack(spacing: 4) {
            if let typing = model.typingText { Text(typing).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            if let error = model.sendError { Text(error).font(.caption).foregroundStyle(.red) }
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
            HStack(alignment: .bottom) {
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
    }
}

private struct RowView: View {
    let row: TimelineRow
    let model: TimelineViewModel

    /// Long-press menu for confirmed messages: quick reactions, and edit/delete for own messages.
    @ViewBuilder private var actions: some View {
        ForEach(TimelineViewModel.quickReactions, id: \.self) { key in
            Button(key) { Task { await model.toggleReaction(on: row, key: key) } }
        }
        Button("More reactions…", systemImage: "face.smiling") { model.beginReactionPicker(row) }
        Button("Reply", systemImage: "arrowshape.turn.up.left") { model.beginReply(row) }
        if row.isOwn {
            if row.style == .ownMessage && row.image == nil { Button("Edit", systemImage: "pencil") { model.beginEdit(row) } }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(row) } }
        }
    }

    var body: some View {
        switch row.style {
        case .message, .ownMessage:
            VStack(alignment: row.style == .ownMessage ? .trailing : .leading, spacing: 2) {
                if let sender = row.sender, row.style == .message { Text(sender).font(.caption).foregroundStyle(.secondary) }
                if let reply = row.reply {
                    VStack(alignment: .leading, spacing: 0) {
                        if let name = reply.sender { Text(name).font(.caption2.bold()) }
                        Text(reply.snippet ?? "Original message unavailable").font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
                }
                if let image = row.image { ThumbnailView(image: image, model: model) }
                Text(row.styled ?? AttributedString(row.text))
                    .padding(8)
                    .background(row.style == .ownMessage ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
                    .opacity(row.status == nil ? 1 : 0.6)
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
            .contextMenu { if row.eventID != nil { actions } }
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
private struct ThumbnailView: View {
    let image: TimelineRow.Image
    let model: TimelineViewModel
    @State private var data: Data?

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().scaledToFit()
            } else {
                Rectangle().fill(.secondary.opacity(0.2)).overlay(ProgressView())
            }
            #else
            Rectangle().fill(.secondary.opacity(0.2))
            #endif
        }
        .aspectRatio(image.aspectRatio ?? 4 / 3, contentMode: .fit)
        .frame(maxWidth: 240)
        .clipShape(.rect(cornerRadius: 12))
        .task { data = await model.thumbnail(for: image) }
    }
}
#endif

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
