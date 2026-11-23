#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// The message composer (docs/features/COMPOSER_PANELS.md §2, D97): an attach button, the message field with the
/// emoji/sticker/GIF toggle inside it, and a send button once there is something to send.
///
/// It is independent of the panels: it only reads the input mode for its two toggle icons and sends events to the
/// `ComposerInputController` (focus changes, toggle taps). The panels are drawn by `TimelineView` under it.
struct Composer: View {
    @Bindable var model: TimelineViewModel
    let input: ComposerInputController
    @Binding var choosingFile: Bool
    @FocusState private var focused: Bool
    @State private var sendTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasAccessoryRows: Bool {
        model.typingText != nil || model.sendError != nil || model.isSendingImage || model.isSendingFile || model.editing != nil
            || model.replyingTo != nil || !model.mentionSuggestions.isEmpty || !model.emojiSuggestions.isEmpty || !model.pendingPhotos.isEmpty
    }

    var body: some View {
        VStack(spacing: HaloSpacing.s) {
            if hasAccessoryRows {
                accessoryRows
                    .padding(HaloSpacing.s)
                    .glassEffect(.regular, in: .rect(cornerRadius: HaloRadius.bubble, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            inputRow
        }
        .padding(.horizontal, HaloSpacing.s)
        .padding(.top, HaloSpacing.xs)
        .padding(.bottom, HaloSpacing.s)
        .animation(HaloMotion.standard(reduceMotion: reduceMotion), value: hasAccessoryRows)
        .haloFeedback(.send, trigger: sendTrigger)
        .onChange(of: focused) { _, isFocused in input.fieldFocusChanged(isFocused) }
        .onChange(of: input.state.wantsFieldFocus) { _, wants in if focused != wants { focused = wants } }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task { await Self.sendPickedFile(url, model: model) }
        }
    }

    // MARK: Input row

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: HaloSpacing.s) {
            ComposerCircleButton(
                systemImage: input.state.showsKeyboardToggle(for: .attachments) ? "keyboard" : "paperclip",
                label: input.state.showsKeyboardToggle(for: .attachments) ? "Show keyboard" : "Attach"
            ) { input.toggle(.attachments) }
                .accessibilityIdentifier("attachment-button")

            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.vertical, 11)
                    .padding(.leading, HaloSpacing.l)
                    .accessibilityIdentifier("composer")
                Button { input.toggle(.expression) } label: {
                    Image(systemName: expressionSymbol)
                        .font(HaloTypography.title)
                        .foregroundStyle(HaloColor.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(input.state.showsKeyboardToggle(for: .expression) ? "Show keyboard" : "Emoji, stickers and GIFs")
                .accessibilityIdentifier("sticker-button")
            }
            .frame(minHeight: 44)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))

            if model.canSend {
                ComposerCircleButton(systemImage: "arrow.up", label: "Send", prominent: true) {
                    sendTrigger += 1
                    Task { await model.send() }
                }
                .accessibilityIdentifier("send-button")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.canSend)
    }

    /// Keyboard while the expression panel is open; a smiley while typing; the sticker symbol on an empty field.
    private var expressionSymbol: String {
        if input.state.showsKeyboardToggle(for: .expression) { return "keyboard" }
        return model.draft.isEmpty ? "sparkles.rectangle.stack" : "face.smiling"
    }

    // MARK: Accessory rows (typing, errors, edit/reply, suggestions, pending photos)

    @ViewBuilder private var accessoryRows: some View {
        VStack(spacing: HaloSpacing.xs) {
            if let typing = model.typingText {
                Text(typing).font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.sendError {
                HStack(spacing: HaloSpacing.s) {
                    Text(error).font(HaloTypography.caption).foregroundStyle(HaloColor.danger)
                    Spacer()
                    Button { model.dismissSendError() } label: { Image(systemName: "xmark").font(HaloTypography.caption) }
                        .buttonStyle(.plain)
                        .foregroundStyle(HaloColor.textSecondary)
                        .accessibilityLabel("Dismiss")
                }
            }
            if model.isSendingImage { ProgressView("Sending photo…").font(HaloTypography.caption) }
            if model.isSendingFile { ProgressView("Sending file…").font(HaloTypography.caption) }
            if model.editing != nil {
                HStack {
                    Label("Editing message", systemImage: "pencil").font(HaloTypography.caption)
                    Spacer()
                    Button("Cancel") { model.cancelEdit() }.font(HaloTypography.caption)
                }
            }
            if let target = model.replyingTo {
                HStack {
                    Label("Replying to \(target.sender ?? "message")", systemImage: "arrowshape.turn.up.left").font(HaloTypography.caption).lineLimit(1)
                    Spacer()
                    Button("Cancel") { model.cancelReply() }.font(HaloTypography.caption)
                }
            }
            ForEach(model.mentionSuggestions) { member in
                Button { model.pickMention(member) } label: {
                    HStack {
                        Text(member.mentionName)
                        Spacer()
                        Text(member.user.rawValue).font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mention-suggestion")
            }
            if !model.emojiSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HaloSpacing.s) {
                        ForEach(model.emojiSuggestions) { entry in
                            Button { model.pickEmojiSuggestion(entry) } label: {
                                HStack(spacing: HaloSpacing.xs) {
                                    Text(entry.emoji)
                                    Text(":\(entry.shortcode):").font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary)
                                }
                                .padding(.horizontal, HaloSpacing.s).padding(.vertical, HaloSpacing.xs)
                                .background(HaloColor.textSecondary.opacity(0.15), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("emoji-suggestion")
                        }
                    }
                }
            }
            if !model.pendingPhotos.isEmpty { pendingPhotoStrip }
        }
    }

    private var pendingPhotoStrip: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HaloSpacing.s) {
                    ForEach(Array(model.pendingPhotos.enumerated()), id: \.offset) { index, photo in
                        ZStack(alignment: .topTrailing) {
                            #if canImport(UIKit)
                            if let image = UIImage(data: photo.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(.rect(cornerRadius: HaloRadius.small, style: .continuous))
                            }
                            #endif
                            Button { model.removePendingPhoto(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(HaloTypography.caption)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(HaloColor.mediaOverlayForeground, HaloColor.mediaOverlayBackground)
                            }
                            .offset(x: 4, y: -4)
                            .accessibilityLabel("Remove photo")
                            .accessibilityIdentifier("remove-photo")
                        }
                        .padding(.top, HaloSpacing.xs)
                    }
                }
                .padding(.horizontal, HaloSpacing.xs)
            }
            Text(model.pendingPhotos.count == 1
                 ? "Photo ready. Add a caption below, or send as is."
                 : "\(model.pendingPhotos.count) photos ready. Add a caption below, or send as is.")
                .font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary)
        }
    }

    /// Reads a file picked in Files (inside its security scope, size checked before reading) and sends it as is.
    static func sendPickedFile(_ url: URL, model: TimelineViewModel) async {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= OutgoingFile.maximumBytes else { model.reportFileTooLarge(); return }
        guard let data = try? Data(contentsOf: url) else { model.reportFileUnreadable(); return }
        let type = UTType(filenameExtension: url.pathExtension)
        await model.sendFile(data: data, filename: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
    }
}
#endif
