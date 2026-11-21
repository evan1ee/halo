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
    /// A message of the user's that the server hasn't confirmed yet (a local echo, sending or failed). The SDK takes an own
    /// event as a read receipt only once it is on the server, so its counts don't reflect a local echo yet.
    public let isLocal: Bool
    /// The event ID when known (e.g. from an open timeline or model); `nil` when sourced from `Room.latestEvent()` (F-FFI-15).
    public let eventID: EventID?

    public init(timestamp: Date, senderIsSelf: Bool, isLocal: Bool = false, eventID: EventID? = nil) {
        self.timestamp = timestamp
        self.senderIsSelf = senderIsSelf
        self.isLocal = isLocal
        self.eventID = eventID
    }
}

/// This device's latest read intent for a room, carrying event identity and confirmation state (R-06, ADR-0020).
public struct LocalReadPosition: Sendable, Equatable {
    public let eventID: EventID
    public let timestamp: Date
    public let isSent: Bool

    public init(eventID: EventID, timestamp: Date, isSent: Bool = false) {
        self.eventID = eventID
        self.timestamp = timestamp
        self.isSent = isSent
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
    /// The event time up to which the user has read the room: the newest of this device's read position and the receipt the
    /// SDK holds (`receiptReadThrough`).
    public let localIntent: Date?
    /// The time of the event the user's newest receipt (any device) points at, as the SDK holds it. The SDK's own counts are
    /// relative to this receipt, so when it is at least `localIntent`, a positive SDK count is unread after the read position
    /// (R-07). `nil` when unknown.
    public let receiptReadThrough: Date?
    /// The event ID of this device's local read intent (or own receipt when no local intent exists), when known (R-06).
    public let localIntentEventID: EventID?
    /// True once the local intent's receipt has been sent and confirmed by the server (echoed in `ownReceiptEventID` or
    /// followed by a sync response): positive server/SDK counts then override E1 so a stale intent cannot hide unread (R-06, ADR-0020).
    public let localIntentConfirmed: Bool
    /// The event ID of the user's own newest receipt from the SDK, when resolved (R-06).
    public let ownReceiptEventID: EventID?
    public let unconfirmedNotified: [NotifiedRef]

    public init(
        roomID: RoomID, membership: Membership, isEncrypted: Bool, counts: RoomReadCounts, latestEvent: LatestEventRef? = nil,
        localIntent: Date? = nil, receiptReadThrough: Date? = nil, localIntentEventID: EventID? = nil,
        localIntentConfirmed: Bool = false, ownReceiptEventID: EventID? = nil, unconfirmedNotified: [NotifiedRef] = []
    ) {
        self.roomID = roomID
        self.membership = membership
        self.isEncrypted = isEncrypted
        self.counts = counts
        self.latestEvent = latestEvent
        self.localIntent = localIntent
        self.receiptReadThrough = receiptReadThrough
        self.localIntentEventID = localIntentEventID
        self.localIntentConfirmed = localIntentConfirmed
        self.ownReceiptEventID = ownReceiptEventID
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
    /// Encrypted room: the server counts events the SDK doesn't (E3c, R-01).
    case encServerOnly = "ENC_SERVER_ONLY"
    case notifiedUnsynced = "NOTIFIED_UNSYNCED"
    case markedUnread = "MARKED_UNREAD"
    /// The read position covers the latest event, but the SDK, which has applied that position, still counts unread: an event
    /// after it that the latest event leaves out (one the SDK can't decrypt). E1/E1b give way (R-07).
    case sdkUnreadAfterRead = "SDK_UNREAD_AFTER_READ"
    /// A sent local intent was confirmed by the server, yet the server (when countable) or SDK still counts unread:
    /// a newer event arrived with an equal or skewed timestamp, so E1 gives way (R-06, ADR-0020).
    case intentStale = "INTENT_STALE"
}

public struct RoomReadState: Sendable, Equatable {
    public let roomID: RoomID
    /// Should the room count towards the app badge?
    public let attention: Bool
    /// Quiet unread (bold title, no badge).
    public let hasUnread: Bool
    public let display: DisplayCount
    public let confidence: Confidence
    /// No notifying event up to this timestamp is unread (UNREAD_STATE §5): drives record pruning and clearing.
    public let notifiedThroughTs: Date?
    public let reasons: Set<ReasonCode>

    public init(
        roomID: RoomID, attention: Bool, hasUnread: Bool, display: DisplayCount, confidence: Confidence,
        notifiedThroughTs: Date? = nil, reasons: Set<ReasonCode>
    ) {
        self.roomID = roomID
        self.attention = attention
        self.hasUnread = hasUnread
        self.display = display
        self.confidence = confidence
        self.notifiedThroughTs = notifiedThroughTs
        self.reasons = reasons
    }
}

/// The pure, total, deterministic read-state policy (UNREAD_STATE §5).
public enum ReadStatePolicy {
    /// The timestamp up to which no notifying event is unread (UNREAD_STATE §5): the maximum of `localIntent` (read
    /// position) and, when `serverZero` holds, `latestEvent.timestamp`.
    public static func notifiedThrough(for input: RoomReadInputs) -> Date? {
        let serverCanCount = !input.isEncrypted || input.counts.mode == .allMessages
        let serverZero = input.counts.server == .zero && serverCanCount
        return [input.localIntent, serverZero ? input.latestEvent?.timestamp : nil].compactMap { $0 }.max()
    }

    /// Splits `records` for `input.roomID` into those still unconfirmed (feed rule E4) and those covered by the read
    /// position / `notifiedThroughTs` or superseded by sync (R-02, UNREAD_STATE §2/§5).
    ///
    /// A record is superseded when sync has already delivered an event at or after it (`record.timestamp <= latest.timestamp`),
    /// except for an encrypted mention when the SDK counts zero mentions (a mention sitting inside a timeline gap, S22).
    public static func partitionRecords(for input: RoomReadInputs, records: [NotificationRecord]) -> (unconfirmed: [NotifiedRef], superseded: Set<EventID>) {
        let coveredThrough = notifiedThrough(for: input)
        let latestTs = input.latestEvent?.timestamp
        var unconfirmed: [NotifiedRef] = []
        var superseded: Set<EventID> = []
        for record in records where record.roomID == input.roomID {
            if let coveredThrough, record.timestamp <= coveredThrough {
                superseded.insert(record.eventID)
                continue
            }
            if let latestTs, record.timestamp <= latestTs {
                let encryptedGapMention = input.isEncrypted && record.isMention && input.counts.sdk.unreadMentions == 0
                if !encryptedGapMention {
                    superseded.insert(record.eventID)
                    continue
                }
            }
            unconfirmed.append(NotifiedRef(timestamp: record.timestamp, isMention: record.isMention))
        }
        return (unconfirmed, superseded)
    }

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
        let notifiedThrough = Self.notifiedThrough(for: input)
        var reasons: Set<ReasonCode> = []
        var notify = 0
        var highlight = 0
        var confidence = Confidence.exact
        var hasUnread: Bool

        let intentCovers: Bool = {
            guard let latest = input.latestEvent else { return false }
            // R-06 (ADR-0020): when both event IDs are known, identity decides — equal or skewed timestamps never override it.
            if let intentID = input.localIntentEventID, let latestID = latest.eventID {
                return intentID == latestID
            }
            guard let intent = input.localIntent else { return false }
            return latest.timestamp <= intent
        }()
        let ownLatest = input.latestEvent?.senderIsSelf == true && input.unconfirmedNotified.isEmpty
        // R-07: the SDK's latest event leaves out events it can't decrypt, so "covers the latest event" can be true while
        // newer unread exists. The SDK's counts know better once the SDK has applied the read position: the receipt it holds
        // is at least the local one (E1), or the own latest event is on the server (E1b: the SDK takes an own event as a receipt).
        let sdkCountsAfterRead = counts.sdk != .zero && {
            if intentCovers, let receipt = input.receiptReadThrough, let intent = input.localIntent, intent <= receipt { return true }
            if ownLatest, input.latestEvent?.isLocal == false { return true }
            return false
        }()
        // R-06 (ADR-0020): once the receipt is confirmed on the server (echoed or followed by a sync), a stale intent
        // must not suppress positive server counts (when countable) or positive SDK counts (revisiting D47/D72).
        let intentContradicted = intentCovers && input.localIntentConfirmed && (counts.sdk != .zero || (serverCanCount && counts.server != .zero))

        if sdkCountsAfterRead {
            reasons.insert(.sdkUnreadAfterRead)
        }
        if intentContradicted && !sdkCountsAfterRead {
            reasons.insert(.intentStale)
        }
        if (intentCovers || ownLatest) && !sdkCountsAfterRead && !intentContradicted {  // E1, E1b
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
            // E3b: the SDK's counts, whenever it counts anything. It evaluates the push rules again on the decrypted event, so a
            // call invite counts as a notification without being a message, and a poll vote counts as nothing (R-01).
            if counts.sdk != .zero {
                notify = counts.sdk.unreadNotifications
                highlight = counts.sdk.unreadMentions
                reasons.insert(.sdkCounts)
                if serverCanCount && counts.server.notification > counts.sdk.unreadNotifications {
                    confidence = .approximate
                    reasons.insert(.encServerOvercount)
                }
                if reasons.contains(.serverBlind) && counts.sdk.unreadMentions > 0 { confidence = .approximate }
            } else if counts.server.notification > 0 || counts.server.highlight > 0 {
                // E3c (R-01): the server counts every encrypted event, because its push rules can't look into one (a poll
                // vote, an encrypted reaction); the SDK, which holds the same events over classic sync (D74) and counts one it
                // can't decrypt, counts nothing. Its zero is the truth: no unread. A message the SDK hasn't got can still
                // show through a push record (E4).
                reasons.insert(.encServerOnly)
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
        return RoomReadState(
            roomID: id, attention: attention, hasUnread: hasUnread, display: display, confidence: confidence,
            notifiedThroughTs: notifiedThrough, reasons: reasons)
    }
}

/// The app badge: the number of rooms that need attention (D5). Never incremented, always recomputed (D9).
public enum BadgeCalculator {
    public static func badge(_ states: [RoomReadState]) -> Int { states.filter(\.attention).count }
}
