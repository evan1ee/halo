import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("ReadReceiptCoordinator")
struct ReadReceiptCoordinatorTests {
    private final class Clock: Sendable {
        let value = Mutex(ContinuousClock.now)
        let sleeps = Mutex<[Duration]>([])
        func advance(_ d: Duration) { value.withLock { $0 = $0.advanced(by: d) } }
        /// A sleep that records, advances the clock and returns at once.
        func sleep(_ d: Duration) { sleeps.withLock { $0.append(d) }; advance(d) }
    }

    private let room = try! RoomID("!r:halo.localhost")
    private func event(_ n: Int) -> EventID { try! EventID("$e\(n)") }
    private func at(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n)) }

    private func make(private priv: Bool = false, store: (any ReadIntentPort)? = nil, wall: Date = Date(timeIntervalSince1970: 1_000_000)) -> (ReadReceiptCoordinator, FakeReadMarkerPort, Clock) {
        let port = FakeReadMarkerPort()
        let clock = Clock()
        let coordinator = ReadReceiptCoordinator(
            port: port, store: store, privateReceipts: priv, wallClock: { wall }, now: { clock.value.withLock { $0 } }, sleep: { clock.sleep($0) })
        return (coordinator, port, clock)
    }

    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<200_000 { if condition() { return true }; await Task.yield() }
        return false
    }

    @Test func firstSeenEventSendsReceiptAndMarker() async {
        let (c, port, _) = make()
        await c.reportSeen(room: room, event: event(1), timestamp: at(10))
        #expect(await eventually { port.receipts.count == 1 && port.markers.count == 1 })
        #expect(port.receipts == [.init(room: room, event: event(1), isPrivate: false)])
    }

    @Test func olderOrEqualCandidatesAreIgnored() async {
        let (c, port, _) = make()
        await c.reportSeen(room: room, event: event(2), timestamp: at(20))
        #expect(await eventually { port.receipts.count == 1 })
        await c.reportSeen(room: room, event: event(1), timestamp: at(10))
        await c.reportSeen(room: room, event: event(3), timestamp: at(20))
        await c.flush()
        #expect(port.receipts.count == 1)
        #expect(await c.readPosition(of: room) == at(20))
    }

    @Test func burstWithinIntervalSendsOnlyNewestAfterWaiting() async {
        let (c, port, clock) = make()
        await c.reportSeen(room: room, event: event(1), timestamp: at(10))
        #expect(await eventually { port.receipts.count == 1 })
        await c.reportSeen(room: room, event: event(2), timestamp: at(20))
        await c.reportSeen(room: room, event: event(3), timestamp: at(30))
        // With an instant fake sleep event 2 may go out before 3 is reported; either way the newest ends up sent, in order,
        // and the first receipt was never repeated.
        #expect(await eventually { port.receipts.last?.event == event(3) })
        let sent = port.receipts.map(\.event.rawValue)
        #expect(sent == sent.sorted() && Set(sent).count == sent.count && sent.first == "$e1")
        #expect(clock.sleeps.withLock { $0 }.allSatisfy { $0 <= ReadReceiptCoordinator.minimumInterval })
    }

    @Test func privateSettingUsesPrivateReceipts() async {
        let (c, port, _) = make(private: true)
        await c.reportSeen(room: room, event: event(1), timestamp: at(10))
        #expect(await eventually { port.receipts.count == 1 })
        #expect(port.receipts.first?.isPrivate == true)
    }

    @Test func retryableFailureBacksOffAndRetries() async {
        let (c, port, clock) = make()
        port.failNextReceipts(with: [.network(retryable: true), .network(retryable: true)])
        await c.reportSeen(room: room, event: event(1), timestamp: at(10))
        #expect(await eventually { port.receipts.count == 1 })
        let sleeps = clock.sleeps.withLock { $0 }
        #expect(sleeps.contains(.seconds(1)) && sleeps.contains(.seconds(2)))
    }

    @Test func nonRetryableFailureStopsUntilNewIntentOrFlush() async {
        let (c, port, _) = make()
        port.failNextReceipts(with: [.forbidden])
        await c.reportSeen(room: room, event: event(1), timestamp: at(10))
        for _ in 0..<1000 { await Task.yield() }
        #expect(port.receipts.isEmpty)
        await c.flush()
        #expect(port.receipts.count == 1)
    }

    @Test("intents are stored, marked sent after the receipt, and an unsent stored one is sent after a relaunch")
    func persistence() async throws {
        let store = FakeReadIntents()
        let (c, port, _) = make(store: store)
        await c.reportSeen(room: room, event: event(1), timestamp: at(10))
        #expect(await eventually { port.receipts.count == 1 && store.intents.first?.isSent == true })

        // Relaunch with an unsent intent in the store.
        let pending = FakeReadIntents([ReadIntent(room: room, event: event(5), timestamp: at(50), createdAt: Date(timeIntervalSince1970: 999_000))])
        let (again, port2, _) = make(store: pending)
        await again.restore()
        #expect(await eventually { port2.receipts.map(\.event) == [event(5)] })
        #expect(await again.readPosition(of: room) == at(50))
    }

    @Test("restore drops sent intents older than seven days and doesn't resend sent ones")
    func restoreExpiry() async throws {
        let wall = Date(timeIntervalSince1970: 10_000_000)
        let old = ReadIntent(room: room, event: event(1), timestamp: at(1), isSent: true, createdAt: wall.addingTimeInterval(-8 * 24 * 3600))
        let other = try RoomID("!o:halo.localhost")
        let recent = ReadIntent(room: other, event: event(2), timestamp: at(2), isSent: true, createdAt: wall.addingTimeInterval(-3600))
        let store = FakeReadIntents([old, recent])
        let (c, port, _) = make(store: store, wall: wall)
        await c.restore()
        #expect(store.intents.map(\.room) == [other])
        await c.flush()
        #expect(port.receipts.isEmpty)
        #expect(await c.readPosition(of: other) == at(2))
    }

    @Test func markRoomReadSendsClearsTheFlagAndRecordsASentPosition() async throws {
        let (c, port, _) = make()
        port.setLatestEvent(event(7), in: room)
        try await c.markRoomUnread(room)
        #expect(port.unreadFlags[room] == true)
        try await c.markRoomRead(room, latestEventTime: at(70))
        #expect(port.receipts == [.init(room: room, event: event(7), isPrivate: false)])
        #expect(port.unreadFlags[room] == false)
        #expect(await c.readPosition(of: room) == at(70))
        // Already sent: nothing further goes out, and an older event doesn't move the position back.
        await c.flush()
        #expect(port.receipts.count == 1)
        await c.reportSeen(room: room, event: event(3), timestamp: at(30))
        #expect(await c.readPosition(of: room) == at(70))
    }

    @Test func markRoomReadInARoomWithoutEventsOnlyClearsTheFlag() async throws {
        let (c, port, _) = make()
        try await c.markRoomRead(room, latestEventTime: nil)
        #expect(port.receipts.isEmpty)
        #expect(port.unreadFlags[room] == false)
        #expect(await c.readPosition(of: room) == nil)
    }
}
