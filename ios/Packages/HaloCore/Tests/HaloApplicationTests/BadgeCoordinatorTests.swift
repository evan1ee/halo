import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("BadgeCoordinator")
struct BadgeCoordinatorTests {
    private func summary(_ id: String, notify: Int = 0, mode: NotificationMode = .allMessages, membership: Membership = .joined) throws -> RoomSummary {
        RoomSummary(
            id: try RoomID(id), name: id, isDirect: false, isEncrypted: false, membership: membership,
            read: RoomReadCounts(mode: mode, server: ServerCounts(notification: notify, highlight: 0), sdk: .zero, isMarkedUnread: false))
    }

    private func record(_ room: String, _ event: String) throws -> NotificationRecord {
        NotificationRecord(roomID: try RoomID(room), eventID: try EventID(event), timestamp: Date(), isMention: false)
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<500_000 { if await condition() { return true }; await Task.yield() }
        return false
    }

    private func make() async -> (FakeRoomListPort, RoomListCoordinator, FakeNotificationRecords, FakeBadgePort, BadgeCoordinator) {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let records = FakeNotificationRecords()
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, records: records, port: port)
        await badge.begin()
        await coordinator.start()
        return (rooms, coordinator, records, port, badge)
    }

    @Test("D82: the badge sums unread messages across rooms needing attention and is recomputed, not counted up or down")
    func follows() async throws {
        let (rooms, _, _, port, badge) = await make()
        try rooms.emit(.reset([try summary("!a:x.org", notify: 2), try summary("!b:x.org"), try summary("!c:x.org", notify: 1, mode: .mute)]))
        #expect(await eventually { port.badge == 2 })
        try rooms.emit(.set(index: 1, try summary("!b:x.org", notify: 4)))
        #expect(await eventually { port.badge == 6 })
        try rooms.emit(.set(index: 0, try summary("!a:x.org")))
        #expect(await eventually { port.badge == 4 })
        #expect(port.history.last == [try RoomID("!b:x.org")])
        #expect(await badge.badge == 4)
    }

    @Test("a notification record makes a room count although the room list shows no unread, and clearing it updates the badge (D82)")
    func recordsCount() async throws {
        let (rooms, _, records, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org"), try summary("!b:x.org")]))
        #expect(await eventually { !port.history.isEmpty })
        #expect(port.badge == 0)
        records.add(try record("!a:x.org", "$1"))  // written by the extension
        #expect(await eventually { port.badge == 1 })
        records.add(try record("!a:x.org", "$2"))  // a second unread message in room a
        records.add(try record("!b:x.org", "$3"))  // plus 1 in room b = 3 total unread messages
        #expect(await eventually { port.badge == 3 })
        records.clear(room: try RoomID("!a:x.org"))  // the user cleared room a
        #expect(await eventually { port.badge == 1 })
    }

    @Test("a record for a room that isn't in the loaded list still counts")
    func unknownRoom() async throws {
        let (rooms, _, records, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org")]))
        #expect(await eventually { !port.history.isEmpty })
        records.add(try record("!elsewhere:x.org", "$9"))
        #expect(await eventually { port.badge == 1 })
    }

    @Test("the first evaluation writes even an empty set, so a stale badge is cleared")
    func firstWriteClears() async throws {
        let (rooms, _, _, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org")]))
        #expect(await eventually { !port.history.isEmpty })
        #expect(port.history == [[]])
    }

    @Test("R-15 (D6): opening a timeline keeps records until a message is seen; reporting a read position clears only covered records")
    func openKeepsUntilSeen() async throws {
        let rooms = FakeRoomListPort()
        let roomList = RoomListCoordinator(port: rooms)
        let records = FakeNotificationRecords()
        let markers = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: markers)
        let port = FakeBadgePort()
        let coordinator = ReadStateCoordinator(rooms: roomList, records: records, port: port, receipts: receipts)
        defer { withExtendedLifetime(coordinator) {} }
        await coordinator.begin()
        await roomList.start()

        let room = try RoomID("!a:x.org")
        let timelines = FakeTimelinePort()
        timelines.addRoom(room)
        try rooms.emit(.reset([try summary("!a:x.org"), try summary("!b:x.org")]))
        records.add(NotificationRecord(roomID: room, eventID: try EventID("$1"), timestamp: Date(timeIntervalSince1970: 100), isMention: false, deliveredAt: Date(timeIntervalSince1970: 100), source: .nse))
        records.add(NotificationRecord(roomID: room, eventID: try EventID("$3"), timestamp: Date(timeIntervalSince1970: 200), isMention: false, deliveredAt: Date(timeIntervalSince1970: 200), source: .nse))
        records.add(try record("!b:x.org", "$2"))
        #expect(await eventually { port.badge == 3 })

        // Opening the room alone does NOT wipe its notification records before anything is seen (D6, R-15).
        await TimelineCoordinator(port: timelines, room: room).open()
        #expect(Set(records.all().map(\.eventID.rawValue)) == ["$1", "$2", "$3"])

        // Seeing $1 (ts 100) clears only $1; unseen newer record $3 (ts 200) and other room's $2 stay (badge 3 → 2).
        await receipts.reportSeen(room: room, event: try EventID("$1"), timestamp: Date(timeIntervalSince1970: 100))
        #expect(await eventually { !records.all().contains { $0.eventID.rawValue == "$1" } })
        #expect(Set(records.all().map(\.eventID.rawValue)) == ["$2", "$3"])
        #expect(await eventually { port.badge == 2 })

        // Seeing $3 (ts 200) clears $3 and drops room !a from the badge (badge 2 → 1).
        await receipts.reportSeen(room: room, event: try EventID("$3"), timestamp: Date(timeIntervalSince1970: 200))
        #expect(await eventually { port.badge == 1 })
        #expect(records.all().map(\.eventID.rawValue) == ["$2"])
    }

    @Test("reading a room here clears its attention at once, before the server confirms; a newer event brings it back")
    func localIntentClears() async throws {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let markers = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: markers)
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, records: FakeNotificationRecords(), port: port, receipts: receipts)
        await badge.begin()
        await coordinator.start()
        func unread(latest: Double) throws -> RoomSummary {
            RoomSummary(
                id: try RoomID("!a:x.org"), name: "a", isDirect: false, isEncrypted: false, membership: .joined,
                read: RoomReadCounts(mode: .allMessages, server: ServerCounts(notification: 3, highlight: 0), sdk: .zero, isMarkedUnread: false),
                latestEvent: LatestEventRef(timestamp: Date(timeIntervalSince1970: latest), senderIsSelf: false))
        }
        try rooms.emit(.reset([try unread(latest: 100)]))
        #expect(await eventually { port.badge == 3 })

        await receipts.reportSeen(room: try RoomID("!a:x.org"), event: try EventID("$e"), timestamp: Date(timeIntervalSince1970: 100))
        #expect(await eventually { port.badge == 0 })

        try rooms.emit(.set(index: 0, try unread(latest: 200)))
        #expect(await eventually { port.badge == 3 })
    }

    @Test("a receipt your other device sent clears the room here, until a newer event arrives")
    func readElsewhereClears() async throws {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, records: FakeNotificationRecords(), port: port)
        await badge.begin()
        await coordinator.start()
        func room(latest: Double, readThrough: Double?) throws -> RoomSummary {
            RoomSummary(
                id: try RoomID("!a:x.org"), name: "a", isDirect: false, isEncrypted: false, membership: .joined,
                read: RoomReadCounts(mode: .allMessages, server: ServerCounts(notification: 3, highlight: 0), sdk: .zero, isMarkedUnread: false),
                latestEvent: LatestEventRef(timestamp: Date(timeIntervalSince1970: latest), senderIsSelf: false),
                ownReadThrough: readThrough.map { Date(timeIntervalSince1970: $0) })
        }
        try rooms.emit(.reset([try room(latest: 100, readThrough: nil)]))
        #expect(await eventually { port.badge == 3 })
        try rooms.emit(.set(index: 0, try room(latest: 100, readThrough: 100)))
        #expect(await eventually { port.badge == 0 })
        try rooms.emit(.set(index: 0, try room(latest: 200, readThrough: 100)))
        #expect(await eventually { port.badge == 3 })
    }

    @Test("a pushed event the user already read doesn't count, a newer one does")
    func recordsAreReadThrough() throws {
        let id = try RoomID("!a:x.org")
        let input = RoomReadInputs(roomID: id, membership: .joined, isEncrypted: true, counts: .none)
        func record(_ t: Double) throws -> NotificationRecord {
            NotificationRecord(roomID: id, eventID: try EventID("$e\(Int(t))"), timestamp: Date(timeIntervalSince1970: t), isMention: false)
        }
        let read = [id: Date(timeIntervalSince1970: 100)]
        #expect(BadgeCoordinator.attention(inputs: [input], records: [try record(100)], positions: read).isEmpty)
        #expect(BadgeCoordinator.attention(inputs: [input], records: [try record(100), try record(150)], positions: read) == [id])
        #expect(BadgeCoordinator.attention(inputs: [input], records: [try record(100)]) == [id])
    }

    /// P7 (UNREAD_REGRESSION_TESTS §2): the app and the extension share records through storage; the badge computed from
    /// records after an encode/decode round trip, in any stored order, equals the one from the originals and is the size of the attention set.
    @Test("P7: the badge is identical after the records are serialised, and equals the number of attention rooms")
    func p7() throws {
        var rng = SeededRandomNumberGenerator(seed: 77)
        let modes: [NotificationMode] = [.allMessages, .mentionsAndKeywords, .mute]
        for n in 0..<300 {
            let inputs = try (0..<6).map { i -> RoomReadInputs in
                let s = try summary("!r\(i):x.org", notify: Int.random(in: 0...2, using: &rng), mode: modes.randomElement(using: &rng)!)
                return RoomReadInputs(
                    roomID: s.id, membership: s.membership, isEncrypted: false, counts: s.read,
                    localIntent: Bool.random(using: &rng) ? Date(timeIntervalSince1970: Double(Int.random(in: 0...100, using: &rng))) : nil)
            }
            let records = try (0..<Int.random(in: 0...8, using: &rng)).map { k in
                NotificationRecord(
                    roomID: try RoomID("!r\(Int.random(in: 0...7, using: &rng)):x.org"), eventID: try EventID("$e\(k)"),
                    timestamp: Date(timeIntervalSince1970: Double(Int.random(in: 0...100, using: &rng))), isMention: Bool.random(using: &rng))
            }
            let stored = try JSONDecoder().decode([NotificationRecord].self, from: JSONEncoder().encode(records.shuffled(using: &rng)))
            let direct = BadgeCoordinator.attention(inputs: inputs, records: records)
            #expect(direct == BadgeCoordinator.attention(inputs: inputs, records: stored), "seed 77 case \(n)")
            #expect(direct.count == BadgeCoordinator.attention(inputs: inputs, records: stored).count, "seed 77 case \(n)")
        }
    }

    @Test("the auditor stores a finding once while it lasts, again after it went away, with a hashed room and counts only")
    func auditor() async throws {
        let (rooms, _, _, _, badge) = await make()
        let store = FakeAuditEvents()
        await badge.setAudit(.init(port: store, roomHash: { _ in "!abc123" }, appVersion: "1.0", now: { Date(timeIntervalSince1970: 100) }))
        func stale(_ sdk: Int) throws -> RoomSummary {
            RoomSummary(
                id: try RoomID("!a:x.org"), name: "a", isDirect: false, isEncrypted: false, membership: .joined,
                read: RoomReadCounts(mode: .allMessages, server: .zero, sdk: SDKCounts(unreadMessages: sdk, unreadNotifications: sdk, unreadMentions: 0), isMarkedUnread: false))
        }
        try rooms.emit(.reset([try stale(2)]))
        #expect(await eventually { store.events.count == 1 })
        func settle() async { for _ in 0..<100_000 { await Task.yield() } }
        await settle()
        try rooms.emit(.reset([try stale(3)]))  // same finding, still there: not written again
        await settle()
        try rooms.emit(.reset([try stale(0)]))  // gone
        await settle()
        try rooms.emit(.reset([try stale(1)]))  // back: written again
        #expect(await eventually { store.events.count == 2 })
        let event = try #require(store.events.first)
        #expect(event.finding == AuditFinding(kind: .explained, reason: "SDK_STALE_PENDING_RECEIPT"))
        #expect(event.roomHash == "!abc123" && event.appVersion == "1.0" && !event.inputsJSON.contains("x.org"))
        #expect(try await store.unexplainedCount() == 0)
    }

    private func started(preloaded: Set<String>) async throws -> (FakeRoomListPort, FakeBadgePort, BadgeCoordinator) {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        port.preload(Set(try preloaded.map { try RoomID($0) }))
        let badge = BadgeCoordinator(rooms: coordinator, records: FakeNotificationRecords(), port: port)
        await badge.begin()
        await coordinator.start()
        return (rooms, port, badge)
    }

    @Test("an empty or partial first evaluation never erases the stored attention (P0): rooms not shown yet keep their state")
    func partialEvaluationKeepsStoredAttention() async throws {
        let (rooms, port, badge) = try await started(preloaded: ["!a:x.org", "!b:x.org"])
        // The list is empty at launch: nothing is written that is smaller than what is stored.
        try rooms.emit(.reset([]))
        #expect(await eventually { !port.history.isEmpty && port.history.count >= 2 })
        #expect(port.history.allSatisfy { $0.count == 2 })
        // Only room A has loaded, as the local replica of the last run knows it: that proves nothing yet (E6).
        try rooms.emit(.reset([try summary("!a:x.org")]))
        #expect(await eventually { !(await badge.roomStates).isEmpty })
        #expect(await badge.badge == 2)
        #expect(await badge.roomStates[try RoomID("!a:x.org")]?.display == .count(1))  // the list agrees with the icon
        // The first sync response confirms A is read: it drops; B (not shown yet) stays.
        rooms.emitSyncComplete(present: [try RoomID("!a:x.org"), try RoomID("!b:x.org")])
        #expect(await eventually { port.badge == 1 })
        #expect(await badge.attentionRooms == [try RoomID("!b:x.org")])
        // B loads and is read: now it drops too.
        try rooms.emit(.reset([try summary("!a:x.org"), try summary("!b:x.org")]))
        #expect(await eventually { port.badge == 0 })
        #expect(port.countsHistory.allSatisfy { $0.values.allSatisfy { $0 == 1 } })
    }

    @Test("a room that was shown and then leaves the list is dropped, not carried; reset clears the stored set explicitly")
    func shownThenGone() async throws {
        let (rooms, port, badge) = try await started(preloaded: [])
        try rooms.emit(.reset([try summary("!a:x.org", notify: 1), try summary("!b:x.org", notify: 1)]))
        #expect(await eventually { port.badge == 2 })
        try rooms.emit(.reset([try summary("!b:x.org", notify: 1)]))
        #expect(await eventually { port.badge == 1 })
        await badge.reset()
        #expect(port.badge == 0 && port.history.last == [])
        #expect(await port.lastAttention().isEmpty)
    }

    @Test("reconcile forces a fresh badge write without losing carried-over rooms (ROOM_LIST FR-8, D73)")
    func manualReconcile() async throws {
        let (_, port, badge) = try await started(preloaded: ["!a:x.org"])
        let before = port.history.count
        await badge.reconcile()
        #expect(port.history.count == before + 1)
        #expect(port.history.last == [try RoomID("!a:x.org")])
        #expect(await badge.attentionRooms == [try RoomID("!a:x.org")])
    }

    @Test("the periodic auditor runs only in the foreground with an audit attached and stops on background (LOGGING_AND_DIAGNOSTICS §2)")
    func periodicForegroundAudit() async throws {
        #expect(BadgeCoordinator.defaultAuditInterval == .seconds(600))
        actor Ticker {
            var calls: [Duration] = []
            var waiting: CheckedContinuation<Void, Error>?
            func wait(_ duration: Duration) async throws {
                calls.append(duration)
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { waiting = $0 }
                } onCancel: {
                    Task { await self.cancel() }
                }
            }
            func tick() { waiting?.resume(); waiting = nil }
            func cancel() { waiting?.resume(throwing: CancellationError()); waiting = nil }
        }
        let ticker = Ticker()
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let records = FakeNotificationRecords()
        let badge = BadgeCoordinator(rooms: coordinator, records: records, port: FakeBadgePort(), auditInterval: .seconds(600), sleep: { try await ticker.wait($0) })
        await badge.begin()
        await coordinator.start()

        // Without an audit attached, going foreground starts no timer.
        await badge.setForeground(true)
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await ticker.calls.isEmpty)

        // Attaching an audit while foregrounded starts the 10-minute cadence.
        let store = FakeAuditEvents()
        await badge.setAudit(.init(port: store, roomHash: { _ in "!h" }, appVersion: "1.0", now: { Date(timeIntervalSince1970: 100) }))
        for _ in 0..<200_000 where await ticker.calls != [.seconds(600)] { await Task.yield() }
        #expect(await ticker.calls == [.seconds(600)])
        // Put a stale room in place, tick once, verify the periodic pass ran and scheduled the next tick.
        try rooms.emit(.reset([RoomSummary(
            id: try RoomID("!a:x.org"), name: "a", isDirect: false, isEncrypted: false, membership: .joined,
            read: RoomReadCounts(mode: .allMessages, server: .zero, sdk: SDKCounts(unreadMessages: 2, unreadNotifications: 2, unreadMentions: 0), isMarkedUnread: false))]))
        #expect(await eventually { store.events.count == 1 })
        await ticker.tick()
        for _ in 0..<200_000 where await ticker.calls.count < 2 { await Task.yield() }
        #expect(await ticker.calls.count == 2)

        // Backgrounding cancels the periodic task; no further ticks occur.
        await badge.setForeground(false)
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await ticker.calls.count == 2)
    }

    @Test("R-02: notification records superseded by sync or covered by serverZero are pruned and never leave a ghost badge")
    func supersededRecordsPruned() async throws {
        let (rooms, _, records, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        let r = try RoomID("!a:x.org")
        let ts = Date(timeIntervalSince1970: 1_000)
        // Push arrives before sync (e.g. UTD push stamped with event origin_server_ts).
        records.add(NotificationRecord(roomID: r, eventID: try EventID("$utd"), timestamp: ts, isMention: false))
        try rooms.emit(.reset([RoomSummary(id: r, name: "a", isDirect: true, isEncrypted: true, membership: .joined)]))
        #expect(await eventually { port.badge == 1 })

        // User reads on A2 and sync delivers the decrypted event (serverZero + latestEvent == ts, ownReadThrough nil).
        try rooms.emit(.reset([RoomSummary(
            id: r, name: "a", isDirect: true, isEncrypted: true, membership: .joined,
            read: .none, latestEvent: LatestEventRef(timestamp: ts, senderIsSelf: false))]))
        #expect(await eventually { port.badge == 0 && records.all().isEmpty })
    }

    @Test("R-03: records for left, hidden, ignored-inviter rooms and signed-out accounts are pruned and excluded from the badge")
    func recordsPrunedOnLeaveHideIgnoreAndReset() async throws {
        let rooms = FakeRoomListPort()
        let hidden = FakeHiddenRooms()
        let profiles = FakeProfilePort()
        let coordinator = RoomListCoordinator(port: rooms, hiddenRooms: hidden, profiles: profiles)
        let records = FakeNotificationRecords()
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, records: records, port: port)
        await badge.begin()
        await coordinator.start()

        let leftRoom = try RoomID("!left:x.org")
        let hiddenRoom = try RoomID("!pack:x.org")
        let ignoredRoom = try RoomID("!spam:x.org")
        let keepRoom = try RoomID("!keep:x.org")
        let spammer = try UserID("@spam:x.org")

        records.add(try record(leftRoom.rawValue, "$1"))
        records.add(try record(hiddenRoom.rawValue, "$2"))
        records.add(try record(ignoredRoom.rawValue, "$3"))
        records.add(try record(keepRoom.rawValue, "$4"))

        hidden.set([hiddenRoom])
        try await profiles.ignore(spammer)
        try rooms.emit(.reset([
            try summary(hiddenRoom.rawValue),
            RoomSummary(id: ignoredRoom, name: "Spam", isDirect: true, isEncrypted: false, membership: .invited, inviter: "Spam", inviterID: spammer),
            try summary(keepRoom.rawValue),
        ]))
        rooms.emitLeft([leftRoom])

        #expect(await eventually {
            port.history.last == [keepRoom] && Set(records.all().map(\.roomID)) == [keepRoom]
        })

        // forget(_:) clears records for a room the user leaves here.
        await badge.forget(keepRoom)
        #expect(records.all().isEmpty)
        #expect(await badge.badge == 0)

        // reset() clears all records on sign-out / account switch.
        records.add(try record("!old:x.org", "$9"))
        await badge.reset()
        #expect(records.all().isEmpty)
        #expect(port.badge == 0)
    }

    @Test("R-04 (PS26): carried attention for a room that never reappears is dropped after the first sync response")
    func carriedRoomDroppedAfterFirstSync() async throws {
        let gone = try RoomID("!gone:x.org")
        let alive = try RoomID("!alive:x.org")
        let pending = try RoomID("!pending:x.org")
        let (rooms, port, badge) = try await started(preloaded: [gone.rawValue, alive.rawValue, pending.rawValue])
        // Before the first sync response: a partial list keeps all carried rooms, also the one it shows as read (E6).
        try rooms.emit(.reset([try summary(alive.rawValue)]))
        #expect(await eventually { !(await badge.roomStates).isEmpty })
        #expect(await badge.attentionRooms == [gone, alive, pending])

        // First sync response completes: SDK reports only `alive` and `pending` as joined/invited (`gone` was left while closed).
        // `gone` is dropped immediately; `pending` stays carried (no flicker) until its diff arrives.
        rooms.emitSyncComplete(present: [alive, pending])
        #expect(await eventually { port.history.last == [pending] })
        #expect(await badge.attentionRooms == [pending])

        // Once `pending`'s summary arrives (read), it drops too.
        try rooms.emit(.reset([try summary(alive.rawValue), try summary(pending.rawValue)]))
        #expect(await eventually { port.history.last == [] })
    }

    @Test("reconcile before begin does not overwrite cached badge with zero")
    func reconcileBeforeBeginDoesNotOverwriteCachedBadge() async throws {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        let roomA = try RoomID("!a:x.org")
        await port.update(BadgeSnapshot(attentionCounts: [roomA: 3], evaluatedAt: Date()))
        let beforeWrites = port.history.count

        let badge = ReadStateCoordinator(rooms: coordinator, port: port)
        await badge.reconcile()

        #expect(port.history.count == beforeWrites)
        #expect(port.badge == 3)
    }

    @Test("reconcile re-asserts unchanged unread badge to the port so dropped OS badges heal")
    func reconcileReassertsUnchangedBadge() async throws {
        let (rooms, _, _, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org", notify: 3)]))
        #expect(await eventually { port.badge == 3 })
        let writesBefore = port.history.count

        await badge.reconcile()
        #expect(port.history.count == writesBefore + 1)
        #expect(port.badge == 3)
    }

    // MARK: One consistent count (icon, widgets, list)

    @Test("E6: opening the app never lowers what is shown before the first sync; reading the room in this run does at once")
    func openingNeverLowers() async throws {
        let a = try RoomID("!a:x.org")
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let receipts = ReadReceiptCoordinator(port: FakeReadMarkerPort())
        let port = FakeBadgePort()
        port.preload([a: 8])  // the extension counted 8 while the app was closed
        let badge = BadgeCoordinator(rooms: coordinator, records: FakeNotificationRecords(), port: port, receipts: receipts)
        await badge.begin()
        await coordinator.start()
        func room(notify: Int, latest: Double = 100) throws -> RoomSummary {
            RoomSummary(
                id: a, name: "a", isDirect: false, isEncrypted: false, membership: .joined,
                read: RoomReadCounts(mode: .allMessages, server: ServerCounts(notification: notify, highlight: 0), sdk: .zero, isMarkedUnread: false),
                latestEvent: LatestEventRef(timestamp: Date(timeIntervalSince1970: latest), senderIsSelf: false))
        }
        // The replica still says 3, as when the app was last open; the app is closed again before any sync.
        try rooms.emit(.reset([try room(notify: 3)]))
        #expect(await eventually { !(await badge.roomStates).isEmpty })
        await badge.reconcile()
        #expect(port.countsHistory.allSatisfy { $0 == [a: 8] })
        // Offline, the user opens the room and reads it: no sync is needed for that.
        await receipts.reportSeen(room: a, event: try EventID("$e"), timestamp: Date(timeIntervalSince1970: 100))
        #expect(await eventually { port.badge == 0 })
        // The first response brings a newer message: from here on only sync decides.
        try rooms.emit(.set(index: 0, try room(notify: 1, latest: 200)))
        rooms.emitSyncComplete()
        #expect(await eventually { port.badge == 1 })
    }

    @Test("writes land in evaluation order: a slow older write never overwrites a newer count")
    func writesAreOrdered() async throws {
        let (rooms, _, records, port, badge) = await make()
        let release = AsyncStream<Void>.makeStream()
        let held = Mutex(false)
        port.beforeWrite { counts in
            guard counts.isEmpty else { return }
            held.withLock { $0 = true }
            for await _ in release.stream { break }
        }
        try rooms.emit(.reset([try summary("!a:x.org")]))  // evaluates to 0; its write hangs
        #expect(await eventually { held.withLock { $0 } })
        for n in 1...3 { records.add(try record("!a:x.org", "$\(n)")) }  // pushes, on their own path
        #expect(await eventually { await badge.badge == 3 })
        #expect(port.countsHistory.isEmpty)  // not before the older one
        release.continuation.yield()
        #expect(await eventually { port.badge == 3 })
        #expect(port.countsHistory.first == [:])
    }

    @Test("every sync response writes the counts again, so a badge something else changed is corrected")
    func syncReasserts() async throws {
        let (rooms, _, _, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org", notify: 3)]))
        #expect(await eventually { port.badge == 3 })
        let before = port.history.count
        rooms.emitSyncComplete()
        #expect(await eventually { port.history.count == before + 1 })
        #expect(port.badge == 3)
    }

    @Test("a sync completion never arrives before the list changes of its response")
    func syncFollowsItsDiffs() async throws {
        let (rooms, coordinator, _, _, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        for n in 1...200 {
            try rooms.emit(.reset([try summary("!a:x.org", notify: n)]))
            rooms.emitSyncComplete()
        }
        for await snapshot in await coordinator.readSnapshots() {
            if snapshot.syncCount > 0 { #expect((snapshot.inputs.first?.counts.server.notification ?? 0) >= snapshot.syncCount) }
            if snapshot.syncCount == 200 { break }
        }
    }

    @Test("waitForSync returns only once the new counts have been written, and gives up at its limit")
    func waitForSync() async throws {
        let (rooms, _, _, port, badge) = await make()
        let epoch = await badge.syncEpoch
        let waiter = Task { (await badge.waitForSync(after: epoch, timeout: .seconds(60)), port.badge) }
        try rooms.emit(.reset([try summary("!a:x.org", notify: 4)]))
        rooms.emitSyncComplete()
        let (reached, shown) = await waiter.value
        #expect(reached && shown == 4)

        let impatient = BadgeCoordinator(rooms: RoomListCoordinator(port: FakeRoomListPort()), port: FakeBadgePort(), sleep: { _ in })
        await impatient.begin()
        #expect(await impatient.waitForSync(after: 0, timeout: .seconds(1)) == false)
    }

    @Test("records that can't be read right now (suspended or locked database) are unknown, not none")
    func unreadableRecords() async throws {
        final class Flaky: NotificationRecordPort {
            let inner = FakeNotificationRecords()
            let readable = Mutex(true)
            func all() -> [NotificationRecord] { load() ?? [] }
            func load() -> [NotificationRecord]? { readable.withLock { $0 } ? inner.all() : nil }
            func add(_ record: NotificationRecord) -> Bool { inner.add(record) }
            func clear(room: RoomID) { inner.clear(room: room) }
            func clear(rooms: Set<RoomID>) { inner.clear(rooms: rooms) }
            func remove(events: Set<EventID>) { inner.remove(events: events) }
            func clearAll() { inner.clearAll() }
            func changes() -> AsyncStream<Void> { inner.changes() }
        }
        let records = Flaky()
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, records: records, port: port)
        await badge.begin()
        await coordinator.start()
        try rooms.emit(.reset([try summary("!a:x.org")]))
        _ = records.add(try record("!a:x.org", "$1"))
        #expect(await eventually { port.badge == 1 })
        records.readable.withLock { $0 = false }
        await badge.reconcile()
        #expect(port.badge == 1)
    }

    @Test("the extension's baseline carries when the app evaluated and what sync has delivered per room")
    func snapshotForTheExtension() async throws {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        let at = Date(timeIntervalSince1970: 500)
        let badge = BadgeCoordinator(rooms: coordinator, port: port, now: { at })
        await badge.begin()
        await coordinator.start()
        let a = try RoomID("!a:x.org")
        try rooms.emit(.reset([RoomSummary(
            id: a, name: "a", isDirect: false, isEncrypted: false, membership: .joined,
            latestEvent: LatestEventRef(timestamp: Date(timeIntervalSince1970: 400), senderIsSelf: false))]))
        #expect(await eventually { port.snapshots.last?.syncedThrough == [a: Date(timeIntervalSince1970: 400)] || !port.snapshots.isEmpty })
        rooms.emitSyncComplete()
        #expect(await eventually { port.snapshots.last == BadgeSnapshot(attentionCounts: [:], evaluatedAt: at, syncedThrough: [a: Date(timeIntervalSince1970: 400)]) })
    }

    @Test("E6 ends with the first sync: a list that stops and resubscribes doesn't bring launch-time counts back")
    func floorEndsForGood() async throws {
        let a = try RoomID("!a:x.org")
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        port.preload([a: 5])
        let badge = BadgeCoordinator(rooms: coordinator, records: FakeNotificationRecords(), port: port)
        await badge.begin()
        await coordinator.start()
        try rooms.emit(.reset([try summary("!a:x.org")]))
        rooms.emitSyncComplete()
        #expect(await eventually { port.badge == 0 })
        await coordinator.stop()
        await coordinator.start()
        for _ in 0..<2_000 { await Task.yield() }
        await badge.reconcile()
        #expect(port.badge == 0)
    }
}
