import Foundation
import HaloFoundation

// The read-state auditor's classifier (docs/architecture/LOGGING_AND_DIAGNOSTICS.md §2, UNREAD_STATE). Pure: it compares
// what the policy decided with the raw inputs (server counts, SDK counts, local intent) and says whether each
// disagreement has a known reason. AC-U8 counts the *unexplained* ones.

public enum AuditKind: String, Sendable, Equatable, Hashable {
    case explained, unexplained
}

/// One disagreement between the policy's output and an input, with the stable reason code stored for it.
public struct AuditFinding: Sendable, Equatable, Hashable {
    public let kind: AuditKind
    /// `SDK_STALE_PENDING_RECEIPT`, `SERVER_BLIND`, `ENC_SERVER_OVERCOUNT`, `ENC_SERVER_ONLY`, `INTENT_UNCONFIRMED` (explained), or an
    /// `UNEXPLAINED_*` code.
    public let reason: String

    public init(kind: AuditKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

public enum ReadStateAuditor {
    /// The disagreements for one room. An agreeing room has none. Rooms the user isn't in are not audited.
    public static func audit(_ input: RoomReadInputs, state: RoomReadState) -> [AuditFinding] {
        guard input.membership == .joined else { return [] }
        let counts = input.counts
        var findings: [AuditFinding] = []
        let serverCanCount = !input.isEncrypted || counts.mode == .allMessages
        let covered = state.reasons.contains(.intentCovers) || state.reasons.contains(.ownLatest)

        // The server counted unread messages (a highlight implies a notification), the policy says there are none.
        if serverCanCount, counts.server.notification > 0, !state.hasUnread, !state.attention {
            if covered {
                findings.append(AuditFinding(kind: .explained, reason: "INTENT_UNCONFIRMED"))
            } else if state.reasons.contains(.encServerOnly) {
                // An encrypted event that isn't a message (a poll vote, a call signal): the SDK's zero wins (E3c, R-01).
                findings.append(AuditFinding(kind: .explained, reason: "ENC_SERVER_ONLY"))
            } else {
                findings.append(AuditFinding(kind: .unexplained, reason: "UNEXPLAINED_SERVER_UNREAD_HIDDEN"))
            }
        }
        // The SDK still counts unread messages, the server says zero: the SDK hasn't applied the newest receipt yet.
        if serverCanCount, counts.server == .zero, counts.sdk.unreadMessages > 0 {
            findings.append(AuditFinding(kind: .explained, reason: "SDK_STALE_PENDING_RECEIPT"))
        }
        // The server can't count here, so the policy relies on the SDK alone.
        if state.reasons.contains(.serverBlind) {
            findings.append(AuditFinding(kind: .explained, reason: "SERVER_BLIND"))
        }
        if state.reasons.contains(.encServerOvercount) {
            findings.append(AuditFinding(kind: .explained, reason: "ENC_SERVER_OVERCOUNT"))
        }
        // The policy asks for attention but nothing it knows of supports that.
        let supported = counts.isMarkedUnread || !input.unconfirmedNotified.isEmpty || counts.server != .zero
            || counts.sdk.unreadMessages > 0 || counts.sdk.unreadNotifications > 0 || counts.sdk.unreadMentions > 0
        if state.attention, !supported {
            findings.append(AuditFinding(kind: .unexplained, reason: "UNEXPLAINED_ATTENTION_WITHOUT_INPUT"))
        }
        // Attention in a muted room without the user's own unread flag.
        if counts.mode == .mute, state.attention, !counts.isMarkedUnread {
            findings.append(AuditFinding(kind: .unexplained, reason: "UNEXPLAINED_MUTED_ATTENTION"))
        }
        return findings
    }
}

/// One stored audit row: counts and codes only, the room as a short hash (LOGGING_AND_DIAGNOSTICS §2).
public struct AuditEvent: Sendable, Equatable {
    public let at: Date
    public let roomHash: String
    public let finding: AuditFinding
    /// Counts only, e.g. `{"server":[2,0],"sdk":[1,1,0],"enc":true,"mode":"all"}`.
    public let inputsJSON: String
    public let appVersion: String

    public init(at: Date, roomHash: String, finding: AuditFinding, inputsJSON: String, appVersion: String) {
        self.at = at
        self.roomHash = roomHash
        self.finding = finding
        self.inputsJSON = inputsJSON
        self.appVersion = appVersion
    }

    /// The counts of `input` as the JSON stored with an event (no identifiers, no content).
    public static func inputsJSON(for input: RoomReadInputs) -> String {
        let c = input.counts
        let mode = switch c.mode { case .allMessages: "all"; case .mentionsAndKeywords: "mentions"; case .mute: "mute" }
        return "{\"server\":[\(c.server.notification),\(c.server.highlight)],\"sdk\":[\(c.sdk.unreadMessages),\(c.sdk.unreadNotifications),\(c.sdk.unreadMentions)],"
            + "\"enc\":\(input.isEncrypted),\"mode\":\"\(mode)\",\"marked\":\(c.isMarkedUnread),\"intent\":\(input.localIntent != nil),\"notified\":\(input.unconfirmedNotified.count)}"
    }
}

/// Durable audit rows, capped (oldest pruned first).
public protocol AuditEventPort: Sendable {
    func append(_ events: [AuditEvent]) async throws(HaloError)
    func all() async throws(HaloError) -> [AuditEvent]
    /// How many unexplained events are stored (AC-U8).
    func unexplainedCount() async throws(HaloError) -> Int
}
