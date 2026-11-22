import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("TimelineReadTracker (R-06)")
struct TimelineReadTrackerTests {
    private let sender = try! UserID("@bob:x.org")

    private func item(_ id: String, ts: Double) throws -> TimelineItem {
        let eventID = try EventID(id)
        return TimelineItem(
            id: TimelineItemID(id),
            content: .event(TimelineEvent(
                eventID: eventID, sender: sender, senderName: "Bob",
                timestamp: Date(timeIntervalSince1970: ts), isOwn: false,
                kind: .text(id, isEdited: false), sendState: .sent)))
    }

    @Test("PS28: picks the later message in timeline order when two messages share the exact same millisecond timestamp")
    func equalTimestampsPickLaterInTimelineOrder() throws {
        var tracker = TimelineReadTracker()
        let e1 = try EventID("$1"), e2 = try EventID("$2")
        tracker.update(items: [try item("$1", ts: 100), try item("$2", ts: 100)])
        tracker.setVisible(e1, isVisible: true)
        tracker.setVisible(e2, isVisible: true)

        let c = try #require(tracker.candidate(isActive: true))
        #expect(c.event == e2 && c.isAtTail && c.advancesOrder)
    }

    @Test("PS29: picks the later message in timeline order even when its federated clock is behind or ahead")
    func skewedClockPicksTimelineOrderNotTimestamp() throws {
        var tracker = TimelineReadTracker()
        let futureSkewed = try EventID("$future"), normalLater = try EventID("$normal"), slowSkewed = try EventID("$slow")
        tracker.update(items: [
            try item("$future", ts: 9_999),
            try item("$normal", ts: 1_000),
            try item("$slow", ts: 400),
        ])
        tracker.setVisible(futureSkewed, isVisible: true)
        tracker.markReported(futureSkewed)

        tracker.setVisible(normalLater, isVisible: true)
        let mid = try #require(tracker.candidate(isActive: true))
        #expect(mid.event == normalLater && !mid.isAtTail && mid.advancesOrder)
        tracker.markReported(normalLater)

        tracker.setVisible(slowSkewed, isVisible: true)
        let tail = try #require(tracker.candidate(isActive: true))
        #expect(tail.event == slowSkewed && tail.isAtTail && tail.advancesOrder)
    }
}
