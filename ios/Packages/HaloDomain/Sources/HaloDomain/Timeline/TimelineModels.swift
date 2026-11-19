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

    public init(eventID: EventID?, sender: UserID?, senderName: String?, timestamp: Date, isOwn: Bool, kind: TimelineEventKind) {
        self.eventID = eventID
        self.sender = sender
        self.senderName = senderName
        self.timestamp = timestamp
        self.isOwn = isOwn
        self.kind = kind
    }
}

/// What an event is, as far as M1 renders it (TIMELINE FR-2). Anything else is `.unsupported`.
public enum TimelineEventKind: Sendable, Equatable {
    case text(String, isEdited: Bool)
    case notice(String, isEdited: Bool)
    case emote(String, isEdited: Bool)
    /// Image, video, audio or file; `body` is the filename or caption. Media display arrives in M2.
    case media(MediaKind, body: String)
    case sticker(body: String)
    case redacted
    /// Can't be decrypted (yet). The reason is shown honestly, never hidden (R-P0-3).
    case undecryptable
    case membership(user: UserID?, displayName: String?, change: MembershipChange)
    case otherState
    case unsupported
}

public enum MediaKind: Sendable, Equatable { case image, video, audio, file }

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
