import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import FeatureTimeline

/// A gate the test opens by hand: `wait()` suspends until `open()` (or returns at once afterwards).
private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrived = 0
    }
    private let state = Mutex(State())

    var arrived: Int { state.withLock { $0.arrived } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                state.arrived += 1
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor
@Suite("TimelineViewModel lifecycle (audit F-10)")
struct TimelineLifecycleTests {
    @Test("a screen closed while its timeline is still opening leaves no timeline open behind it")
    func stopDuringStart() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let gate = Gate()
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room), room: room,
            readThrough: { await gate.wait(); return nil },
            locale: Locale(identifier: "en_US"), timeZone: .gmt)

        let starting = Task { await model.start() }
        while gate.arrived == 0 { await Task.yield() }  // the start is suspended inside its opening steps
        let stopping = Task { await model.stop() }
        for _ in 0..<1_000 { await Task.yield() }
        gate.open()
        await starting.value
        await stopping.value
        for _ in 0..<1_000 { await Task.yield() }

        #expect(port.openSessions(in: room) == 0, "the stopped screen's timeline must be closed")
        #expect(model.observation == nil)
    }

    @Test("a timeline stopped during its start opens normally on the next start")
    func restartAfterInterruptedStart() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room, items: [TimelineItem(id: TimelineItemID("a"), content: .event(TimelineEvent(
            eventID: try EventID("$a"), sender: try UserID("@alice:x.org"), senderName: "Alice",
            timestamp: Date(timeIntervalSince1970: 0), isOwn: false, kind: .text("hi", isEdited: false))))])
        let gate = Gate()
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room), room: room,
            readThrough: { await gate.wait(); return nil },
            locale: Locale(identifier: "en_US"), timeZone: .gmt)

        let starting = Task { await model.start() }
        while gate.arrived == 0 { await Task.yield() }
        let stopping = Task { await model.stop() }
        for _ in 0..<1_000 { await Task.yield() }
        gate.open()
        await starting.value
        await stopping.value

        await model.start()
        for _ in 0..<200_000 { if case .live = model.content { break }; await Task.yield() }
        guard case .live(let rows, _, _, _) = model.content else {
            Issue.record("expected the timeline to be live after the second start")
            return
        }
        #expect(rows.contains { $0.text == "hi" })
        #expect(port.openSessions(in: room) == 1)
        await model.stop()
        #expect(port.openSessions(in: room) == 0)
    }
}
