import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

// Scenarios S01–S24 of docs/testing/UNREAD_REGRESSION_TESTS.md §3.
//
// These run the real `ReadStatePolicy`, `ReadReceiptCoordinator` and `BadgeCoordinator` against `World`, an in-process
// model of the parts of Synapse and of device A1's sync that the scenarios need (server counts after the user's newest
// receipt on any device, limited timelines, push rules per mode, `m.marked_unread`). They are NOT run against a real
// homeserver: the Docker scenario driver of TEST_STRATEGY §3 does not exist yet, and the model encodes our reading of
// server behaviour; the count rules are re-checked against Synapse by tools/server-rules/check_server_rules.py. Where a
// scenario depends on a reading that is not checked there, it says so.

private enum Who { case a, b, c }
/// `vote`: an encrypted event that isn't a message (a poll vote, a call signal): the server's rules see only `m.room.encrypted`
/// and count it, the SDK doesn't (verified: ClassicSyncEvidenceTests.encryptedNonMessageEvidence, R-01).
private enum Kind { case message, edit, redacted, vote }

private struct Ev {
    let id: EventID
    let ts: Date
    let sender: Who
    let mention: Bool
    var kind: Kind
}

private struct WRoom {
    var encrypted: Bool
    var mode: NotificationMode
    var events: [Ev] = []
    /// Index of the event the user's newest receipt (any device) points at.
    var receipt: Int?
    var marked = false
}

/// What device A1 knew after its last sync of a room.
private struct Snap {
    var encrypted = false
    var mode = NotificationMode.allMessages
    var known: Set<EventID> = []
    var undecrypted: Set<EventID> = []
    var server = ServerCounts.zero
    var sdk = SDKCounts.zero
    /// The own receipt as the SDK knows it.
    var receiptIdx: Int?
    var latest: LatestEventRef?
    var marked = false
}

private struct World {
    var rooms: [RoomID: WRoom] = [:]
    var snaps: [RoomID: Snap] = [:]
    var order: [RoomID] = []
    var tick = 0

    mutating func addRoom(encrypted: Bool, mode: NotificationMode) -> RoomID {
        let id = try! RoomID("!r\(order.count):x.org")
        rooms[id] = WRoom(encrypted: encrypted, mode: mode)
        order.append(id)
        return id
    }

    mutating func send(_ room: RoomID, _ who: Who, mention: Bool, kind: Kind, skew: Int) -> EventID {
        tick += 1
        let id = try! EventID("$\(tick)")
        let ev = Ev(id: id, ts: Date(timeIntervalSince1970: Double(10_000 + tick * 10 + skew)), sender: who, mention: mention, kind: kind)
        rooms[room]?.events.append(ev)
        return id
    }

    func locate(_ id: EventID) -> (room: RoomID, index: Int)? {
        for (room, r) in rooms { if let i = r.events.firstIndex(where: { $0.id == id }) { return (room, i) } }
        return nil
    }

    func ts(_ id: EventID) -> Date { let l = locate(id)!; return rooms[l.room]!.events[l.index].ts }

    /// A receipt of the user's on any device; the server keeps the newest.
    mutating func read(_ room: RoomID, through id: EventID) {
        guard let l = locate(id), l.room == room else { return }
        let current = rooms[room]?.receipt ?? -1
        rooms[room]?.receipt = max(current, l.index)
    }

    mutating func redact(_ id: EventID) {
        guard let l = locate(id) else { return }
        rooms[l.room]?.events[l.index].kind = .redacted
    }

    static func serverCounts(_ r: WRoom) -> ServerCounts {
        guard !r.encrypted || r.mode == .allMessages, r.mode != .mute else { return .zero }
        var n = 0, h = 0
        for (i, ev) in r.events.enumerated() where i > (r.receipt ?? -1) && ev.sender != .a && (ev.kind == .message || (ev.kind == .vote && r.encrypted)) {
            if r.mode == .allMessages || ev.mention {
                n += 1
                if ev.mention && !r.encrypted { h += 1 }
            }
        }
        return ServerCounts(notification: n, highlight: h)
    }

    /// The SDK counts messages after the receipt that it holds. One it can't decrypt counts as a message too, notifying by the
    /// encrypted-event rule (all-messages mode only) and never as a mention, as the real SDK does (verified against
    /// `infra/dev`: ClassicSyncEvidenceTests.encryptedNonMessageEvidence).
    /// An own event it holds counts as a receipt too (the SDK's implicit receipt, `select_best_receipt`).
    static func sdkCounts(_ r: WRoom, _ s: Snap) -> SDKCounts {
        var m = 0, n = 0, h = 0
        let ownIdx = r.events.indices.last { r.events[$0].sender == .a && s.known.contains(r.events[$0].id) }
        let start = max(s.receiptIdx ?? -1, ownIdx ?? -1)
        for (i, ev) in r.events.enumerated()
        where i > start && s.known.contains(ev.id) && ev.sender != .a && ev.kind == .message {
            m += 1
            if s.undecrypted.contains(ev.id) {
                if s.mode == .allMessages { n += 1 }
                continue
            }
            if ev.mention { h += 1 }
            if s.mode == .allMessages || (s.mode == .mentionsAndKeywords && ev.mention) { n += 1 }
        }
        return SDKCounts(unreadMessages: m, unreadNotifications: n, unreadMentions: h)
    }

