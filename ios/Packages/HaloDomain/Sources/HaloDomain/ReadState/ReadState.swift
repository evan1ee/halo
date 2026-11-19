import Foundation
import HaloFoundation

// The read-state policy and badge (docs/matrix/UNREAD_STATE.md, D5, D9, D47, ADR-0007). Pure values and a pure
// function: no I/O, no stored counters. Every indicator derives from `ReadStatePolicy.evaluate`.

/// How a room notifies the user.
public enum NotificationMode: Sendable, Equatable {
    case allMessages, mentionsAndKeywords, mute
}

/// Counts the homeserver computed from push rules after the user's latest receipt on any device.
public struct ServerCounts: Sendable, Equatable {
    public let notification: Int
    public let highlight: Int

    public init(notification: Int, highlight: Int) {
        self.notification = notification
        self.highlight = highlight
    }

    public static let zero = ServerCounts(notification: 0, highlight: 0)
}

/// Counts the SDK computed on the device from the events it has seen after the latest receipt.
public struct SDKCounts: Sendable, Equatable {
    public let unreadMessages: Int
    public let unreadNotifications: Int
    public let unreadMentions: Int

    public init(unreadMessages: Int, unreadNotifications: Int, unreadMentions: Int) {
        self.unreadMessages = unreadMessages
        self.unreadNotifications = unreadNotifications
        self.unreadMentions = unreadMentions
    }

    public static let zero = SDKCounts(unreadMessages: 0, unreadNotifications: 0, unreadMentions: 0)
}

/// The raw read data of one room, as the adapter reads it from the SDK.
public struct RoomReadCounts: Sendable, Equatable {
    public let mode: NotificationMode
    public let server: ServerCounts
    public let sdk: SDKCounts
    public let isMarkedUnread: Bool

    public init(mode: NotificationMode, server: ServerCounts, sdk: SDKCounts, isMarkedUnread: Bool) {
        self.mode = mode
        self.server = server
        self.sdk = sdk
        self.isMarkedUnread = isMarkedUnread
    }

    /// Nothing unread; the default for rooms whose counts aren't known yet.
    public static let none = RoomReadCounts(mode: .allMessages, server: .zero, sdk: .zero, isMarkedUnread: false)
}

public struct LatestEventRef: Sendable, Equatable {
    public let timestamp: Date
    public let senderIsSelf: Bool

    public init(timestamp: Date, senderIsSelf: Bool) {
        self.timestamp = timestamp
        self.senderIsSelf = senderIsSelf
    }
}

/// An event the notification extension fetched that sync hasn't delivered yet (rule E4).
public struct NotifiedRef: Sendable, Equatable {
    public let timestamp: Date
    public let isMention: Bool

    public init(timestamp: Date, isMention: Bool) {
        self.timestamp = timestamp
        self.isMention = isMention
    }
}

public struct RoomReadInputs: Sendable, Equatable {
    public let roomID: RoomID
    public let membership: Membership
    public let isEncrypted: Bool
    public let counts: RoomReadCounts
    public let latestEvent: LatestEventRef?
    /// The event time up to which the user read the room on this device and the server hasn't confirmed yet.
    public let localIntent: Date?
    public let unconfirmedNotified: [NotifiedRef]

    public init(
        roomID: RoomID, membership: Membership, isEncrypted: Bool, counts: RoomReadCounts, latestEvent: LatestEventRef? = nil,
        localIntent: Date? = nil, unconfirmedNotified: [NotifiedRef] = []
    ) {
        self.roomID = roomID
        self.membership = membership
        self.isEncrypted = isEncrypted
        self.counts = counts
        self.latestEvent = latestEvent
        self.localIntent = localIntent
        self.unconfirmedNotified = unconfirmedNotified
    }
}

public enum DisplayCount: Sendable, Equatable {
    case none, dot
    case count(Int)
    case mentions(Int)
}

public enum Confidence: Sendable, Equatable {
    case exact, approximate
}

/// Why the policy decided as it did; for the auditor and tests (UNREAD_STATE §5).
public enum ReasonCode: String, Sendable, Equatable, CaseIterable {
    case invite = "INVITE"
    case intentCovers = "INTENT_COVERS"
    case ownLatest = "OWN_LATEST"
    case serverZero = "SERVER_ZERO"
    case sdkStale = "SDK_STALE"
    case serverBlind = "SERVER_BLIND"
    case serverCounts = "SERVER_COUNTS"
    case sdkCounts = "SDK_COUNTS"
    case encServerOvercount = "ENC_SERVER_OVERCOUNT"
    case encSDKBlind = "ENC_SDK_BLIND"
    case notifiedUnsynced = "NOTIFIED_UNSYNCED"
    case markedUnread = "MARKED_UNREAD"
}

