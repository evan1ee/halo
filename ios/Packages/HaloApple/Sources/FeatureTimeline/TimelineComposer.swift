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
    @State private var voice = VoiceRecorder()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasAccessoryRows: Bool {
        model.typingText != nil || !model.identityNotices.isEmpty || model.sendError != nil || model.isSendingImage || model.isSendingFile || model.editing != nil
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

    /// Telegram's layout in Halo's look: paperclip · field (face/keyboard toggle inside) · one round button on the right —
    /// send once there is something to send, else the mic, or ↑ / ↓ to pull an open panel up to a tall sheet and back.
    /// Send sits outside the field so a long message keeps the field's width (founder: "right side … is empty").
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: HaloSpacing.s) {
            ComposerCircleButton(systemImage: "paperclip", label: "Attach") { input.toggle(.attachments) }
                .accessibilityIdentifier("attachment-button")
                .accessibilityValue(input.state.panel == .attachments ? "Open" : "")

            HStack(alignment: .bottom, spacing: 0) {
                if voice.isRecording {
                    recordingField
                } else {
                    TextField("Message", text: $model.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .padding(.vertical, 11)
                        .padding(.leading, HaloSpacing.l)
                        .accessibilityIdentifier("composer")
                        // A pasted image joins the pending photos; its placeholder never stays in the draft.
                        .background {
                            ComposerImagePaste { images in
                                guard model.canSendImages else { return }
                                Task { await model.attachPhotos(images.map { (data: $0, filename: "pasted") }) }
                            }
                            .allowsHitTesting(false)
                        }
                        .onChange(of: model.draft) { _, draft in
                            if draft.contains(ComposerImagePaste.placeholder) {
                                model.draft.removeAll { $0 == ComposerImagePaste.placeholder }
                            }
                        }
                    Button { input.toggle(.expression) } label: {
                        Image(systemName: input.state.showsKeyboardToggle(for: .expression) ? "keyboard" : "face.smiling")
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
            }
            .frame(minHeight: 44)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if ComposerMotionTrace.isEnabled { ComposerMotionTrace().frame(width: 1, height: 1) }
            }
            #endif

            if voice.isRecording {
                ComposerCircleButton(systemImage: "arrow.up", label: "Send voice message", prominent: true) { sendVoice() }
                    .accessibilityIdentifier("voice-send-button")
                    .transition(.scale.combined(with: .opacity))
            } else if model.canSend {
                ComposerCircleButton(systemImage: "paperplane.fill", label: "Send", prominent: true) {
                    sendTrigger += 1
                    Task { await model.send() }
                }
                .accessibilityIdentifier("send-button")
                .transition(.scale.combined(with: .opacity))
            } else {
                ComposerCircleButton(systemImage: trailingSymbol, label: trailingLabel) { trailingTapped() }
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityIdentifier(input.state.panel != nil ? "panel-expand-button" : "voice-button")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.canSend)
        .animation(.snappy(duration: 0.2), value: voice.isRecording)
        .alert("Microphone access is off", isPresented: Binding(get: { voice.phase == .denied }, set: { if !$0 { voice.dismissProblem() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("To record voice messages, allow Halo to use the microphone in Settings.")
        }
    }

    /// The right button: ↑ / ↓ while a panel is open, the mic otherwise.
    private var trailingSymbol: String {
        guard input.state.panel != nil else { return "mic" }
        return input.state.panelExpanded ? "chevron.down" : "chevron.up"
    }

    private var trailingLabel: String {
        guard input.state.panel != nil else { return "Record voice message" }
        return input.state.panelExpanded ? "Shrink panel" : "Expand panel"
    }

    private func trailingTapped() {
        if input.state.panel != nil {
            input.toggleExpanded()
        } else {
            Task { await voice.start() }
        }
    }

    /// While recording, the field shows a red dot, the time and Cancel.
    private var recordingField: some View {
        HStack(spacing: HaloSpacing.s) {
            Circle().fill(HaloColor.danger).frame(width: 10, height: 10)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            Text(VoiceRecorder.clock(voice.elapsed))
                .font(HaloTypography.body.monospacedDigit())
                .foregroundStyle(HaloColor.textPrimary)
                .accessibilityLabel("Recording, \(VoiceRecorder.clock(voice.elapsed))")
            Spacer()
            Button("Cancel") { voice.cancel() }
                .font(HaloTypography.bodyEmphasis)
                .foregroundStyle(HaloColor.danger)
                .accessibilityIdentifier("voice-cancel-button")
        }
        .padding(.horizontal, HaloSpacing.l)
        .frame(minHeight: 44)
    }

    private func sendVoice() {
        guard let recording = voice.finish() else { return }
        sendTrigger += 1
        Task { await model.sendFile(data: recording.data, filename: "Voice message.m4a", mimeType: "audio/mp4") }
    }

    // MARK: Accessory rows (typing, errors, edit/reply, suggestions, pending photos)

    @ViewBuilder private var accessoryRows: some View {
        VStack(spacing: HaloSpacing.xs) {
            if let typing = model.typingText {
                Text(typing).font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(model.identityNotices) { notice in
                VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                    Label(notice.text, systemImage: notice.isSerious ? "exclamationmark.shield.fill" : "exclamationmark.shield")
                        .font(HaloTypography.caption)
                        .foregroundStyle(notice.isSerious ? HaloColor.danger : HaloColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(notice.actionTitle) { Task { await model.acceptIdentity(of: notice.user) } }
                        .font(HaloTypography.caption)
                        .accessibilityIdentifier("identity-accept-button")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("identity-notice")
                .frame(maxWidth: .infinity, alignment: .leading)
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
                            DecodedImage(photo.data, maxPixel: ImagePipeline.Size.listRow) { image in
                                image.resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(.rect(cornerRadius: HaloRadius.small, style: .continuous))
                            } placeholder: { Color.clear.frame(width: 56, height: 56) }
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
