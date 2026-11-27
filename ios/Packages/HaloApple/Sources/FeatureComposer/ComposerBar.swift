#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Snapshot of pending photo bytes shown in the composer strip before sending (M13, ADR-0022).
public struct ComposerPendingPhoto: Identifiable, Sendable {
    public let id: Int
    public let data: Data

    public init(id: Int, data: Data) {
        self.id = id
        self.data = data
    }
}

/// Pure helper rules for the message composer (line limits, send eligibility, paste validation).
public enum ComposerRules {
    public static let maxLineCount = 6

    public static func canSend(draft: String, pendingPhotoCount: Int, isBusy: Bool) -> Bool {
        guard !isBusy else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingPhotoCount > 0
    }
}

/// Messages-style timeline composer bar with 6-line growth, attachment menu, paste-image support,
/// mention/emoji suggestions, and send haptic (`docs/design/SCREEN_SPECIFICATIONS.md` S4, M13, ADR-0022).
public struct ComposerBarView: View {
    @Binding private var draft: String
    private let canSend: Bool
    private let canSendImages: Bool
    private let isSendingImage: Bool
    private let isSendingFile: Bool
    private let typingText: String?
    private let sendError: String?
    private let isEditing: Bool
    private let replyTargetName: String?
    private let mentionSuggestions: [RoomMember]
    private let emojiSuggestions: [NativeEmoji.Entry]
    private let pendingPhotos: [ComposerPendingPhoto]
    private let maxPendingPhotos: Int

    private let onSend: () -> Void
    private let onAddPhotoData: (Data) -> Void
    private let onChooseFile: () -> Void
    private let onOpenEmojiPicker: () -> Void
    private let onOpenStickers: (() -> Void)?
    private let onDismissError: () -> Void
    private let onCancelEdit: () -> Void
    private let onCancelReply: () -> Void
    private let onPickMention: (RoomMember) -> Void
    private let onPickEmoji: (NativeEmoji.Entry) -> Void
    private let onRemovePendingPhoto: (Int) -> Void

    @State private var showingPhotoPicker = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var sendTrigger = 0

    public init(
        draft: Binding<String>,
        canSend: Bool,
        canSendImages: Bool,
        isSendingImage: Bool,
        isSendingFile: Bool,
        typingText: String?,
        sendError: String?,
        isEditing: Bool,
        replyTargetName: String?,
        mentionSuggestions: [RoomMember],
        emojiSuggestions: [NativeEmoji.Entry],
        pendingPhotos: [ComposerPendingPhoto],
        maxPendingPhotos: Int,
        onSend: @escaping () -> Void,
        onAddPhotoData: @escaping (Data) -> Void,
        onChooseFile: @escaping () -> Void,
        onOpenEmojiPicker: @escaping () -> Void,
        onOpenStickers: (() -> Void)? = nil,
        onDismissError: @escaping () -> Void,
        onCancelEdit: @escaping () -> Void,
        onCancelReply: @escaping () -> Void,
        onPickMention: @escaping (RoomMember) -> Void,
        onPickEmoji: @escaping (NativeEmoji.Entry) -> Void,
        onRemovePendingPhoto: @escaping (Int) -> Void
    ) {
        _draft = draft
        self.canSend = canSend
        self.canSendImages = canSendImages
        self.isSendingImage = isSendingImage
        self.isSendingFile = isSendingFile
        self.typingText = typingText
        self.sendError = sendError
        self.isEditing = isEditing
        self.replyTargetName = replyTargetName
        self.mentionSuggestions = mentionSuggestions
        self.emojiSuggestions = emojiSuggestions
        self.pendingPhotos = pendingPhotos
        self.maxPendingPhotos = maxPendingPhotos
        self.onSend = onSend
        self.onAddPhotoData = onAddPhotoData
        self.onChooseFile = onChooseFile
        self.onOpenEmojiPicker = onOpenEmojiPicker
        self.onOpenStickers = onOpenStickers
        self.onDismissError = onDismissError
        self.onCancelEdit = onCancelEdit
        self.onCancelReply = onCancelReply
        self.onPickMention = onPickMention
        self.onPickEmoji = onPickEmoji
        self.onRemovePendingPhoto = onRemovePendingPhoto
    }

