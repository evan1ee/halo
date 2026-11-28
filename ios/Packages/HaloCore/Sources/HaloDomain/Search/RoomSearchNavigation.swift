import Foundation
import HaloFoundation

/// Pure navigation state machine for searching inside one room with previous (older) / next (newer) stepping (ROADMAP M20-11, MESSAGE_SEARCH FR-8).
///
/// Hits arrive newest-first (`index == 0` is the newest match). In a chat timeline, older messages sit above newer ones:
/// - **Previous (↑ / older):** moves toward higher indices (`0 → 1 → 2…`), requesting more pages when reaching the end of loaded hits.
/// - **Next (↓ / newer):** moves toward lower indices (`…2 → 1 → 0`).
public struct RoomSearchNavigator: Sendable, Equatable {
    public enum StepOutcome: Sendable, Equatable {
        case jump(MessageSearchHit)
        case loadMore
        case none
    }

    public private(set) var hits: [MessageSearchHit] = []
    public private(set) var hasMore = false
    public private(set) var selectedIndex: Int?
    public private(set) var selectedEventID: EventID?
    private var pendingAdvanceAfterLoadMore = false

    public init() {}

    public var currentHit: MessageSearchHit? {
        guard let selectedIndex, hits.indices.contains(selectedIndex) else { return nil }
        return hits[selectedIndex]
    }

    /// Human-readable counter such as `"1 of 5"` or `"3 of 25+"`; `nil` when there are no matches.
    public var positionText: String? {
        guard let selectedIndex, !hits.isEmpty else { return nil }
        let suffix = hasMore ? "+" : ""
        return "\(selectedIndex + 1) of \(hits.count)\(suffix)"
    }

    /// Whether stepping to an older match (↑) is possible (either another loaded hit or another page).
    public var canStepPrevious: Bool {
        guard let selectedIndex, !hits.isEmpty else { return false }
        return selectedIndex + 1 < hits.count || hasMore
    }

    /// Whether stepping to a newer match (↓) is possible.
    public var canStepNext: Bool {
        guard let selectedIndex, !hits.isEmpty else { return false }
        return selectedIndex > 0
    }

    /// Applies an updated list of room-scoped hits.
    /// Returns the hit to jump to if the selected match changed (e.g. first result, new query, pending load-more, or deleted selection);
    /// returns `nil` when the user's currently selected match stays anchored in place across a background refresh.
    @discardableResult
    public mutating func apply(hits newHits: [MessageSearchHit], hasMore newHasMore: Bool, queryChanged: Bool) -> MessageSearchHit? {
        let oldCount = hits.count
        let oldIndex = selectedIndex
        let oldEvent = selectedEventID
        hits = newHits
        hasMore = newHasMore

        guard !newHits.isEmpty else {
            selectedIndex = nil
            selectedEventID = nil
            pendingAdvanceAfterLoadMore = false
            return nil
        }

        if queryChanged {
            pendingAdvanceAfterLoadMore = false
            selectedIndex = 0
            selectedEventID = newHits[0].eventID
            return newHits[0]
        }

        if pendingAdvanceAfterLoadMore {
            pendingAdvanceAfterLoadMore = false
            let candidate = min((oldIndex ?? (oldCount - 1)) + 1, newHits.count - 1)
            selectedIndex = candidate
            selectedEventID = newHits[candidate].eventID
            return newHits[candidate].eventID != oldEvent ? newHits[candidate] : nil
        }

        // Keep the reader anchored on the same match when background indexing appends older hits or live sync prepends a newer hit.
        if let oldEvent, let relocated = newHits.firstIndex(where: { $0.eventID == oldEvent }) {
            selectedIndex = relocated
            return nil
        }

        // First hits arrived or the previously selected hit was deleted on the server: select the nearest valid hit.
        let clamped = min(oldIndex ?? 0, newHits.count - 1)
        selectedIndex = clamped
        selectedEventID = newHits[clamped].eventID
        return newHits[clamped]
    }

