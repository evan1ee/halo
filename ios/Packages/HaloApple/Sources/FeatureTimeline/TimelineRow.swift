import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// One displayed row. Text is prepared here so the view only lays it out.
public struct TimelineRow: Equatable, Identifiable, Sendable {
    public enum Style: Equatable, Sendable { case message, ownMessage, notice, emote, placeholder, state, divider, marker }
    public let id: String
    public let style: Style
    public let sender: String?
    public let text: String
    /// An image to show above the text (the filename or caption), loaded through the view model.
    public let image: Image?
    /// "Sending…" or "Not sent" for an own message that the server hasn't confirmed; `nil` once it is sent.
    public let status: String?
    /// Set for confirmed events only: reactions, edits and deletes need it.
    public let eventID: EventID?
    public let isOwn: Bool
    public let reactions: [Chip]
    /// The quoted message, shown above the text of a reply.
    public let reply: Reply?
    /// Styled text for a message that came with an HTML body; the view shows `text` otherwise.
    public let styled: AttributedString?
    /// The local ID of an own message whose sending failed; the user can retry or delete it.
    public let failedLocalID: String?
    /// A sticker: its image is shown without a bubble or caption (`text` is the accessibility label).
    public let isSticker: Bool
    /// A file, audio or video attachment, shown as a tile that opens in Quick Look (MEDIA_ATTACHMENTS FR-2…4).
    public let file: FileTile?

    /// What "View source" shows for a text message (BOT_MESSAGES FR-1): the sender, the event and both bodies, untouched.
    public struct Source: Equatable, Sendable {
        public let sender: String?
        public let eventID: String?
        public let body: String
        public let formattedBody: String?

        /// Plain-text representation for Copy and Share in "View source".
        public var formattedText: String {
            var parts: [String] = []
            if let sender { parts.append("Sender: \(sender)") }
            if let eventID { parts.append("Event: \(eventID)") }
            parts.append("Body:\n\(body)")
            if let formattedBody { parts.append("Formatted body (HTML):\n\(formattedBody)") }
            return parts.joined(separator: "\n\n")
        }
    }

    /// Set for text messages and notices.
    public let source: Source?
    /// A known bot's message read as a structured card (BOT_MESSAGES Layer 2); `nil` for everything else.
    public let card: BotCard?
    /// The sender's profile picture, for someone else's message; the view shows their initial until it loads.
    public var avatar: MediaRef?
    /// Someone else's message that follows their previous one closely: the view leaves out the name and picture (one group).
    public var continuesRun = false
    /// The last message of a group: the view shows its time (`time`) under it.
    public var endsRun = true
    /// When it was sent, as a short time ("9:41 AM"); set for messages.
    public var time: String?
    /// The text was edited; "View edit history" is offered.
    public var isEdited = false
    /// How many other people's newest read receipt is on this own message (TIMELINE FR-6); 0 for anything else.
    public var seenBy = 0
    /// All of them, for the list behind the avatars; the name is theirs if they wrote in this timeline, else their Matrix ID's name part.
    public var allReaders: [Reader] = []
    /// The first three, for the avatars under the message.
    public var readers: [Reader] { Array(allReaders.prefix(3)) }
    /// "Seen" / "Seen by 3" for the footer of an own message someone has read; `nil` otherwise.
    public var seenLabel: String? { seenBy == 0 ? nil : seenBy == 1 ? "Seen" : "Seen by \(seenBy)" }

    public struct Reader: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let avatar: MediaRef?
    }

    public struct FileTile: Equatable, Sendable {
        public let kind: MediaKind
        public let name: String
        /// For example "PDF · 1.2 MB" or "0:42 · 3.4 MB".
        public let detail: String
        public let ref: MediaRef
        public let size: Int?
        /// A video's own still picture, shown above the tile (when the sender attached one).
        public let thumbnail: Image?
    }

    /// Whether the row shows its `text` in a bubble. A sticker never does, nor does a file tile, and neither does an image whose
    /// body is just its file name ("photo.jpg", which clients put in `body` when there is no caption); a real caption is shown.
    public var showsText: Bool { !isSticker && file == nil && !(image != nil && Self.looksLikeFilename(text)) }

    /// Whether a plain text message consists solely of 1–3 native Unicode emoji and renders jumbo-sized without a bubble fill.
    public var isJumboEmoji: Bool {
        showsText && image == nil && file == nil && card == nil && NativeEmoji.isEmojiOnly(text, maxCount: 3)
    }

    /// The KLIPY GIF or sticker this message is, when its whole text is one KLIPY media link (COMPOSER_PANELS §6, D98).
    public var klipyURL: URL? {
        guard style == .message || style == .ownMessage, showsText, image == nil, card == nil else { return nil }
        return KlipyLink.mediaURL(in: text)
    }

    /// Whether the user can edit this row's text (own confirmed text message; never photos, files or stickers).
    public var canEdit: Bool { isOwn && style == .ownMessage && eventID != nil && image == nil && file == nil && !isSticker }

    static func looksLikeFilename(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex else { return false }
        let ext = trimmed[trimmed.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.contains(where: \.isLetter)
    }

    public struct Reply: Equatable, Sendable {
        /// The quoted message, so a tap can scroll to it when it is in the loaded timeline (TIMELINE FR-8).
        public let eventID: EventID?
        public let sender: String?
        /// `nil` when the original isn't available; the view then says so.
        public let snippet: String?
    }

    public struct Chip: Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let count: Int
        public let reactedByMe: Bool
    }

    public struct Image: Equatable, Sendable {
        public let ref: MediaRef
        /// Width / height, when the sender gave dimensions; the view falls back to 4:3.
        public let aspectRatio: Double?
        /// Optional BlurHash placeholder string (`xyz.amorgan.blurhash`), when provided by the sender.
        public let blurhash: String?

        public init(ref: MediaRef, aspectRatio: Double?, blurhash: String? = nil) {
            self.ref = ref
            self.aspectRatio = aspectRatio
            self.blurhash = blurhash
        }
    }

    init(
        id: String, style: Style, sender: String?, text: String, image: Image? = nil, status: String? = nil,
        eventID: EventID? = nil, isOwn: Bool = false, reactions: [Chip] = [], reply: Reply? = nil, styled: AttributedString? = nil,
        failedLocalID: String? = nil, isSticker: Bool = false, file: FileTile? = nil, source: Source? = nil, card: BotCard? = nil
    ) {
        self.card = card
        self.source = source
        self.file = file
        self.failedLocalID = failedLocalID
        self.isSticker = isSticker
        self.styled = styled
        self.reply = reply
        self.eventID = eventID
        self.isOwn = isOwn
        self.reactions = reactions
        self.status = status
        self.id = id
        self.style = style
        self.sender = sender
        self.text = text
        self.image = image
    }
}

/// Presents one room's timeline from `TimelineCoordinator` (docs/features/TIMELINE.md). M1: read-only.
