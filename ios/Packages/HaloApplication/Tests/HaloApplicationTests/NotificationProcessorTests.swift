import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
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

    @Test("display push in background adds record and computes badge from app attention set + room")
    func backgroundDisplay() async {
        let fetcher = FakeNotificationFetchPort()
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Alice", body: "Hello", timestamp: eventTs, isMention: false, mode: .allMessages))), for: ev1)
        let records = FakeNotificationRecords()
        let processor = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [roomB] }, isAppForeground: { false }, now: { now })

        let decision = await processor.process(room: roomA, event: ev1)
        #expect(decision == .deliver(title: "Alice", body: "Hello", threadID: roomA.rawValue, badge: 2, outcome: "display"))
        #expect(records.all() == [NotificationRecord(roomID: roomA, eventID: ev1, timestamp: eventTs, isMention: false, deliveredAt: now, source: .nse)])
    }

    @Test("PS32 (R-08): foreground app leaves badge nil; mentions-only non-mention and mute never add a badge unit")
    func foregroundAndModeAwareBadge() async {
        let fetcher = FakeNotificationFetchPort()
        let records = FakeNotificationRecords()

        // 1. App is foreground: even an all-messages push leaves badge nil so NSE never overwrites app's newer badge.
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Alice", body: "Hi", timestamp: eventTs, isMention: false, mode: .allMessages))), for: ev1)
        let fg = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [roomB] }, isAppForeground: { true }, now: { now })
        #expect(await fg.process(room: roomA, event: ev1) == .deliver(title: "Alice", body: "Hi", threadID: roomA.rawValue, badge: nil, outcome: "display"))

        // 2. App is background, room is mentions-only, push is NOT a mention: badge stays nil (room not added).
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Team", body: "Bob: chatter", timestamp: eventTs, isMention: false, mode: .mentionsAndKeywords))), for: ev2)
        let bg = NotificationProcessor(
            fetcher: fetcher, records: records, lastAttention: { [roomB] }, isAppForeground: { false }, now: { now })
        #expect(await bg.process(room: roomA, event: ev2) == .deliver(title: "Team", body: "Bob: chatter", threadID: roomA.rawValue, badge: nil, outcome: "display"))

        // 3. Mentions-only room WITH mention in background: room gains attention, badge becomes 2.
        let ev3 = try! EventID("$e3")
        fetcher.setResult(.success(.display(NotificationDisplay(
            title: "Team", body: "Bob: @you", timestamp: eventTs, isMention: true, mode: .mentionsAndKeywords))), for: ev3)
        #expect(await bg.process(room: roomA, event: ev3) == .deliver(title: "Team", body: "Bob: @you", threadID: roomA.rawValue, badge: 2, outcome: "display"))

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
            fetcher: fetcher, records: records, lastAttention: { [] }, isAppForeground: { false }, now: { now })

        #expect(await processor.process(room: roomA, event: ev1) == .deliver(title: "Secret", body: "Encrypted message", threadID: roomA.rawValue, badge: 1, outcome: "encrypted"))
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
            fetcher: fetcher, records: records, lastAttention: { [] }, isAppForeground: { false }, now: { now })

        #expect(await processor.process(room: roomA, event: ev1) == .deliver(title: "A", body: "1", threadID: roomA.rawValue, badge: 1, outcome: "display"))
        #expect(await processor.process(room: roomA, event: ev1) == .suppressed(outcome: "duplicate"))
        #expect(await processor.process(room: roomA, event: ev2) == .suppressed(outcome: "suppressed"))
        #expect(await processor.process(room: roomA, event: ev3) == .fallback(outcome: "error"))
        #expect(records.all().count == 1)
    }
}