    /// Device A1 syncs. `limit` is the timeline length it is sent per room (older events stay a gap); `applyOwnReceipt: false`
    /// models an SDK that hasn't applied the user's receipt from another device yet; `serverStale` keeps the previous
    /// server counts and receipt.
    mutating func sync(
        _ only: RoomID? = nil, limit: Int = .max, applyOwnReceipt: Bool = true, serverStale: Bool = false, undecrypted: Set<EventID> = []
    ) {
        for id in order where only == nil || only == id {
            guard let r = rooms[id] else { continue }
            var s = snaps[id] ?? Snap()
            s.encrypted = r.encrypted
            s.mode = r.mode
            s.marked = r.marked
            for ev in r.events.suffix(limit) { s.known.insert(ev.id) }
            s.undecrypted = undecrypted
            if applyOwnReceipt && !serverStale { s.receiptIdx = r.receipt }
            if !serverStale { s.server = Self.serverCounts(r) }
            s.sdk = Self.sdkCounts(r, s)
            // The SDK's latest event leaves out edits, votes and events it can't decrypt (F-SDK-3).
            s.latest = r.events.last(where: { $0.kind != .edit && $0.kind != .vote && !undecrypted.contains($0.id) })
                .map { LatestEventRef(timestamp: $0.ts, senderIsSelf: $0.sender == .a) }
            snaps[id] = s
        }
    }

    func summary(_ id: RoomID) -> RoomSummary {
        let s = snaps[id]!, r = rooms[id]!
        return RoomSummary(
            id: id, name: nil, isDirect: false, isEncrypted: s.encrypted, membership: .joined,
            read: RoomReadCounts(mode: s.mode, server: s.server, sdk: s.sdk, isMarkedUnread: s.marked), latestEvent: s.latest,
            ownReadThrough: s.receiptIdx.map { r.events[$0].ts })
    }

    func input(_ id: RoomID) -> RoomReadInputs {
        let s = summary(id)
        return RoomReadInputs(
            roomID: id, membership: s.membership, isEncrypted: s.isEncrypted, counts: s.read, latestEvent: s.latestEvent,
            localIntent: s.ownReadThrough, receiptReadThrough: s.ownReadThrough)
    }

    func inputs() -> [RoomReadInputs] { order.filter { snaps[$0] != nil }.map(input) }
}

private final class Clock: Sendable {
    let value = Mutex(ContinuousClock.now)
    let sleeps = Mutex<[Duration]>([])
    func sleep(_ d: Duration) {
        sleeps.withLock { $0.append(d) }
        value.withLock { $0 = $0.advanced(by: d) }
    }
}

/// Device A1 under test (real coordinators and fakes) plus the model server around it.
private struct Rig {
    var world = World()
    let port = FakeReadMarkerPort()
    let store = FakeReadIntents()
    let records = FakeNotificationRecords()
    let clock = Clock()
    let hangs: Bool
    var receipts: ReadReceiptCoordinator

    /// `hangingBackoff`: a retry wait never ends, so retries happen only through `flush()` (network down until the test says so).
    init(hangingBackoff: Bool = false) {
        hangs = hangingBackoff
        receipts = Self.makeReceipts(port: port, store: store, clock: clock, hangs: hangingBackoff)
    }

    private static func makeReceipts(port: FakeReadMarkerPort, store: FakeReadIntents, clock: Clock, hangs: Bool) -> ReadReceiptCoordinator {
        ReadReceiptCoordinator(
            port: port, store: store, wallClock: { Date(timeIntervalSince1970: 2_000_000) }, now: { clock.value.withLock { $0 } },
            sleep: { d in
                if hangs { clock.sleeps.withLock { $0.append(d) }; try await Task.sleep(for: .seconds(3600)) } else { clock.sleep(d) }
            })
    }

    /// The app is killed and started again: a new coordinator over the same database.
    mutating func relaunch() async {
        receipts = Self.makeReceipts(port: port, store: store, clock: clock, hangs: hangs)
        await receipts.restore()
    }

    mutating func addRoom(encrypted: Bool = false, mode: NotificationMode = .allMessages, synced: Bool = true) -> RoomID {
        let id = world.addRoom(encrypted: encrypted, mode: mode)
        if synced { world.sync(id) }
        return id
    }

    @discardableResult
    mutating func send(_ room: RoomID, _ who: Who = .b, mention: Bool = false, kind: Kind = .message, skew: Int = 0) -> EventID {
        world.send(room, who, mention: mention, kind: kind, skew: skew)
    }

