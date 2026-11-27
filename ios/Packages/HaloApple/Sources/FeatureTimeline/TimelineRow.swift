import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// One displayed row. Text is prepared here so the view only lays it out.
public struct TimelineRow: Equatable, Identifiable, Sendable {
    public enum Style: Equatable, Sendable { case message, ownMessage, notice, emote, placeholder, state, divider, marker }

    /// A message of the conversation (not a room event, divider or marker).
    public var isConversation: Bool { [.message, .ownMessage, .notice, .emote, .placeholder].contains(style) }
    public let id: String
    public let style: Style
    public let sender: String?
    public let text: String
    /// An image to show above the text (the filename or caption), loaded through the view model.
    public let image: Image?
    /// "Sending…" or "Not sent" for an own message that the server hasn't confirmed; `nil` once it is sent.
    public var status: String?
    /// The state of an own message for the indicator beside its time, the same for text, photos, files and stickers
    /// (TIMELINE FR-6); `nil` for everyone else's messages and for room events.
    public var delivery: Delivery?

    /// Telegram-style: sending is a small spinner, sent a circle with a check, read the readers' pictures instead of the check.
    public enum Delivery: Equatable, Sendable {
        case sending
        /// `recoverable`: the send queue will retry by itself.
        case failed(recoverable: Bool)
        case sent
        /// Someone has read up to this message (`seenBy` > 0).
        case read

        init(sendState: SendState, readCount: Int) {
            switch sendState {
            case .sending: self = .sending
            case .failed(let recoverable): self = .failed(recoverable: recoverable)
            case .sent: self = readCount > 0 ? .read : .sent
            }
        }
    }
    /// Set for confirmed events only: reactions, edits and deletes need it.
    public let eventID: EventID?
    public let isOwn: Bool
    public let reactions: [Chip]
    /// The quoted message, shown above the text of a reply.
    public let reply: Reply?
    /// Styled text for a message that came with an HTML body; the view shows `text` otherwise.
    public let styled: AttributedString?
    /// The local ID of an own message whose sending failed; the user can retry or delete it.
    public var failedLocalID: String?
    /// What the person can do about a failed message beyond retrying: send it anyway after accepting the risk (AC-SEC-2).
    public var canSendAnyway = false
    /// A sticker: its image is shown without a bubble or caption (`text` is the accessibility label).
    public let isSticker: Bool
    /// A file attachment, shown as a tile that opens in Quick Look (MEDIA_ATTACHMENTS FR-4).
    public let file: FileTile?
    /// An audio file or voice message, played inline in the bubble (MEDIA_ATTACHMENTS FR-3, M20-2).
    public let audio: Audio?
    /// A video attachment, shown as an inline poster that opens the full-screen player (MEDIA_ATTACHMENTS FR-2, M20-3).
    public let video: Video?
    /// A shared location (`m.location`), shown as a static map snapshot card that opens in Apple Maps.
    public let location: Location?
    /// An interactive poll (`m.poll.start`, MESSAGING FR-10, M20-4).
    public let poll: PollDetails?
    /// Forwardable content for this message (`nil` for polls, redacted, UTD, state, or unconfirmed items; MESSAGING FR-8, M20-6).
    public let forwardPayload: ForwardPayload?

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

    public struct Audio: Equatable, Sendable {
        public let ref: MediaRef
        public let name: String
        public let mimeType: String?
        public let size: Int?
        public let duration: TimeInterval?
        public let isVoice: Bool
        /// Normalised `[0, 1]` waveform samples from MSC1767 metadata, when provided by the sender.
        public let waveform: [Float]?

        public init(
            ref: MediaRef, name: String, mimeType: String? = nil, size: Int? = nil,
            duration: TimeInterval? = nil, isVoice: Bool = false, waveform: [Float]? = nil
        ) {
            self.ref = ref
            self.name = name
            self.mimeType = mimeType
            self.size = size
            self.duration = duration
            self.isVoice = isVoice
            self.waveform = waveform
        }
    }

    public struct Video: Equatable, Sendable {
        public let ref: MediaRef
        public let filename: String
        public let caption: String?
        public let mimeType: String?
        public let size: Int?
        public let duration: TimeInterval?
        public let aspectRatio: Double
        public let thumbnail: Image?
        public let blurhash: String?
        public let isOwn: Bool