    public var body: some View {
        VStack(spacing: HaloSpacing.xs) {
            if let typingText {
                Text(typingText)
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let sendError {
                HaloBanner(tone: .danger, icon: "exclamationmark.triangle.fill", message: sendError, onDismiss: onDismissError)
            }
            if isSendingImage { ProgressView("Sending photo…").font(HaloTypography.caption) }
            if isSendingFile { ProgressView("Sending file…").font(HaloTypography.caption) }
            if isEditing {
                HStack {
                    Label("Editing message", systemImage: "pencil").font(HaloTypography.caption)
                    Spacer()
                    Button("Cancel", action: onCancelEdit).font(HaloTypography.caption)
                }
            }
            if let replyTargetName {
                HStack {
                    Label("Replying to \(replyTargetName)", systemImage: "arrowshape.turn.up.left")
                        .font(HaloTypography.caption)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel", action: onCancelReply).font(HaloTypography.caption)
                }
            }
            mentionList
            emojiSuggestionStrip
            pendingPhotoStrip
            inputRow
        }
        .padding(.horizontal, HaloSpacing.m)
        .padding(.vertical, HaloSpacing.s)
        .background(.bar)
        .haloFeedback(.send, trigger: sendTrigger)
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $picked,
            maxSelectionCount: max(1, maxPendingPhotos - pendingPhotos.count),
            matching: .images
        )
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {  // best-effort: an item the picker can't read is skipped
                        onAddPhotoData(data)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mentionList: some View {
        ForEach(mentionSuggestions) { member in
            Button { onPickMention(member) } label: {
                HStack {
                    Text(member.mentionName)
                    Spacer()
                    Text(member.user.rawValue)
                        .font(HaloTypography.caption)
                        .foregroundStyle(HaloColor.textSecondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mention-suggestion")
        }
    }

    @ViewBuilder
    private var emojiSuggestionStrip: some View {
        if !emojiSuggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HaloSpacing.s) {
                    ForEach(emojiSuggestions) { entry in
                        Button { onPickEmoji(entry) } label: {
                            HStack(spacing: HaloSpacing.xs) {
                                Text(entry.emoji)
                                Text(":\(entry.shortcode):")
                                    .font(HaloTypography.caption)
                                    .foregroundStyle(HaloColor.textSecondary)
                            }
                            .padding(.horizontal, HaloSpacing.s)
                            .padding(.vertical, HaloSpacing.xs)
                            .background(HaloColor.bgSecondary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("emoji-suggestion")
                    }
                }
                .padding(.horizontal, HaloSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private var pendingPhotoStrip: some View {
        if !pendingPhotos.isEmpty {
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HaloSpacing.s) {
                        ForEach(pendingPhotos) { photo in
                            ZStack(alignment: .topTrailing) {
                                #if canImport(UIKit)
                                DecodedImage(photo.data, maxPixel: ImagePipeline.Size.listRow) { image in
                                    image.resizable().scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous))
                                } placeholder: { Color.clear.frame(width: 56, height: 56) }
                                #else
                                RoundedRectangle(cornerRadius: HaloRadius.small)
                                    .fill(HaloColor.bgSecondary)
                                    .frame(width: 56, height: 56)
                                #endif
                                Button { onRemovePendingPhoto(photo.id) } label: {
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
                Text(
                    pendingPhotos.count == 1
                        ? "Photo ready. Add a caption below, or send as is."
                        : "\(pendingPhotos.count) photos ready. Add a caption below, or send as is."
                )
                .font(HaloTypography.caption)
                .foregroundStyle(HaloColor.textSecondary)
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: HaloSpacing.m) {
            attachmentMenu
            Button(action: onOpenEmojiPicker) {
                Image(systemName: "face.smiling")
                    .font(.title3)
                    .foregroundStyle(HaloColor.textSecondary)
            }
            .accessibilityLabel("Emoji")
            .accessibilityIdentifier("emoji-button")

            HStack(alignment: .bottom, spacing: HaloSpacing.xs) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...ComposerRules.maxLineCount)
                    .textFieldStyle(.plain)
                    .padding(.vertical, HaloSpacing.s)
                    .padding(.leading, 14)
                    .padding(.trailing, canSend ? 0 : 14)
                    .accessibilityIdentifier("composer")
                if canSend {
                    Button {
                        sendTrigger += 1
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(HaloColor.onAccent, HaloColor.accent)
                    }
                    .padding(3)
                    .accessibilityLabel("Send")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(minHeight: 36)
            .background(.background, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous).strokeBorder(.separator))
        }
    }

    private var attachmentMenu: some View {
        Menu {
            if canSendImages {
                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("Photos", systemImage: "photo")
                }
                .disabled(isSendingImage || pendingPhotos.count >= maxPendingPhotos)
                .accessibilityIdentifier("photo-button")
            }
            Button(action: onChooseFile) {
                Label("Files", systemImage: "paperclip")
            }
            .disabled(isSendingFile)
            .accessibilityIdentifier("file-button")
            #if canImport(UIKit)
            if canSendImages, UIPasteboard.general.hasImages {
                Button {
                    if let image = UIPasteboard.general.image, let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9) {
                        onAddPhotoData(data)
                    }
                } label: {
                    Label("Paste image", systemImage: "doc.on.clipboard")
                }
            }
            #endif
            if let onOpenStickers {
                Button(action: onOpenStickers) {
                    Label("Stickers", systemImage: "sparkles.rectangle.stack")
                }
                .accessibilityIdentifier("sticker-button")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(HaloColor.accent)
        }
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("attachment-menu")
    }
}
#endif