    mutating func sync(
        _ only: RoomID? = nil, limit: Int = .max, applyOwnReceipt: Bool = true, serverStale: Bool = false, undecrypted: Set<EventID> = []
    ) {
        world.sync(only, limit: limit, applyOwnReceipt: applyOwnReceipt, serverStale: serverStale, undecrypted: undecrypted)
    }

    /// The user reads on device A2.
    mutating func a2Reads(_ room: RoomID, _ event: EventID) { world.read(room, through: event) }
    mutating func markUnreadOnA2(_ room: RoomID) { world.rooms[room]?.marked = true }
    mutating func setModeOnA2(_ room: RoomID, _ mode: NotificationMode) { world.rooms[room]?.mode = mode }

    /// The user sees `event` on A1 (the timeline's visibility report).
    func view(_ room: RoomID, _ event: EventID) async {
        await receipts.reportSeen(room: room, event: event, timestamp: world.ts(event))
    }

    /// Sends every pending receipt now and lets the server (model) take them in.
    mutating func settle() async {
        await receipts.flush()
        for _ in 0..<2000 { await Task.yield() }
        for sent in port.receipts { world.read(sent.room, through: sent.event) }
        for (room, flag) in port.unreadFlags { world.rooms[room]?.marked = flag }
    }

    /// The notification extension fetched `event` for a push. Only events that notify create a record.
    @discardableResult
    func push(_ id: EventID) -> Bool {
        guard let l = world.locate(id), let r = world.rooms[l.room] else { return false }
        let ev = r.events[l.index]
        guard ev.kind == .message, ev.sender != .a, r.mode != .mute, r.mode == .allMessages || ev.mention else { return false }
        return records.add(NotificationRecord(roomID: l.room, eventID: id, timestamp: ev.ts, isMention: ev.mention))
    }

    private func positions() async -> [RoomID: Date] {
        var result: [RoomID: Date] = [:]
        for id in world.order { if let p = await receipts.readPosition(of: id) { result[id] = p } }
        return result
    }

    func state(_ room: RoomID) async -> RoomReadState {
        let input = world.input(room)
        let read = [await receipts.readPosition(of: room), input.localIntent].compactMap { $0 }.max()
        let base = RoomReadInputs(
            roomID: room, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
            latestEvent: input.latestEvent, localIntent: read, receiptReadThrough: input.receiptReadThrough)
        let notified = ReadStatePolicy.partitionRecords(for: base, records: records.all()).unconfirmed
        return ReadStatePolicy.evaluate(RoomReadInputs(
            roomID: room, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
            latestEvent: input.latestEvent, localIntent: read, receiptReadThrough: input.receiptReadThrough, unconfirmedNotified: notified))
    }

    /// The badge's attention set. Cross-checks `BadgeCoordinator.attention` against the per-room states.
    func attention() async -> Set<RoomID> {
        let set = BadgeCoordinator.attention(inputs: world.inputs(), records: records.all(), positions: await positions())
        var fromStates: Set<RoomID> = []
        for id in world.order where world.snaps[id] != nil { if await state(id).attention { fromStates.insert(id) } }
        #expect(set == fromStates)
        return set
    }
}

private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500_000 { if condition() { return true }; await Task.yield() }
    return false
}

