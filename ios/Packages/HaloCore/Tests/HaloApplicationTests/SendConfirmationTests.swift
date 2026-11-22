import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloApplication

@Suite("SendConfirmation")
struct SendConfirmationTests {
    private func item(_ id: String, _ state: SendState, own: Bool = true) -> TimelineItem {
        TimelineItem(id: TimelineItemID(id), content: .event(TimelineEvent(
            eventID: state == .sent ? try? EventID("$\(id)") : nil, sender: nil, senderName: nil, timestamp: Date(), isOwn: own,
            kind: .text("x", isEdited: false), sendState: state)))
    }

    @Test("an echo that turns sent confirms; nothing is confirmed before it does")
    func confirms() {
        var tracker = SendConfirmation(expected: 1)
        tracker.apply(.reset([]))
        #expect(tracker.state == .waiting)
        tracker.apply(.pushBack(item("a", .sending)))
        #expect(tracker.state == .waiting)
        tracker.apply(.set(index: 0, item("a", .sent)))
        #expect(tracker.state == .confirmed)
    }

    @Test("it waits for every expected message")
    func waitsForAll() {
        var tracker = SendConfirmation(expected: 2)
        tracker.apply(.reset([]))
        tracker.apply(.append([item("a", .sending), item("b", .sending)]))
        tracker.apply(.set(index: 0, item("a", .sent)))
        #expect(tracker.state == .waiting)
        tracker.apply(.set(index: 1, item("b", .sent)))
        #expect(tracker.state == .confirmed)
    }

    @Test("a failed echo fails the delivery")
    func fails() {
        var tracker = SendConfirmation(expected: 1)
        tracker.apply(.reset([]))
        tracker.apply(.pushBack(item("a", .failed(recoverable: true))))
        #expect(tracker.state == .failed)
    }

    @Test("echoes already in the first state, other people's messages and confirmed history are ignored")
    func baseline() {
        var tracker = SendConfirmation(expected: 1)
        tracker.apply(.reset([item("old", .sending), item("theirs", .sent, own: false), item("mine", .sent)]))
        #expect(tracker.state == .waiting)
        tracker.apply(.set(index: 0, item("old", .sent)))
        #expect(tracker.state == .waiting)
        tracker.apply(.pushBack(item("new", .sending)))
        tracker.apply(.set(index: 3, item("new", .sent)))
        #expect(tracker.state == .confirmed)
    }
}
