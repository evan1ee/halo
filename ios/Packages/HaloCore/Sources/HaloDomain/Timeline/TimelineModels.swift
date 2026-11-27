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
    /// The sender's profile picture, if they have one and the SDK has resolved it.
    public let senderAvatar: MediaRef?
    /// Other people whose newest read receipt is on this event (never the signed-in user); TIMELINE FR-6.
    public let readBy: [UserID]
    /// Why a failed own message wasn't sent, when the SDK says; `nil` otherwise.
    public let sendFailure: SendFailure?

    public init(
        eventID: EventID?, sender: UserID?, senderName: String?, timestamp: Date, isOwn: Bool, kind: TimelineEventKind,
        sendState: SendState = .sent, reactions: [ReactionSummary] = [], replyTo: ReplyPreview? = nil, formattedBody: String? = nil,
        localID: String? = nil, senderAvatar: MediaRef? = nil, readBy: [UserID] = [], sendFailure: SendFailure? = nil
    ) {
        self.sendFailure = sendFailure
        self.readBy = readBy
        self.senderAvatar = senderAvatar
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

/// Why the SDK refused to send an own message, when it says (AC-SEC-2). Nothing is ever sent unencrypted instead.
public enum SendFailure: Sendable, Equatable {
    /// Someone in the room has a device this account hasn't verified, and the SDK's setting keeps messages from it.
    case unverifiedDevices(users: [UserID])
    /// A contact who was verified now has a different identity.
    case identityChanged(users: [UserID])
    /// This device must be verified (cross-signing set up) before it can send.
    case needsVerification
    /// The session's access token was rejected; sending waits for a working one.
    case sessionExpired
    /// The picture or file to send is no longer on the device.
    case mediaGone
    case other

    /// The SDK can send anyway after the person accepts the risk (unverified devices, a changed identity).
    public var canSendAnyway: Bool {
        switch self {
        case .unverifiedDevices, .identityChanged: true
        case .needsVerification, .sessionExpired, .mediaGone, .other: false
        }
    }
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
    /// A shared place (`m.location`): the sender's description and the raw `geo:` URI (TIMELINE FR-2, static, no map).
    case location(body: String, geoURI: String)
    /// A poll (TIMELINE FR-2, MESSAGING FR-10, M20-4): question, options with counts and own selection, visibility, and ended state.
    case poll(PollDetails)
    /// A call started or rang in the room; display only, Halo has no calling (D43).
    case call
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
    /// Optional BlurHash placeholder string (`xyz.amorgan.blurhash`), when provided by the sender (MEDIA_ATTACHMENTS FR-1).
    public let blurhash: String?
    /// `true` for MSC3245 voice messages (`org.matrix.msc3245.voice`), `false` for ordinary audio files (MEDIA_ATTACHMENTS FR-3).
    public let isVoice: Bool
    /// Normalised `[0, 1]` amplitude samples from MSC1767 `org.matrix.msc1767.audio.waveform`, when provided by the sender.
    public let waveform: [Float]?
    /// Optional explicit caption when distinct from filename (MSC2530, M20-3).
    public let caption: String?

    public init(
        kind: MediaKind, body: String, source: MediaRef?, width: Int? = nil, height: Int? = nil,
        mimeType: String? = nil, size: Int? = nil, duration: TimeInterval? = nil, thumbnail: MediaRef? = nil,
        blurhash: String? = nil, isVoice: Bool = false, waveform: [Float]? = nil, caption: String? = nil
    ) {
        self.blurhash = blurhash
        self.thumbnail = thumbnail
        self.kind = kind
        self.body = body
        self.source = source
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.size = size
        self.duration = duration
        self.isVoice = isVoice
        self.waveform = waveform
        self.caption = caption
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

/// Whether a poll reveals live vote counts before it ends (MSC3381 `m.poll.disclosed` / `m.poll.undisclosed`).
public enum PollVisibility: Sendable, Equatable {
    case disclosed
    case undisclosed
}

/// One answer of a poll with its MSC3381 identifier, vote count, and whether the signed-in user voted for it.
public struct PollOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let votes: Int
    public let selectedByMe: Bool

    public init(id: String = "", text: String, votes: Int = 0, selectedByMe: Bool = false) {
        self.id = id.isEmpty ? text : id
        self.text = text
        self.votes = max(0, votes)
        self.selectedByMe = selectedByMe
    }
}

/// Full state of an MSC3381 poll in a timeline (MESSAGING FR-10, AC-M5, M20-4).
public struct PollDetails: Sendable, Equatable {
    public let question: String
    public let options: [PollOption]
    public let visibility: PollVisibility
    public let maxSelections: Int
    public let totalVoters: Int
    public let ended: Bool

    public init(
        question: String,
        options: [PollOption],
        visibility: PollVisibility = .disclosed,
        maxSelections: Int = 1,
        totalVoters: Int? = nil,
        ended: Bool = false
    ) {
        self.question = question
        self.options = options
        self.visibility = visibility
        self.maxSelections = max(1, maxSelections)
        self.totalVoters = max(0, totalVoters ?? options.reduce(0) { $0 + $1.votes })
        self.ended = ended
    }

    /// Disclosed polls show live results immediately; undisclosed polls reveal counts only once ended.
    public var showsResults: Bool { visibility == .disclosed || ended }

    /// Answer IDs currently confirmed for the signed-in user, in option order.
    public var ownSelectedIDs: [String] { options.filter(\.selectedByMe).map(\.id) }

    /// Total votes across all options.
    public var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }

    /// Highest vote count among options (`0` when no votes exist).
    public var highestVotes: Int { options.map(\.votes).max() ?? 0 }

    /// Whether `option` is tied for or holds the top vote count on an ended poll.
    public func isWinner(_ option: PollOption) -> Bool {
        ended && option.votes > 0 && option.votes == highestVotes
    }

    /// Normalised `[0, 1]` share of votes for `option`.
    public func voteFraction(for option: PollOption) -> Double {
        let denominator = maxSelections > 1 ? totalVoters : totalVotes
        guard denominator > 0 else { return 0 }
        return min(1, max(0, Double(option.votes) / Double(denominator)))
    }

    /// Rounded whole percentage (`0...100`) for `option`.
    public func votePercentage(for option: PollOption) -> Int {
        Int((voteFraction(for: option) * 100).rounded())
    }

    /// Computes the next answer-ID list when the user taps `optionID` given their `current` selection.
    /// Returns `nil` when the tap is a no-op (poll ended, option unknown, single-choice already selected, or at `maxSelections`).
    public func nextSelection(tapping optionID: String, current: [String]) -> [String]? {
        guard !ended, options.contains(where: { $0.id == optionID }) else { return nil }
        if maxSelections <= 1 {
            return current == [optionID] ? nil : [optionID]
        }
        var next = current.filter { id in options.contains(where: { $0.id == id }) }
        if let existing = next.firstIndex(of: optionID) {
            next.remove(at: existing)
            return next
        }
        guard next.count < maxSelections else { return nil }
        next.append(optionID)
        return next
    }

    /// Plain-text summary sent in `m.poll.end` for clients that do not render MSC3381 polls.
    public func endFallbackText() -> String {
        let top = highestVotes
        guard top > 0 else { return "Poll ended. No votes were cast." }
        let winners = options.filter { $0.votes == top }.map(\.text)
        let list = winners.joined(separator: ", ")
        let noun = top == 1 ? "vote" : "votes"
        return "Poll ended. Top result: \(list) (\(top) \(noun))."
    }
}

/// One version of an edited message, oldest first (the original text, then each edit); TIMELINE FR-9.
public struct EditRevision: Sendable, Equatable {
    public let text: String
    public let timestamp: Date?
    public init(text: String, timestamp: Date?) {
        self.text = text
        self.timestamp = timestamp
    }
}