@Suite("Read-state scenarios S01–S28")
struct ReadStateScenarioTests {
    @Test("S01: B sends 5, A1 views them: no attention, receipt at the 5th, badge 0")
    func s01() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let ids = (0..<5).map { _ in rig.send(r) }
        rig.sync()
        #expect(await rig.attention() == [r])
        await rig.view(r, ids[4])
        await rig.settle()
        rig.sync()
        #expect(await rig.attention().isEmpty)
        #expect(rig.port.receipts == [.init(room: r, event: ids[4], isPrivate: false)])
        #expect(rig.world.rooms[r]?.receipt == 4)
    }

    @Test("S02: B sends 5, A2 reads them, A1 syncs: no attention, even with five pushed events recorded")
    func s02() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let ids = (0..<5).map { _ in rig.send(r) }
        for id in ids { rig.push(id) }
        #expect(await rig.attention() == [r])
        rig.a2Reads(r, ids[4])
        rig.sync()
        #expect(await rig.attention().isEmpty)
        #expect(await rig.state(r).reasons.contains(.intentCovers))
    }

    @Test("S03: push first (NSE path), then sync, then viewing: attention from E4, still after sync, cleared after viewing")
    func s03() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let id = rig.send(r)
        rig.push(id)
        #expect(await rig.attention() == [r])  // A1 hasn't synced: only the push knows
        #expect(await rig.state(r).reasons.contains(.notifiedUnsynced))
        rig.sync()
        #expect(await rig.attention() == [r])
        await rig.view(r, id)
        await rig.settle()
        #expect(await rig.attention().isEmpty)
    }

    @Test("S04: 300 messages over 20 rooms while A1 is offline (limited timelines), A2 reads 10: exactly the other 10 have attention")
    func s04() async throws {
        var rig = Rig()
        let rooms = (0..<20).map { _ in rig.addRoom() }
        var latest: [RoomID: EventID] = [:]
        for _ in 0..<15 { for r in rooms { latest[r] = rig.send(r) } }
        for r in rooms.prefix(10) { rig.a2Reads(r, latest[r]!) }
        rig.sync(limit: 5)
        #expect(await rig.attention() == Set(rooms.suffix(10)))
    }

    @Test("S05: A2's receipt targets an event inside A1's gap")
    func s05() async throws {
        var rig = Rig()
        let covered = rig.addRoom(), partial = rig.addRoom()
        let a = (0..<10).map { _ in rig.send(covered) }
        let b = (0..<10).map { _ in rig.send(partial) }
        rig.a2Reads(covered, a[9])  // A2 read everything; A1's timeline holds only the newest event
        rig.a2Reads(partial, b[6])  // A2 read up to the 7th; A1's timeline holds the 8th–10th
        rig.sync(limit: 3)
        #expect(await rig.attention() == [partial])
        // The gap-resident receipt event still resolves to its time, so the covered room is quiet even with limit 1.
        var again = Rig()
        let r = again.addRoom()
        let ids = (0..<10).map { _ in again.send(r) }
        again.a2Reads(r, ids[9])
        again.sync(limit: 1)
        #expect(await again.attention().isEmpty)
    }

    @Test("S06: encrypted group room, all messages, B mentions A, keys arrive late: one unread, then one mention")
    func s06() async throws {
        var rig = Rig()
        let r = rig.addRoom(encrypted: true, mode: .allMessages)
        let id = rig.send(r, mention: true)
        rig.sync(undecrypted: [id])
        var state = await rig.state(r)
        // The SDK counts the event it can't decrypt; the mention is hidden in the ciphertext until the keys arrive.
        #expect(state.attention && state.display == .count(1) && state.reasons == [.sdkCounts])
        rig.sync()  // decrypted
        state = await rig.state(r)
        #expect(state.attention && state.display == .mentions(1))
    }

    @Test("S07: encrypted room in mentions-only mode, 3 messages without a mention: no attention, hasUnread")
    func s07() async throws {
        var rig = Rig()
        let r = rig.addRoom(encrypted: true, mode: .mentionsAndKeywords)
        for _ in 0..<3 { rig.send(r) }
        rig.sync()
        let state = await rig.state(r)
        #expect(!state.attention && state.hasUnread && state.reasons.contains(.serverBlind))
        #expect(await rig.attention().isEmpty)
    }

    @Test("S07b: unencrypted room in mentions-only mode: quiet unread, and viewing sends a receipt for the 3rd message")
    func s07b() async throws {
        var rig = Rig()
        let r = rig.addRoom(mode: .mentionsAndKeywords)
        let ids = (0..<3).map { _ in rig.send(r) }
        rig.sync()
        let before = await rig.state(r)
        #expect(!before.attention && before.hasUnread && before.reasons.contains(.serverZero))
        #expect(await rig.receipts.readPosition(of: r) == nil)  // server zero must not advance the read position
        await rig.view(r, ids[2])
        await rig.settle()
        #expect(rig.port.receipts == [.init(room: r, event: ids[2], isPrivate: false)])
        rig.sync()
        #expect(!(await rig.state(r)).hasUnread)
    }

    @Test("S08: the only unread message is redacted: no attention")
    func s08() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let id = rig.send(r)
        rig.sync()
        #expect(await rig.attention() == [r])
        rig.world.redact(id)
        rig.sync()
        let state = await rig.state(r)
        #expect(!state.attention && !state.hasUnread)
    }

    @Test("S09: A2 marks the room unread: attention until A1 clears it")
    func s09() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let id = rig.send(r)
        rig.a2Reads(r, id)
        rig.markUnreadOnA2(r)
        rig.sync()
        #expect(await rig.attention() == [r])
        #expect(await rig.state(r).reasons.contains(.markedUnread))

        // Opening the room (the timeline view model calls `roomOpened` once it is visible) clears the flag.
        await rig.view(r, id)
        await rig.receipts.roomOpened(r)
        await rig.settle()
        #expect(rig.port.unreadFlags[r] == false)
        rig.sync()
        #expect(await rig.attention().isEmpty)

        // The room-list "Read" swipe clears it too.
        let other = rig.addRoom()
        let id2 = rig.send(other)
        rig.a2Reads(other, id2)
        rig.markUnreadOnA2(other)
        rig.sync()
        #expect(await rig.attention() == [other])
        rig.port.setLatestEvent(id2, in: other)
        try await rig.receipts.markRoomRead(other, latestEventTime: rig.world.ts(id2))
        await rig.settle()
        rig.sync()
        #expect(rig.port.unreadFlags[other] == false)
        #expect(await rig.attention().isEmpty)
    }

    @Test("S10: A2 mutes a room that has unread messages: A1's attention is gone after the sync")
    func s10() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        for _ in 0..<3 { rig.send(r) }
        rig.sync()
        #expect(await rig.attention() == [r])
        rig.setModeOnA2(r, .mute)
        rig.sync()
        #expect(await rig.attention().isEmpty)
    }

    @Test("S11: network down while viewing, then a restart, then the network returns")
    func s11() async throws {
        var rig = Rig(hangingBackoff: true)
        let store = rig.store
        let r = rig.addRoom()
        let ids = (0..<3).map { _ in rig.send(r) }
        rig.sync()
        rig.port.failNextReceipts(with: Array(repeating: .network(retryable: true), count: 100))
        await rig.view(r, ids[2])
        await rig.receipts.flush()
        #expect(rig.port.receipts.isEmpty)
        #expect(await rig.attention().isEmpty)  // cleared at once, from the local intent
        #expect(await eventually { store.intents.first?.event == ids[2] })

        await rig.relaunch()  // the app is killed and started again, still offline
        await rig.receipts.flush()
        #expect(rig.port.receipts.isEmpty)
        #expect(await rig.attention().isEmpty)  // the intent survived the restart

        rig.port.failNextReceipts(with: [])  // the network returns
        await rig.settle()
        #expect(rig.port.receipts == [.init(room: r, event: ids[2], isPrivate: false)])
        #expect(await eventually { store.intents.first?.isSent == true })
    }

    @Test("S12: the receipt fails three times: the intent stays pending, there is no attention, retries back off")
    func s12() async throws {
        var rig = Rig(hangingBackoff: true)
        let store = rig.store
        let r = rig.addRoom()
        let id = rig.send(r)
        rig.sync()
        rig.port.failNextReceipts(with: Array(repeating: .network(retryable: true), count: 3))
        await rig.view(r, id)
        for _ in 0..<3 {
            await rig.receipts.flush()
            #expect(rig.port.receipts.isEmpty)
            #expect(rig.store.intents.first?.isSent != true)
            #expect(await rig.attention().isEmpty)
        }
        await rig.receipts.flush()
        #expect(rig.port.receipts.count == 1)
        #expect(await eventually { store.intents.first?.isSent == true })

        // With real waits between attempts, the delays double: 1 s, 2 s, 4 s.
        var timed = Rig()
        let timedPort = timed.port
        let r2 = timed.addRoom()
        let id2 = timed.send(r2)
        timed.port.failNextReceipts(with: Array(repeating: .network(retryable: true), count: 3))
        await timed.view(r2, id2)
        #expect(await eventually { timedPort.receipts.count == 1 })
        let waits = timed.clock.sleeps.withLock { $0 }
        #expect(waits.filter { $0 >= .seconds(1) }.prefix(3) == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test("S13: A1 sends a message in a room with unread messages: attention cleared (E1b) although the server still counts; the receipt follows (FR-6)")
    func s13() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        for _ in 0..<2 { rig.send(r) }
        rig.sync()
        #expect(await rig.attention() == [r])
        let mine = rig.send(r, .a)
        rig.sync()
        // [VERIFIED against Synapse 1.165] sending does not reset the server's counts; E1b is what clears the badge.
        #expect(rig.world.input(r).counts.server.notification == 2)
        let state = await rig.state(r)
        #expect(!state.attention && state.reasons.contains(.ownLatest))
        // The timeline then reports the own message as seen, which sends a receipt and zeroes the server counts.
        await rig.view(r, mine)
        await rig.settle()
        rig.sync()
        #expect(rig.world.input(r).counts.server == .zero)
        #expect(await rig.attention().isEmpty)
    }

    @Test("S14: thread replies after the root was read: attention until the replies are viewed; the root's receipt isn't enough")
    func s14() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let root = rig.send(r)
        await rig.view(r, root)
        await rig.settle()
        rig.sync()
        #expect(await rig.attention().isEmpty)
        rig.send(r)  // thread reply
        let reply = rig.send(r)  // thread reply
        rig.sync()
        #expect(await rig.attention() == [r])
        await rig.view(r, reply)  // viewed inline, unthreaded receipt
        await rig.settle()
        rig.sync()
        #expect(await rig.attention().isEmpty)
        #expect(rig.port.receipts.last?.event == reply)
    }

    @Test("S15: B edits an old message: no new attention and no push record")
    func s15() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let ids = (0..<2).map { _ in rig.send(r) }
        await rig.view(r, ids[1])
        await rig.settle()
        rig.sync()
        let edit = rig.send(r, kind: .edit)  // edits don't notify (push rule .m.rule.suppress_edits)
        #expect(!rig.push(edit))
        rig.sync()
        #expect(await rig.attention().isEmpty)
        #expect(rig.records.all().isEmpty)
    }

    @Test("S16: a push for the same event delivered twice leaves one record and one badge unit")
    func s16() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let id = rig.send(r)
        #expect(rig.push(id))
        #expect(!rig.push(id))
        #expect(rig.records.all().count == 1)
        #expect(await rig.attention() == [r])
    }

    @Test("S17: A1 in the background, A2 reads, the room list updates: the badge drops (delivered notifications: SystemBadge, not modelled)")
    func s17() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let id = rig.send(r)
        rig.push(id)
        let port = FakeRoomListPort()
        let list = RoomListCoordinator(port: port)
        let badgePort = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: list, records: rig.records, port: badgePort, receipts: rig.receipts)
        await badge.begin()
        await list.start()
        try port.emit(.reset([rig.world.summary(r)]))
        #expect(await eventually { badgePort.badge == 1 })
        rig.a2Reads(r, id)
        rig.sync()
        try port.emit(.set(index: 0, rig.world.summary(r)))
        #expect(await eventually { badgePort.history.last == [] })
    }

    @Test("S18: B's clock is 10 minutes behind: viewing the latest event leaves no phantom unread; a late skewed message shows once the receipt is applied")
    func s18() async throws {
        var rig = Rig()
        let r = rig.addRoom()
        let skewed = rig.send(r, skew: -600)
        rig.sync()
        #expect(await rig.attention() == [r])
        await rig.view(r, skewed)
        await rig.settle()
        rig.sync()
        #expect(await rig.attention().isEmpty)

        // A new message stamped before the read position: "covers the latest event" by time, but the SDK has applied the
        // receipt and counts the message, so it shows (R-07). [LIMITATION] while the local position is ahead of the SDK's
        // receipt (not confirmed yet) the timestamp still decides (R-06).
        rig.send(r, skew: -2000)
        rig.sync()
        #expect(rig.world.input(r).counts.server.notification == 1)
        let state = await rig.state(r)
        #expect(state.attention && state.reasons.contains(.sdkUnreadAfterRead))
    }

    @Test("S19: 50 rooms change while the app reconciles: the final badge equals a fresh evaluation")
    func s19() async throws {
        var rig = Rig()
        var rng = SeededRandomNumberGenerator(seed: 19)
        let modes: [NotificationMode] = [.allMessages, .mentionsAndKeywords, .mute]
        let rooms = (0..<50).map { _ in rig.addRoom(encrypted: Bool.random(using: &rng), mode: modes.randomElement(using: &rng)!) }
        let port = FakeRoomListPort()
        let list = RoomListCoordinator(port: port)
        let badgePort = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: list, records: rig.records, port: badgePort, receipts: rig.receipts)
        await badge.begin()
        await list.start()
        try port.emit(.reset(rooms.map { rig.world.summary($0) }))
        for _ in 0..<300 {
            let i = Int.random(in: 0..<rooms.count, using: &rng), r = rooms[i]
            switch Int.random(in: 0..<6, using: &rng) {
            case 0, 1: rig.send(r, mention: Bool.random(using: &rng))
            case 2: if let last = rig.world.rooms[r]?.events.last { rig.a2Reads(r, last.id) }
            case 3: rig.markUnreadOnA2(r)
            case 4: rig.setModeOnA2(r, modes.randomElement(using: &rng)!)
            default: if let last = rig.world.rooms[r]?.events.last(where: { $0.sender != .a }) { await rig.view(r, last.id) }
            }
            if Bool.random(using: &rng) {
                rig.sync(r)
                try port.emit(.set(index: i, rig.world.summary(r)))
            }
        }
        rig.sync()
        for (i, r) in rooms.enumerated() { try port.emit(.set(index: i, rig.world.summary(r))) }
        let expected = await rig.attention()
        #expect(await eventually { badgePort.history.last == expected })
    }

    @Test("S20: the app dies before the receipt went out: after relaunch the outbox sends it and A2 sees the room read")
    func s20() async throws {
        var rig = Rig(hangingBackoff: true)
        let store = rig.store
        let r = rig.addRoom()
        let id = rig.send(r)
        rig.sync()
        rig.port.failNextReceipts(with: Array(repeating: .network(retryable: true), count: 100))
        await rig.view(r, id)
        await rig.receipts.flush()
        #expect(rig.port.receipts.isEmpty)
        #expect(await eventually { store.intents.count == 1 })
        #expect(rig.store.intents.first?.isSent == false)
        #expect(rig.world.rooms[r]?.receipt == nil)  // A2 still sees the room unread

        rig.port.failNextReceipts(with: [])  // the network is back for the relaunched app
        await rig.relaunch()
        await rig.settle()
        #expect(rig.port.receipts == [.init(room: r, event: id, isPrivate: false)])
        #expect(rig.world.rooms[r]?.receipt == 0)  // the server now has the receipt
    }

    @Test("S21: encrypted room, mentions-only, B mentions A: a mention shows although server counts stay 0; cleared by A1 or by A2's receipt")
    func s21() async throws {
        var viaA1 = Rig()
        let r = viaA1.addRoom(encrypted: true, mode: .mentionsAndKeywords)
        let id = viaA1.send(r, mention: true)
        viaA1.sync()
        var state = await viaA1.state(r)
        #expect(state.attention && state.display == .mentions(1) && state.reasons.contains(.serverBlind))
        #expect(viaA1.world.input(r).counts.server == .zero)
        await viaA1.view(r, id)
        #expect(await viaA1.attention().isEmpty)

        var viaA2 = Rig()
        let r2 = viaA2.addRoom(encrypted: true, mode: .mentionsAndKeywords)
        let id2 = viaA2.send(r2, mention: true)
        viaA2.a2Reads(r2, id2)
        viaA2.sync(applyOwnReceipt: false)  // the SDK hasn't applied A2's receipt yet
        state = await viaA2.state(r2)
        #expect(state.attention && state.reasons.contains(.serverBlind))
        viaA2.sync()
        #expect(await viaA2.attention().isEmpty)
    }

    @Test("S22: encrypted mentions-only room, a mention left in a timeline gap: attention only with the push; without it a documented blind spot")
    func s22() async throws {
        func scenario() -> (Rig, RoomID, EventID) {
            var rig = Rig()
            let r = rig.addRoom(encrypted: true, mode: .mentionsAndKeywords)
            var mention: EventID!
            for i in 0..<30 { let id = rig.send(r, mention: i == 10); if i == 10 { mention = id } }
            return (rig, r, mention)
        }

        // (a) the push for the mention reached A1
        var (a, ra, mentionA) = scenario()
        a.push(mentionA)
        var state = await a.state(ra)
        #expect(state.attention && state.display == .mentions(1))  // before the sync
        a.sync(limit: 5)
        state = await a.state(ra)
        #expect(state.attention && state.display == .mentions(1))  // after the limited sync
        await a.view(ra, a.world.rooms[ra]!.events.last!.id)
        #expect(await a.attention().isEmpty)

        // (b) no pusher: [LIMITATION] the mention is invisible until the SDK sees it
        var (b, rb, _) = scenario()
        b.sync(limit: 5)
        state = await b.state(rb)
        #expect(!state.attention && state.hasUnread && state.reasons.contains(.serverBlind))
        b.sync()  // the room was opened and the timeline paged back
        state = await b.state(rb)
        #expect(state.attention && state.display == .mentions(1))
    }

    @Test("S23: encrypted room with no read position yet (joined, never opened), B votes in a poll: no attention; a message after it shows; viewing clears (R-01)")
    func s23() async throws {
        var rig = Rig()
        let r = rig.addRoom(encrypted: true, mode: .allMessages)
        let vote = rig.send(r, kind: .vote)  // an encrypted non-message: the server counts it, the SDK doesn't
        #expect(!rig.push(vote))  // the extension decrypts a vote and has nothing to show or record
        rig.sync()
        #expect(rig.world.input(r).counts.server.notification == 1)
        var state = await rig.state(r)
        #expect(!state.attention && !state.hasUnread && state.display == .none && state.reasons == [.encServerOnly])
        #expect(await rig.attention().isEmpty)

        // A real message after the vote: attention. The server still counts the vote, so the number is approximate (a dot).
        let message = rig.send(r)
        rig.sync()
        state = await rig.state(r)
        #expect(state.attention && state.display == .dot && state.reasons == [.sdkCounts, .encServerOvercount])
        await rig.view(r, message)
        await rig.settle()
        rig.sync()
        #expect(await rig.attention().isEmpty)
        #expect(rig.world.input(r).counts.server == .zero)  // the receipt is after the vote
    }

    @Test("S24: A1 read the room, then B sends a message A1 can't decrypt yet: attention although the latest event is still the read one; also after A's own message (R-07)")
    func s24() async throws {
        // (a) after a receipt: the SDK applied it and counts the undecryptable event; its latest event leaves it out.
        var rig = Rig()
        let r = rig.addRoom(encrypted: true, mode: .allMessages)
        let seen = rig.send(r)
        rig.sync()
        await rig.view(r, seen)
        await rig.settle()
        rig.sync()
        #expect(await rig.attention().isEmpty)
        let hidden = rig.send(r)
        rig.sync(undecrypted: [hidden])
        #expect(rig.world.input(r).latestEvent?.timestamp == rig.world.ts(seen))  // still the read event
        var state = await rig.state(r)
        #expect(state.attention && state.display == .count(1) && state.reasons == [.sdkUnreadAfterRead, .sdkCounts])
        #expect(await rig.attention() == [r])
        rig.sync()  // the keys arrive: the latest event is the new message, nothing covers it
        await rig.view(r, hidden)
        await rig.settle()
        rig.sync()
        #expect(await rig.attention().isEmpty)

        // (b) after A's own message: the SDK takes it as a receipt and counts what came after.
        var own = Rig()
        let r2 = own.addRoom(encrypted: true, mode: .allMessages)
        own.send(r2, .a)
        let after = own.send(r2)
        own.sync(undecrypted: [after])
        state = await own.state(r2)
        #expect(state.attention && state.display == .count(1) && state.reasons == [.sdkUnreadAfterRead, .sdkCounts])

        // (c) a local read position ahead of the SDK's receipt (not sent yet): the SDK's count is stale, the room reads as read.
        var ahead = Rig(hangingBackoff: true)
        let r3 = ahead.addRoom(encrypted: true, mode: .allMessages)
        let m = ahead.send(r3)
        ahead.sync()
        await ahead.view(r3, m)  // reported here, not yet on the server
        state = await ahead.state(r3)
        #expect(!state.attention && state.reasons == [.intentCovers])
    }

    @Test("S25: encrypted DM, UTD push stamped with event ts, sync delivers and decrypts, A reads on A2: no attention and record pruned without opening (R-02)")
    func s25() async throws {
        var rig = Rig()
        let r = rig.addRoom(encrypted: true, mode: .allMessages)
        let id = rig.send(r)
        // NSE couldn't decrypt the push, but stamped the record with the raw event's origin_server_ts (not Date()).
        rig.records.add(NotificationRecord(roomID: r, eventID: id, timestamp: rig.world.ts(id), isMention: false))
        let port = FakeRoomListPort()
        let list = RoomListCoordinator(port: port)
        let badgePort = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: list, records: rig.records, port: badgePort, receipts: rig.receipts)
        await badge.begin()
        await list.start()
        try port.emit(.reset([rig.world.summary(r)]))
        #expect(await eventually { badgePort.badge == 1 })

        // Sync delivers and decrypts the event (still unread → attention from SDK counts, record superseded and pruned).
        let records = rig.records
        rig.sync()
        try port.emit(.reset([rig.world.summary(r)]))
        #expect(await eventually { records.all().isEmpty })
        #expect(badgePort.badge == 1)

        // A reads on A2 and A1 syncs: attention drops to 0 without opening the room on A1.
        rig.a2Reads(r, id)
        rig.sync()
        try port.emit(.reset([rig.world.summary(r)]))
        #expect(await eventually { badgePort.history.last == [] })
        #expect(rig.records.all().isEmpty)
    }

    @Test("S26: room with a notification record is left on A2 while A1 is closed; A1 syncs and badge excludes it (R-03)")
    func s26() async throws {
        let port = FakeRoomListPort()
        let list = RoomListCoordinator(port: port)
        let records = FakeNotificationRecords()
        let badgePort = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: list, records: records, port: badgePort)
        let left = try RoomID("!left:x.org")
        records.add(NotificationRecord(roomID: left, eventID: try EventID("$e1"), timestamp: Date(timeIntervalSince1970: 100), isMention: false))
        await badge.begin()
        await list.start()
        try port.emit(.reset([]))
        #expect(await eventually { badgePort.history.last == [left] })

        // Sync delivers `rooms.left` containing the room left on A2.
        port.emitLeft([left])
        #expect(await eventually { badgePort.history.last == [] && records.all().isEmpty })
    }

    @Test("S27: sign out account X (records exist), sign in account Y: Y's badge has no X rooms (R-03)")
    func s27() async throws {
        let port = FakeRoomListPort()
        let list = RoomListCoordinator(port: port)
        let recordsX = FakeNotificationRecords()
        let recordsY = FakeNotificationRecords()
        let badgePort = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: list, records: recordsX, port: badgePort)
        let roomX = try RoomID("!x:x.org")
        recordsX.add(NotificationRecord(roomID: roomX, eventID: try EventID("$x1"), timestamp: Date(timeIntervalSince1970: 100), isMention: false))
        await badge.begin()
        await list.start()
        try port.emit(.reset([]))
        #expect(await eventually { badgePort.history.last == [roomX] })

        // Account X signs out, account Y signs in with its own record store.
        await badge.reset()
        await badge.attach(records: recordsY)
        try port.emit(.reset([]))
        #expect(recordsX.all().isEmpty)
        #expect(await eventually { badgePort.history.last == [] })
        #expect(await badge.attentionRooms.isEmpty)
    }

    @Test("S28: carried attention and stale records for a room left while closed are dropped after the first sync response (R-04, R-03)")
    func s28() async throws {
        let port = FakeRoomListPort()
        let list = RoomListCoordinator(port: port)
        let records = FakeNotificationRecords()
        let badgePort = FakeBadgePort()
        let gone = try RoomID("!gone:x.org")
        let stayed = try RoomID("!stayed:x.org")
        badgePort.preload([gone])
        records.add(NotificationRecord(roomID: gone, eventID: try EventID("$g1"), timestamp: Date(timeIntervalSince1970: 100), isMention: false))
        let badge = BadgeCoordinator(rooms: list, records: records, port: badgePort)
        await badge.begin()
        await list.start()
        try port.emit(.reset([RoomSummary(id: stayed, name: "stayed", isDirect: true, isEncrypted: false, membership: .joined)]))
        #expect(await eventually { badgePort.history.last == [gone] })

        // First sync response completes; the server no longer lists `gone` as joined/invited (and didn't even need to send rooms.left).
        port.emitSyncComplete(present: [stayed])
        #expect(await eventually { badgePort.history.last == [] && records.all().isEmpty })
    }

}
