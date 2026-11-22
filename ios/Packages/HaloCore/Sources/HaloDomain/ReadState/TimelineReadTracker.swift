import Foundation
import HaloFoundation

/// Tracks visible confirmed events in an open timeline and picks the read-receipt candidate strictly by **timeline order**
/// (index in the SDK's timeline items), never by `origin_server_ts` (R-06, ADR-0020).
///
/// Pure value type so equal-millisecond timestamps, federated clock skew, and tail detection are directly unit-testable.
public struct TimelineReadTracker: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public let event: EventID
        public let timestamp: Date
        /// True when this event is the newest confirmed event in the current timeline snapshot (so a trailing hidden
        /// event like an encrypted poll vote can also be covered via `Timeline.latestEventId()`, R-01/R-06).
        public let isAtTail: Bool
        /// True when this event is strictly later in timeline order than the previously reported event in this session.
        public let advancesOrder: Bool
    }

    private var order: [EventID: Int] = [:]
    private var timestamps: [EventID: Date] = [:]
    private var tailEvent: EventID?
    private var visible: Set<EventID> = []
    private var reportedEvent: EventID?

    public init() {}

    /// Updates the timeline's confirmed event order from a fresh snapshot.
    public mutating func update(items: [TimelineItem]) {
        var nextOrder: [EventID: Int] = [:]
        var nextTimes: [EventID: Date] = [:]
        var last: EventID?
        for (index, item) in items.enumerated() {
            guard case .event(let event) = item.content, let id = event.eventID else { continue }
            nextOrder[id] = index
            nextTimes[id] = event.timestamp
            last = id
        }
        order = nextOrder
        timestamps = nextTimes
        tailEvent = last
        visible.formIntersection(nextOrder.keys)
    }

    /// Records a row entering or leaving the visible viewport (D6).
    public mutating func setVisible(_ eventID: EventID, isVisible: Bool) {
        if isVisible { visible.insert(eventID) } else { visible.remove(eventID) }
    }

    /// Marks `eventID` as reported to `ReadReceiptCoordinator` so subsequent candidates know whether they advance past it.
    public mutating func markReported(_ eventID: EventID) {
        reportedEvent = eventID
    }

    /// The newest visible confirmed event in **timeline order** (highest index), or `nil` when inactive or nothing is visible.
    public func candidate(isActive: Bool) -> Candidate? {
        guard isActive else { return nil }
        guard let best = visible.compactMap({ id -> (id: EventID, index: Int)? in
            guard let index = order[id] else { return nil }
            return (id, index)
        }).max(by: { $0.index < $1.index }), let timestamp = timestamps[best.id] else { return nil }

        let advances: Bool = {
            guard let previous = reportedEvent else { return true }
            if previous == best.id { return false }
            guard let prevIndex = order[previous] else { return true }
            return best.index > prevIndex
        }()
        return Candidate(event: best.id, timestamp: timestamp, isAtTail: best.id == tailEvent, advancesOrder: advances)
    }
}
