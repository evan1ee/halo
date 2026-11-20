import Foundation
import HaloFoundation

/// A stable identity for a timeline row, from the upstream unique id. Survives local echo → remote
/// (docs/features/TIMELINE.md FR-1).
public struct TimelineItemID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "TimelineItemID(<redacted>)" }
}

/// A row of a room timeline (docs/features/TIMELINE.md §7). M1 subset: read-only content; reactions,
/// receipts, replies and send state arrive in M2/M3.
public struct TimelineItem: Sendable, Equatable, Identifiable {
    public let id: TimelineItemID
    public let content: TimelineContent

    public init(id: TimelineItemID, content: TimelineContent) {
        self.id = id
        self.content = content
    }
}

public enum TimelineContent: Sendable, Equatable {
    case event(TimelineEvent)
    case virtual(VirtualItem)
}

public struct TimelineEvent: Sendable, Equatable {
    public let eventID: EventID?
    public let sender: UserID?
    /// The sender's display name if the SDK has resolved it.
    public let senderName: String?
    public let timestamp: Date
    public let isOwn: Bool
    public let kind: TimelineEventKind
    /// Local echo state of an event this device is sending; remote events are always `.sent`.
    public let sendState: SendState
    public let reactions: [ReactionSummary]
    /// The message this one replies to, if any (docs/features/MESSAGING.md FR-2).
    public let replyTo: ReplyPreview?
    /// The sender's HTML `formatted_body` for a text message, untouched (the UI renders a safe subset). `nil` for
    /// plain messages.
    public let formattedBody: String?
    /// The local transaction ID while this is an own event the server hasn't confirmed; what `retrySend` and `abortSend` take.
    public let localID: String?

    public init(
        eventID: EventID?, sender: UserID?, senderName: String?, timestamp: Date, isOwn: Bool, kind: TimelineEventKind,
        sendState: SendState = .sent, reactions: [ReactionSummary] = [], replyTo: ReplyPreview? = nil, formattedBody: String? = nil,
        localID: String? = nil
    ) {
        self.localID = localID
        self.formattedBody = formattedBody
        self.replyTo = replyTo
        self.reactions = reactions
        self.sendState = sendState
        self.eventID = eventID
        self.sender = sender
        self.senderName = senderName
        self.timestamp = timestamp
        self.isOwn = isOwn
        self.kind = kind
    }
}

/// The quoted message of a reply. `snippet` is `nil` while the original isn't loaded (or can't be shown), so the UI
/// says so instead of inventing text.
public struct ReplyPreview: Sendable, Equatable {
    public let eventID: EventID
    public let senderName: String?
    public let snippet: String?

    public init(eventID: EventID, senderName: String?, snippet: String?) {
        self.eventID = eventID
        self.senderName = senderName
        self.snippet = snippet
    }
}

/// What an event is, as far as M1 renders it (TIMELINE FR-2). Anything else is `.unsupported`.
/// One reaction key on an event (docs/features/TIMELINE.md FR-7): the emoji, how many people used it, and whether
/// the signed-in user is one of them.
public struct ReactionSummary: Sendable, Equatable {
    public let key: String
    public let count: Int
    public let reactedByMe: Bool

    public init(key: String, count: Int, reactedByMe: Bool) {
        self.key = key
        self.count = count
        self.reactedByMe = reactedByMe
    }
}

/// Where an own message is on its way to the server (docs/features/MESSAGING.md §6). Unconfirmed things look
/// unconfirmed (AGENTS.md §4.4).
public enum SendState: Sendable, Equatable {
    case sent
    /// Queued or in flight; it survives an app kill (the SDK send queue).
    case sending
    /// Sending failed. `recoverable` failures (offline, rate limit) retry by themselves; others wait for the user.
    case failed(recoverable: Bool)
}

public enum TimelineEventKind: Sendable, Equatable {
    case text(String, isEdited: Bool)
    case notice(String, isEdited: Bool)
    case emote(String, isEdited: Bool)
    /// Image, video, audio or file. Only images are displayed in M1; the others show their name.
    case media(MediaAttachment)
    case sticker(body: String, source: MediaRef?)
    case redacted
    /// Can't be decrypted (yet). The reason is shown honestly, never hidden (R-P0-3).
    case undecryptable(UTDReason)
    case membership(user: UserID?, displayName: String?, change: MembershipChange)
    case otherState
    case unsupported
}

/// Why an event can't be read (docs/features/ENCRYPTION_AND_DEVICES.md FR-5). The SDK retries by itself when keys
/// arrive, and the row then turns into the decrypted message (AC-E2EE-3).
public enum UTDReason: Sendable, Equatable {
    case unknown
    /// Sent before this user joined the room: the keys were never shared with them.
    case sentBeforeJoining
    /// The sender's device didn't share keys with this device, or it is unknown/unsigned.
    case keysNotShared
    /// The sender's identity changed or is unverified in a way that blocks decryption.
    case senderVerificationProblem
    /// An old message whose keys would be in a key backup, which is not enabled.
    case backupDisabled
}

public enum MediaKind: Sendable, Equatable { case image, video, audio, file }

/// An opaque reference to media on the homeserver. Only the adapter that created it can interpret it, so
/// the domain never sees URLs, keys or upstream types (PORTS_CONTRACT §1).
public struct MediaRef: Sendable, Hashable, CustomStringConvertible {
    public let token: String
    public init(token: String) { self.token = token }
    public var description: String { "MediaRef(<redacted>)" }
}

public struct MediaAttachment: Sendable, Equatable {
    public let kind: MediaKind
    /// The filename or caption.
    public let body: String
    public let source: MediaRef?
    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    /// Bytes, when the sender said.
    public let size: Int?
    /// Seconds, for audio and video.
    public let duration: TimeInterval?
    /// A still picture the sender attached to a video (`info.thumbnail_url`), when there is one.
    public let thumbnail: MediaRef?

    public init(
        kind: MediaKind, body: String, source: MediaRef?, width: Int? = nil, height: Int? = nil,
        mimeType: String? = nil, size: Int? = nil, duration: TimeInterval? = nil, thumbnail: MediaRef? = nil
    ) {
        self.thumbnail = thumbnail
        self.kind = kind
        self.body = body
        self.source = source
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.size = size
        self.duration = duration
    }
}

public enum MembershipChange: Sendable, Equatable {
    case joined, left, invited, kicked, banned, unbanned, invitationRejected, invitationRevoked, knocked, other
}

public enum VirtualItem: Sendable, Equatable {
    /// A day separator before the following events.
    case dateDivider(Date)
    case readMarker
    case timelineStart
}

public typealias TimelineDiff = ListDiff<TimelineItem>
