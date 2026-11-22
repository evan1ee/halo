import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

@Suite("TimelineReadTracker integration in TimelineViewModel (R-06)")
struct TimelineReadTrackerViewModelTests {
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

    @Test("R-01/R-06: viewing the tail row in TimelineViewModel targets Timeline.latestEventId() to cover trailing non-row events (poll votes)")
    @MainActor
    func tailRowCoversTrailingPollVote() async throws {
        let room = try RoomID("!r:x.org")
        let vote = try EventID("$vote")
        let timelines = FakeTimelinePort()
        timelines.addRoom(room, items: [try item("$msg", ts: 100)])
        timelines.setLatestEventID(vote, in: room)
        let markers = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: markers, sleep: { _ in })
        let coordinator = TimelineCoordinator(port: timelines, room: room)
        let model = TimelineViewModel(coordinator: coordinator, receipts: receipts, room: room, dwell: .zero, sleep: { _ in })
        await model.start()
        for _ in 0..<20_000 {
            if case .live(let rows, _, _, _) = model.content, !rows.isEmpty { break }
            await Task.yield()
        }
        guard case .live(let rows, _, _, _) = model.content, let row = rows.first else {
            Issue.record("expected live row")
            return
        }
        model.rowVisibility(row, isVisible: true)
        for _ in 0..<100_000 where markers.receipts.isEmpty { await Task.yield() }
        #expect(markers.receipts == [.init(room: room, event: vote, isPrivate: false)])
    }
}
