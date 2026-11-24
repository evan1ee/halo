import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("NotificationProcessor (NSE pipeline, R-08)")
struct NotificationProcessorTests {
    private let roomA = try! RoomID("!a:x.org")
    private let roomB = try! RoomID("!b:x.org")
    private let ev1 = try! EventID("$e1")
    private let ev2 = try! EventID("$e2")
    private let eventTs = Date(timeIntervalSince1970: 5_000)
    private let now = Date(timeIntervalSince1970: 6_000)

    @Test("display pushes in background add records and recompute total unread-message badge (D82)")
    func backgroundDisplay() async {
        let fetcher = FakeNotificationFetchPort()
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Alice", body: "Hello 1", timestamp: eventTs, isMention: false, mode: .allMessages))), for: ev1)
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Alice", body: "Hello 2", timestamp: eventTs.addingTimeInterval(1), isMention: false, mode: .allMessages))), for: ev2)
        let records = FakeNotificationRecords()
        let processor = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [roomB: 3] }, isAppForeground: { false }, now: { now })

        // Room B had 3 unread; first push in room A gives badge 4, second push in room A gives badge 5.
        let first = await processor.process(room: roomA, event: ev1)
        #expect(first == .deliver(title: "Alice", body: "Hello 1", threadID: roomA.rawValue, badge: 4, outcome: "display", attentionCounts: [roomB: 3, roomA: 1]))
        let second = await processor.process(room: roomA, event: ev2)
        #expect(second == .deliver(title: "Alice", body: "Hello 2", threadID: roomA.rawValue, badge: 5, outcome: "display", attentionCounts: [roomB: 3, roomA: 2]))
        #expect(records.all().count == 2)
    }

    @Test("PS32 (R-08): foreground app leaves badge nil; mentions-only non-mention and mute never add a badge unit")
    func foregroundAndModeAwareBadge() async {
        let fetcher = FakeNotificationFetchPort()
        let records = FakeNotificationRecords()

        // 1. App is foreground: even an all-messages push leaves badge nil so NSE never overwrites app's newer badge.
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Alice", body: "Hi", timestamp: eventTs, isMention: false, mode: .allMessages))), for: ev1)
        let fg = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [roomB: 1] }, isAppForeground: { true }, now: { now })
        #expect(await fg.process(room: roomA, event: ev1) == .deliver(title: "Alice", body: "Hi", threadID: roomA.rawValue, badge: nil, outcome: "display"))

        // 2. App is background, room is mentions-only, push is NOT a mention: badge stays nil (room not added).
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Team", body: "Bob: chatter", timestamp: eventTs, isMention: false, mode: .mentionsAndKeywords))), for: ev2)
        let bg = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [roomB: 1] }, isAppForeground: { false }, now: { now })
        #expect(await bg.process(room: roomA, event: ev2) == .deliver(title: "Team", body: "Bob: chatter", threadID: roomA.rawValue, badge: nil, outcome: "display"))

        // 3. Mentions-only room WITH mention in background: room gains attention, badge becomes 2.
        let ev3 = try! EventID("$e3")
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Team", body: "Bob: @you", timestamp: eventTs, isMention: true, mode: .mentionsAndKeywords))), for: ev3)
        #expect(await bg.process(room: roomA, event: ev3) == .deliver(title: "Team", body: "Bob: @you", threadID: roomA.rawValue, badge: 2, outcome: "display", attentionCounts: [roomB: 1, roomA: 1]))

        // 4. Muted room in background: badge stays nil even for a mention.
        let ev4 = try! EventID("$e4")
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Muted", body: "@you", timestamp: eventTs, isMention: true, mode: .mute))), for: ev4)
        #expect(await bg.process(room: roomA, event: ev4) == .deliver(title: "Muted", body: "@you", threadID: roomA.rawValue, badge: nil, outcome: "display"))
    }

    @Test("encrypted UTD push stamps event timestamp and respects room notification mode (R-02, R-08)")
    func encryptedPush() async {
        let fetcher = FakeNotificationFetchPort()
        let records = FakeNotificationRecords()
        fetcher.setResult(.success(.encrypted(roomName: "Secret", timestamp: eventTs, mode: .allMessages)), for: ev1)
        fetcher.setResult(.success(.encrypted(roomName: "Group", timestamp: eventTs, mode: .mentionsAndKeywords)), for: ev2)
        let processor = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [:] }, isAppForeground: { false }, now: { now })

        #expect(await processor.process(room: roomA, event: ev1) == .deliver(title: "Secret", body: "Encrypted message", threadID: roomA.rawValue, badge: 1, outcome: "encrypted", attentionCounts: [roomA: 1]))
        #expect(await processor.process(room: roomB, event: ev2) == .deliver(title: "Group", body: "Encrypted message", threadID: roomB.rawValue, badge: nil, outcome: "encrypted"))
        #expect(records.all().first?.timestamp == eventTs)
    }

    @Test("duplicate pushes, suppressed events and fetch errors are handled without creating duplicate or phantom records (AC-U7)")
    func duplicateSuppressedAndError() async {
        let fetcher = FakeNotificationFetchPort()
        let records = FakeNotificationRecords()
        fetcher.setResult(.success(.display(NotificationDisplay(title: "A", body: "1", timestamp: eventTs))), for: ev1)
        fetcher.setResult(.success(.suppressed), for: ev2)
        let ev3 = try! EventID("$e3")
        fetcher.setResult(.failure(.network(retryable: true)), for: ev3)

        let processor = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [:] }, isAppForeground: { false }, now: { now })

        #expect(await processor.process(room: roomA, event: ev1) == .deliver(title: "A", body: "1", threadID: roomA.rawValue, badge: 1, outcome: "display", attentionCounts: [roomA: 1]))
        #expect(await processor.process(room: roomA, event: ev1) == .suppressed(outcome: "duplicate"))
        #expect(await processor.process(room: roomA, event: ev2) == .suppressed(outcome: "suppressed"))
        #expect(await processor.process(room: roomA, event: ev3) == .fallback(outcome: "error"))
        #expect(records.all().count == 1)
    }

    @Test("R-23: SingleFlightCache reuses one initialized client across concurrent pushes and rebuilds when the session key changes")
    func singleFlightClientCache() async throws {
        actor Gate {
            var builds = 0
            var started: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?

            func beginBuild() -> Int {
                builds += 1
                if let cont = started {
                    started = nil
                    cont.resume()
                }
                return builds
            }

            func waitUntilStarted() async {
                if builds > 0 { return }
                await withCheckedContinuation { cont in started = cont }
            }

            func waitForRelease() async {
                await withCheckedContinuation { cont in release = cont }
            }

            func triggerRelease() {
                if let cont = release {
                    release = nil
                    cont.resume()
                }
            }

            func buildCount() -> Int { builds }
        }

        let cache = SingleFlightCache<String, Int>()
        let gate = Gate()

        let first = Task {
            try await cache.value(for: "alice:dev1") {
                let n = await gate.beginBuild()
                await gate.waitForRelease()
                return n
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await cache.value(for: "alice:dev1") {
                await gate.beginBuild()
            }
        }
        for _ in 0..<2_000 { await Task.yield() }
        await gate.triggerRelease()

        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(await gate.buildCount() == 1)

        // Subsequent push for the same session reuses cached value; different session rebuilds.
        #expect(try await cache.value(for: "alice:dev1") { await gate.beginBuild() } == 1)
        #expect(try await cache.value(for: "bob:dev2") { await gate.beginBuild() } == 2)
        #expect(await gate.buildCount() == 2)
    }

    @Test("background pushes across multiple rooms preserve earlier rooms and return attention counts for widgets")
    func multiRoomBackgroundPushesPreserveEarlierRooms() async {
        let fetcher = FakeNotificationFetchPort()
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Alice", body: "In A", timestamp: eventTs, isMention: false, mode: .allMessages))), for: ev1)
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Bob", body: "In B", timestamp: eventTs.addingTimeInterval(1), isMention: false, mode: .allMessages))), for: ev2)
        let records = FakeNotificationRecords()
        let cutoff = now.addingTimeInterval(-60)
        let processor = NotificationProcessor(
            fetcher: fetcher, records: records,
            lastAttention: { ([:], cutoff) }, isAppForeground: { false }, now: { now })

        let first = await processor.process(room: roomA, event: ev1)
        let second = await processor.process(room: roomB, event: ev2)
        if case .deliver(_, _, _, let badge1, _, _) = first {
            #expect(badge1 == 1)
        } else {
            Issue.record("Expected deliver for first push")
        }
        if case .deliver(_, _, _, let badge2, _, _) = second {
            #expect(badge2 == 2)
        } else {
            Issue.record("Expected deliver for second push")
        }
    }
}