public struct RoomReadState: Sendable, Equatable {
    public let roomID: RoomID
    /// Should the room count towards the app badge?
    public let attention: Bool
    /// Quiet unread (bold title, no badge).
    public let hasUnread: Bool
    public let display: DisplayCount
    public let confidence: Confidence
    public let reasons: Set<ReasonCode>

    public init(roomID: RoomID, attention: Bool, hasUnread: Bool, display: DisplayCount, confidence: Confidence, reasons: Set<ReasonCode>) {
        self.roomID = roomID
        self.attention = attention
        self.hasUnread = hasUnread
        self.display = display
        self.confidence = confidence
        self.reasons = reasons
    }
}

/// The pure, total, deterministic read-state policy (UNREAD_STATE §5). Not yet: the clearing/`notifiedThroughTs` outputs
/// (they need the notification records of M3).
public enum ReadStatePolicy {
    public static func evaluate(_ input: RoomReadInputs) -> RoomReadState {
        let id = input.roomID
        // E0: an invite always needs attention; a room the user isn't in never does.
        if input.membership == .invited {
            return RoomReadState(roomID: id, attention: true, hasUnread: true, display: .dot, confidence: .exact, reasons: [.invite])
        }
        guard input.membership == .joined else {
            return RoomReadState(roomID: id, attention: false, hasUnread: false, display: .none, confidence: .exact, reasons: [])
        }

        let counts = input.counts
        let serverCanCount = !input.isEncrypted || counts.mode == .allMessages
        let serverZero = counts.server == .zero && serverCanCount
        var reasons: Set<ReasonCode> = []
        var notify = 0
        var highlight = 0
        var confidence = Confidence.exact
        var hasUnread: Bool

        let intentCovers: Bool = {
            guard let intent = input.localIntent, let latest = input.latestEvent else { return false }
            return latest.timestamp <= intent
        }()
        let ownLatest = input.latestEvent?.senderIsSelf == true && input.unconfirmedNotified.isEmpty

        if intentCovers || ownLatest {  // E1, E1b
            reasons.insert(intentCovers ? .intentCovers : .ownLatest)
            hasUnread = false
        } else if serverZero {  // E2
            reasons.insert(.serverZero)
            if counts.sdk.unreadMessages > 0 { reasons.insert(.sdkStale) }
            hasUnread = counts.mode == .allMessages ? false : counts.sdk.unreadMessages > 0
        } else if !input.isEncrypted {  // E3a
            notify = counts.server.notification
            highlight = counts.server.highlight
            reasons.insert(.serverCounts)
            hasUnread = counts.sdk.unreadMessages > 0 || notify > 0
        } else {
            if counts.server == .zero && !serverCanCount { reasons.insert(.serverBlind) }  // E2x
            if counts.sdk.unreadMessages > 0 {  // E3b
                notify = counts.sdk.unreadNotifications
                highlight = counts.sdk.unreadMentions
                reasons.insert(.sdkCounts)
                if serverCanCount && counts.server.notification > counts.sdk.unreadNotifications {
                    confidence = .approximate
                    reasons.insert(.encServerOvercount)
                }
                if reasons.contains(.serverBlind) && counts.sdk.unreadMentions > 0 { confidence = .approximate }
            } else if counts.server.notification > 0 || counts.server.highlight > 0 {  // E3c (a highlight implies a notification; accepted either way)
                notify = 1
                confidence = .approximate
                reasons.insert(.encSDKBlind)
            }
            hasUnread = counts.sdk.unreadMessages > 0 || notify > 0
        }

        // E4: events the extension fetched that sync hasn't delivered yet.
        if !input.unconfirmedNotified.isEmpty {
            notify += input.unconfirmedNotified.count
            highlight += input.unconfirmedNotified.filter(\.isMention).count
            reasons.insert(.notifiedUnsynced)
            hasUnread = true
        }

        // E5: marked unread forces attention in every mode.
        if counts.isMarkedUnread {
            reasons.insert(.markedUnread)
            hasUnread = true
        }

        let attention: Bool
        switch counts.mode {
        case .allMessages: attention = notify > 0 || highlight > 0 || counts.isMarkedUnread
        case .mentionsAndKeywords: attention = highlight > 0 || counts.isMarkedUnread
        case .mute: attention = counts.isMarkedUnread
        }

        let display: DisplayCount
        if !attention {
            display = .none
        } else if highlight > 0 {
            display = .mentions(highlight)
        } else if confidence == .exact && notify > 0 {
            display = .count(notify)
        } else {
            display = .dot
        }
        return RoomReadState(roomID: id, attention: attention, hasUnread: hasUnread, display: display, confidence: confidence, reasons: reasons)
    }
}

/// The app badge: the number of rooms that need attention (D5). Never incremented, always recomputed (D9).
public enum BadgeCalculator {
    public static func badge(_ states: [RoomReadState]) -> Int { states.filter(\.attention).count }
}