        public init(
            ref: MediaRef, filename: String, caption: String? = nil, mimeType: String? = nil,
            size: Int? = nil, duration: TimeInterval? = nil, aspectRatio: Double = VideoDisplayMetrics.defaultAspectRatio,
            thumbnail: Image? = nil, blurhash: String? = nil, isOwn: Bool = false
        ) {
            self.ref = ref
            self.filename = filename
            self.caption = caption
            self.mimeType = mimeType
            self.size = size
            self.duration = duration
            self.aspectRatio = aspectRatio
            self.thumbnail = thumbnail
            self.blurhash = blurhash
            self.isOwn = isOwn
        }
    }

    public struct Location: Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let title: String
        public let subtitle: String
        public let mapsURL: URL?

        public init(latitude: Double, longitude: Double, title: String, subtitle: String, mapsURL: URL?) {
            self.latitude = latitude
            self.longitude = longitude
            self.title = title
            self.subtitle = subtitle
            self.mapsURL = mapsURL
        }
    }

    /// Whether the row shows its `text` in a bubble. A sticker never does, nor does a file tile, audio bubble, video poster, poll card or location card, and neither does an image whose
    /// body is just its file name ("photo.jpg", which clients put in `body` when there is no caption); a real caption is shown.
    public var showsText: Bool { !isSticker && file == nil && audio == nil && video == nil && location == nil && poll == nil && !(image != nil && Self.looksLikeFilename(text)) }

    /// Whether a plain text message consists solely of 1–3 native Unicode emoji and renders jumbo-sized without a bubble fill.
    public var isJumboEmoji: Bool {
        showsText && image == nil && file == nil && audio == nil && video == nil && location == nil && poll == nil && card == nil && NativeEmoji.isEmojiOnly(text, maxCount: 3)
    }

    /// The KLIPY GIF or sticker this message is, when its whole text is one KLIPY media link (COMPOSER_PANELS §6, D98).
    public var klipyURL: URL? {
        guard style == .message || style == .ownMessage, showsText, image == nil, card == nil else { return nil }
        return KlipyLink.mediaURL(in: text)
    }

    /// Whether the user can edit this row's text (own confirmed text message; never photos, files, audio, video, polls, locations or stickers).
    public var canEdit: Bool { isOwn && style == .ownMessage && eventID != nil && image == nil && file == nil && audio == nil && video == nil && location == nil && poll == nil && !isSticker }

    /// Whether this confirmed message can be forwarded to another chat (MESSAGING FR-8, M20-6).
    public var canForward: Bool { eventID != nil && forwardPayload != nil }

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
        /// Precomputed inline thumbnail reference (`info.thumbnail_file` / `info.thumbnail_url`), when the sender included one.
        public let thumbnailRef: MediaRef?
        /// Whether this photo was sent by the signed-in user (cached locally under `MediaFormat::File` by the SDK, M19-5).
        public let isOwn: Bool
        /// Width / height, when the sender gave dimensions; the view falls back to 4:3.
        public let aspectRatio: Double?
        /// Optional BlurHash placeholder string (`xyz.amorgan.blurhash`), when provided by the sender.
        public let blurhash: String?

        public init(
            ref: MediaRef, aspectRatio: Double?, blurhash: String? = nil,
            thumbnailRef: MediaRef? = nil, isOwn: Bool = false
        ) {
            self.ref = ref
            self.thumbnailRef = thumbnailRef
            self.isOwn = isOwn
            self.aspectRatio = aspectRatio
            self.blurhash = blurhash
        }
    }

    init(
        id: String, style: Style, sender: String?, text: String, image: Image? = nil, status: String? = nil,
        eventID: EventID? = nil, isOwn: Bool = false, reactions: [Chip] = [], reply: Reply? = nil, styled: AttributedString? = nil,
        failedLocalID: String? = nil, isSticker: Bool = false, file: FileTile? = nil, audio: Audio? = nil, video: Video? = nil, location: Location? = nil, poll: PollDetails? = nil, forwardPayload: ForwardPayload? = nil, source: Source? = nil, card: BotCard? = nil
    ) {
        self.card = card
        self.source = source
        self.forwardPayload = forwardPayload
        self.poll = poll
        self.location = location
        self.video = video
        self.audio = audio
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