    /// Moves to an older match (↑ in the timeline). Requests `.loadMore` when at the oldest loaded match and more pages exist.
    public mutating func stepPrevious() -> StepOutcome {
        guard let selectedIndex, !hits.isEmpty else { return .none }
        let nextIndex = selectedIndex + 1
        if nextIndex < hits.count {
            self.selectedIndex = nextIndex
            selectedEventID = hits[nextIndex].eventID
            pendingAdvanceAfterLoadMore = false
            return .jump(hits[nextIndex])
        }
        if hasMore {
            pendingAdvanceAfterLoadMore = true
            return .loadMore
        }
        return .none
    }

    /// Moves to a newer match (↓ in the timeline).
    public mutating func stepNext() -> MessageSearchHit? {
        guard let selectedIndex, selectedIndex > 0, hits.indices.contains(selectedIndex - 1) else { return nil }
        pendingAdvanceAfterLoadMore = false
        let nextIndex = selectedIndex - 1
        self.selectedIndex = nextIndex
        selectedEventID = hits[nextIndex].eventID
        return hits[nextIndex]
    }

    /// Cancels a pending advance when `loadMore` fails or returns no additional hits.
    public mutating func cancelPendingLoadMore() {
        pendingAdvanceAfterLoadMore = false
    }

    public mutating func reset() {
        hits = []
        hasMore = false
        selectedIndex = nil
        selectedEventID = nil
        pendingAdvanceAfterLoadMore = false
    }
}

/// Indexing and availability notice shown inside in-room search while the room's history is not yet completely indexed (M20-11, MESSAGE_SEARCH FR-13).
public struct RoomSearchIndexNotice: Sendable, Equatable {
    public let text: String
    /// `true` while history indexing is actively making progress (shows a compact spinner).
    public let isIndexing: Bool
    /// `true` when the device is offline and only on-device history can be searched.
    public let isOffline: Bool

    public init(text: String, isIndexing: Bool, isOffline: Bool) {
        self.text = text
        self.isIndexing = isIndexing
        self.isOffline = isOffline
    }

    /// Returns `nil` once this room is completely indexed (or server-blocked with no more history available).
    public static func describe(
        coverage: RoomSearchCoverage?,
        status: SearchIndexStatus,
        locale: Locale = .current
    ) -> RoomSearchIndexNotice? {
        if status.phase == .unavailable {
            return RoomSearchIndexNotice(
                text: "Search index unavailable while your device is locked.",
                isIndexing: false,
                isOffline: false
            )
        }
        if let coverage, coverage.state == .complete || coverage.state == .blocked {
            return nil
        }

        let base: String
        if let oldest = coverage?.oldest {
            base = "Searched back to \(oldest.formatted(.dateTime.month(.wide).year().locale(locale)))"
        } else {
            base = "Indexing earlier messages…"
        }

        switch status.phase {
        case .paused(.offline):
            let detail = coverage?.oldest != nil
                ? "\(base) · Offline, searching messages on this device"
                : "Offline · Searching messages on this device"
            return RoomSearchIndexNotice(text: detail, isIndexing: false, isOffline: true)
        case .paused(let reason):
            if let pause = pauseLabel(reason) {
                let text = coverage?.oldest != nil ? "\(base) · \(pause)" : pause
                return RoomSearchIndexNotice(text: text, isIndexing: false, isOffline: false)
            }
            return RoomSearchIndexNotice(text: base, isIndexing: true, isOffline: false)
        case .indexing:
            return RoomSearchIndexNotice(text: base, isIndexing: true, isOffline: false)
        case .stopped:
            return RoomSearchIndexNotice(text: "Starting search index…", isIndexing: true, isOffline: false)
        case .done:
            // Global phase is done, yet this specific room has no complete coverage row yet (e.g. just opened or newly joined).
            guard coverage != nil else { return nil }
            return RoomSearchIndexNotice(text: base, isIndexing: false, isOffline: false)
        case .unavailable:
            return nil
        }
    }

    private static func pauseLabel(_ reason: SearchIndexPolicy.Pause) -> String? {
        switch reason {
        case .user: "History indexing paused in Settings"
        case .lowPower: "History indexing paused in Low Power Mode"
        case .hot: "History indexing paused while iPhone is warm"
        case .mobileData: "History indexing paused on mobile data"
        case .offline: "Offline · Searching messages on this device"
        case .storageFull: "History indexing paused: no space left"
        case .busy, .background: nil
        }
    }
}
