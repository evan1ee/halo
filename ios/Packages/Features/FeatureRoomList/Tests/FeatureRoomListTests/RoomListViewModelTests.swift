import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureRoomList

@MainActor
private func makeReadState(
    rooms: RoomListCoordinator, records: FakeNotificationRecords = FakeNotificationRecords(),
    badge: FakeBadgePort = FakeBadgePort(), receipts: ReadReceiptCoordinator? = nil
) async -> ReadStateCoordinator {
    let readState = ReadStateCoordinator(rooms: rooms, records: records, port: badge, receipts: receipts)
    await readState.begin()
    return readState
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

@MainActor
@Suite("RoomListViewModel")
struct RoomListViewModelTests {
    private func summary(_ id: String, _ name: String?) throws -> RoomSummary {
        RoomSummary(id: try RoomID(id), name: name, isDirect: false, isEncrypted: false, membership: .joined)
    }

    @Test("shows the room count and names once the list is loaded, and unnamed rooms get a label")
    func loaded() async throws {
        let port = FakeRoomListPort(rooms: [try summary("!a:x.org", "General"), try summary("!b:x.org", nil)])
        let coordinator = RoomListCoordinator(port: port)
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status {
                await model.listChanged(status)
                break
            }
        }
        #expect(model.content == .loaded(count: 2, rows: [
            .init(id: try RoomID("!a:x.org"), name: "General"), .init(id: try RoomID("!b:x.org"), name: "Unnamed room"),
        ]))
    }

    @Test("a failed list shows a message, retry restarts the coordinator, and an idle list shows nothing")
    func failures() async {
        let rooms = RoomListCoordinator(port: FakeRoomListPort())
        let readState = await makeReadState(rooms: rooms)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: rooms, readState: readState)
        await model.listChanged(.failed(.internal(code: "X")))
        #expect(model.content == .failed("The room list couldn't be loaded."))
        await model.retry()
        #expect(await rooms.status != .idle)
        await model.listChanged(.idle)
        #expect(model.content == .idle)
    }

    @Test("unread rooms show their count, and reading one here clears it")
    func unreadIndicator() async throws {
        let id = try RoomID("!a:x.org")
        let unread = RoomSummary(
            id: id, name: "A", isDirect: false, isEncrypted: false, membership: .joined,
            read: RoomReadCounts(mode: .allMessages, server: ServerCounts(notification: 2, highlight: 0), sdk: .zero, isMarkedUnread: false),
            latestEvent: LatestEventRef(timestamp: Date(timeIntervalSince1970: 100), senderIsSelf: false))
        let coordinator = RoomListCoordinator(port: FakeRoomListPort(rooms: [unread]))
        let receipts = ReadReceiptCoordinator(port: FakeReadMarkerPort())
        let readState = await makeReadState(rooms: coordinator, receipts: receipts)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState, receipts: receipts)
        await coordinator.start()
        #expect(await eventually { await readState.roomStates[id]?.display == .count(2) })
        await model.listChanged(.loaded(roomCount: 1))
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(2), hasUnread: true, lastActivity: Date(timeIntervalSince1970: 100))]))
        await receipts.reportSeen(room: id, event: try EventID("$e"), timestamp: Date(timeIntervalSince1970: 100))
        #expect(await eventually { await readState.roomStates[id]?.display == DisplayCount.none })
        await model.listChanged(.loaded(roomCount: 1))
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", lastActivity: Date(timeIntervalSince1970: 100))]))
    }

    @Test("a change of unread counts with the same number of rooms refreshes the rows (sync updates arrive as .set)")
    func countsChangeRefreshesRows() async throws {
        let id = try RoomID("!a:x.org")
        func room(_ n: Int) -> RoomSummary {
            RoomSummary(
                id: id, name: "A", isDirect: false, isEncrypted: false, membership: .joined,
                read: RoomReadCounts(mode: .allMessages, server: ServerCounts(notification: n, highlight: 0), sdk: .zero, isMarkedUnread: false),
                latestEvent: LatestEventRef(timestamp: Date(timeIntervalSince1970: 100), senderIsSelf: false))
        }
        let port = FakeRoomListPort(rooms: [room(0)])
        let coordinator = RoomListCoordinator(port: port)
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState)
        await model.start()
        for _ in 0..<50_000 { await Task.yield() }  // the signed-out fake session has stopped the (idle) list by now
        await coordinator.start()
        for _ in 0..<200_000 { if case .loaded = model.content { break }; await Task.yield() }
        try port.emit(.set(index: 0, room(3)))
        for _ in 0..<200_000 { if model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(3), hasUnread: true, lastActivity: Date(timeIntervalSince1970: 100))]) { break }; await Task.yield() }
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(3), hasUnread: true, lastActivity: Date(timeIntervalSince1970: 100))]))
    }

    @Test("PS31 (R-05): room list and badge always agree across generated inputs, including push-only notification records")
    func roomListAndBadgeAlwaysAgree() async throws {
        var rng = SeededRandomNumberGenerator(seed: 31)
        let modes: [NotificationMode] = [.allMessages, .mentionsAndKeywords, .mute]
        let port = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: port)
        let records = FakeNotificationRecords()
        let badgePort = FakeBadgePort()
        let receipts = ReadReceiptCoordinator(port: FakeReadMarkerPort())
        let readState = await makeReadState(rooms: coordinator, records: records, badge: badgePort, receipts: receipts)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState, receipts: receipts)
        await coordinator.start()

        for trial in 0..<100 {
            records.clearAll()
            let count = Int.random(in: 1...6, using: &rng)
            var summaries: [RoomSummary] = []
            for i in 0..<count {
                let id = try RoomID("!r\(trial)_\(i):x.org")
                let encrypted = Bool.random(using: &rng)
                let mode = modes.randomElement(using: &rng)!
                let membership: Membership = Int.random(in: 0..<6, using: &rng) == 0 ? .invited : .joined
                let serverNotify = Int.random(in: 0...2, using: &rng)
                let serverHighlight = Int.random(in: 0...serverNotify, using: &rng)
                let sdkMsg = Int.random(in: 0...2, using: &rng)
                let sdkNotify = Int.random(in: 0...sdkMsg, using: &rng)
                let sdkMention = Int.random(in: 0...sdkNotify, using: &rng)
                let latest: LatestEventRef? = Bool.random(using: &rng)
                    ? LatestEventRef(timestamp: Date(timeIntervalSince1970: Double(Int.random(in: 10...100, using: &rng))), senderIsSelf: Bool.random(using: &rng))
                    : nil
                summaries.append(RoomSummary(
                    id: id, name: "R\(i)", isDirect: false, isEncrypted: encrypted, membership: membership,
                    read: RoomReadCounts(
                        mode: mode,
                        server: ServerCounts(notification: serverNotify, highlight: serverHighlight),
                        sdk: SDKCounts(unreadMessages: sdkMsg, unreadNotifications: sdkNotify, unreadMentions: sdkMention),
                        isMarkedUnread: Int.random(in: 0..<5, using: &rng) == 0),
                    latestEvent: latest))
                if Bool.random(using: &rng) {
                    records.add(NotificationRecord(
                        roomID: id, eventID: try EventID("$p\(trial)_\(i)"),
                        timestamp: Date(timeIntervalSince1970: Double(Int.random(in: 50...150, using: &rng))),
                        isMention: Bool.random(using: &rng)))
                }
            }
            try port.emit(.reset(summaries))
            port.emitSyncComplete(present: Set(summaries.map(\.id)))
            let expectedIDs = Set(summaries.map(\.id))
            #expect(await eventually { Set(await readState.roomStates.keys) == expectedIDs })
            await model.listChanged(.loaded(roomCount: summaries.count))

            guard case .loaded(_, let rows) = model.content else {
                Issue.record("trial \(trial): not loaded")
                return
            }
            let badgeCount = await readState.badge
            let states = await readState.roomStates
            let attentionRooms = await readState.attentionRooms
            let rowsWithIndicator = rows.filter { $0.display != .none }
            #expect(badgeCount == BadgeCalculator.badge(Array(states.values)), "seed 31 trial \(trial): badge \(badgeCount) disagrees with BadgeCalculator")
            #expect(attentionRooms == Set(rowsWithIndicator.map(\.id)), "seed 31 trial \(trial): attention rooms disagree with list rows")
        }
    }
}

@MainActor
@Suite("RoomListViewModel invitations")
struct RoomListInviteTests {
    @Test("an invited room is marked as an invitation; accepting and declining go to the port, a failure is shown")
    func invites() async throws {
        let id = try RoomID("!inv:x.org")
        let invited = RoomSummary(id: id, name: "Book club", isDirect: false, isEncrypted: false, membership: .invited, inviter: "Ann")
        let coordinator = RoomListCoordinator(port: FakeRoomListPort(rooms: [invited]))
        let readState = await makeReadState(rooms: coordinator)
        let port = FakeRoomPort(details: RoomDetails(id: id, name: nil, topic: nil, isDirect: false, isEncrypted: false, joinedMemberCount: 0, notificationMode: .allMessages))
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState, actions: port)
        await coordinator.start()
        #expect(await eventually { await readState.roomStates[id]?.display == .dot })
        await model.listChanged(.loaded(roomCount: 1))
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "Book club", display: .dot, hasUnread: true, isInvite: true, inviter: "Ann")]))
        await model.previewInvite(id)
        #expect(model.invitePreviews[id]?.memberCount == 3 && model.actionError == nil)
        port.fail(with: .notFound)
        await model.previewInvite(id)
        #expect(model.actionError == "The invitation's details couldn't be loaded.")
        port.fail(with: nil)
        await model.acceptInvite(id)
        #expect(port.acceptedInvites == [id] && model.actionError == nil)
        await model.declineInvite(id)
        #expect(port.declinedInvites == [id])
        port.fail(with: .notFound)
        await model.acceptInvite(id)
        #expect(model.actionError != nil)
        model.dismissActionError()
        #expect(model.actionError == nil)
    }
}

@MainActor
@Suite("RoomListViewModel filters and swipes")
struct RoomListFilterTests {
    private func summary(_ id: String, name: String, direct: Bool = false, membership: Membership = .joined, favourite: Bool = false, muted: Bool = false) throws -> RoomSummary {
        let counts = RoomReadCounts(mode: muted ? .mute : .allMessages, server: .zero, sdk: .zero, isMarkedUnread: false)
        return RoomSummary(id: try RoomID(id), name: name, isDirect: direct, isEncrypted: false, membership: membership, read: counts, isFavourite: favourite)
    }

    private func loaded(_ rooms: [RoomSummary], actions: FakeRoomPort? = nil) async throws -> RoomListViewModel {
        let coordinator = RoomListCoordinator(port: FakeRoomListPort(rooms: rooms))
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState, actions: actions)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        return model
    }

    private func names(_ model: RoomListViewModel) -> [String] {
        guard case .loaded(_, let rows) = model.content else { return [] }
        return rows.map(\.name)
    }

    @Test("each filter keeps its rooms: people, rooms, favourites, invites")
    func filters() async throws {
        let model = try await loaded([
            try summary("!a:x.org", name: "Ann", direct: true), try summary("!b:x.org", name: "Book club", favourite: true),
            try summary("!c:x.org", name: "Invite", membership: .invited), try summary("!d:x.org", name: "Dev", favourite: true, muted: true),
        ])
        #expect(names(model).count == 4)
        model.filter = .people
        await model.listChanged(.loaded(roomCount: 4))
        #expect(names(model) == ["Ann"])
        model.filter = .rooms
        await model.listChanged(.loaded(roomCount: 4))
        #expect(names(model) == ["Book club", "Dev"])
        model.filter = .favourites
        await model.listChanged(.loaded(roomCount: 4))
        #expect(names(model) == ["Book club", "Dev"])
        model.filter = .invites
        await model.listChanged(.loaded(roomCount: 4))
        #expect(names(model) == ["Invite"])
        guard case .loaded(let count, _) = model.content else { Issue.record("not loaded"); return }
        #expect(count == 1)
    }

    @Test("favourite and mute swipes go to the port; a muted room is unmuted by the second swipe")
    func swipes() async throws {
        let id = try RoomID("!d:x.org")
        let port = FakeRoomPort(details: RoomDetails(id: id, name: nil, topic: nil, isDirect: false, isEncrypted: false, joinedMemberCount: 0, notificationMode: .allMessages))
        let model = try await loaded([try summary("!d:x.org", name: "Dev", favourite: true, muted: true)], actions: port)
        guard case .loaded(_, let rows) = model.content, let row = rows.first else { Issue.record("no row"); return }
        #expect(row.isFavourite && row.isMuted)
        await model.toggleFavourite(row)
        await model.toggleMute(row)
        #expect(port.favouriteChanges.map(\.on) == [false])
        #expect(port.modeChanges == [.allMessages])
    }
}

@MainActor
@Suite("RoomListViewModel previews")
struct RoomListPreviewTests {
    @Test("a row shows the newest message as one line: the bare text in a direct chat, the sender's name in a group")
    func previewLines() async throws {
        let ann = RoomSummary(id: try RoomID("!a:x.org"), name: "Ann", isDirect: true, isEncrypted: false, membership: .joined, preview: LatestMessagePreview(text: "see you", senderName: "Ann", isOwn: false))
        let club = RoomSummary(id: try RoomID("!b:x.org"), name: "Club", isDirect: false, isEncrypted: false, membership: .joined, preview: LatestMessagePreview(text: "Photo", senderName: "Bob", isOwn: false))
        let quiet = RoomSummary(id: try RoomID("!c:x.org"), name: "Quiet", isDirect: false, isEncrypted: false, membership: .joined)
        let coordinator = RoomListCoordinator(port: FakeRoomListPort(rooms: [ann, club, quiet]))
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        guard case .loaded(_, let rows) = model.content else { Issue.record("not loaded"); return }
        #expect(rows.map(\.preview) == ["see you", "Bob: Photo", nil])
    }

    @Test
    func avatarRowsAndData() async throws {
        let ref = MediaRef(token: "avatar-token")
        let ann = RoomSummary(id: try RoomID("!a:x.org"), name: "Ann", isDirect: true, isEncrypted: false, membership: .joined, avatar: ref)
        let quiet = RoomSummary(id: try RoomID("!c:x.org"), name: "Quiet", isDirect: false, isEncrypted: false, membership: .joined)
        let port = FakeMediaPort()
        port.add(ref, data: Data([1, 2, 3]))
        let coordinator = RoomListCoordinator(port: FakeRoomListPort(rooms: [ann, quiet]))
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState, media: MediaLoader(port: port))
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        guard case .loaded(_, let rows) = model.content else { Issue.record("not loaded"); return }
        #expect(rows.map(\.avatar) == [ref, nil])
        #expect(rows.map(\.inviter) == [nil, nil])
        #expect(await model.avatarData(ref) == Data([1, 2, 3]))
        #expect(await model.avatarData(MediaRef(token: "missing")) == nil)
    }
}

@MainActor
@Suite("RoomListViewModel warm-up and invitation previews")
struct RoomListWarmTests {
    private actor Calls {
        var requests: [[RoomID]] = []
        func add(_ rooms: [RoomID]) { requests.append(rooms) }
    }

    @Test("the top rooms are handed to warm once per change of the top, never invitations")
    func warmsTopOnce() async throws {
        let a = RoomSummary(id: try RoomID("!a:x.org"), name: "A", isDirect: false, isEncrypted: false, membership: .joined)
        let inv = RoomSummary(id: try RoomID("!i:x.org"), name: "I", isDirect: false, isEncrypted: false, membership: .invited)
        let port = FakeRoomListPort(rooms: [inv, a])
        let coordinator = RoomListCoordinator(port: port)
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState)
        let calls = Calls()
        model.warm = { await calls.add($0) }
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        await model.listChanged(.loaded(roomCount: 2))  // same top: no second request
        for _ in 0..<10_000 { if await !calls.requests.isEmpty { break }; await Task.yield() }
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await calls.requests == [[a.id]])
    }

    @Test("a preview disappears once its room is no longer an invitation")
    func previewsPruned() async throws {
        let id = try RoomID("!inv:x.org")
        func summary(_ membership: Membership) -> RoomSummary {
            RoomSummary(id: id, name: "Club", isDirect: false, isEncrypted: false, membership: membership)
        }
        let listPort = FakeRoomListPort(rooms: [summary(.invited)])
        let coordinator = RoomListCoordinator(port: listPort)
        let readState = await makeReadState(rooms: coordinator)
        let actions = FakeRoomPort(details: RoomDetails(id: id, name: nil, topic: nil, isDirect: false, isEncrypted: false, joinedMemberCount: 0, notificationMode: .allMessages))
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState, actions: actions)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        await model.previewInvite(id)
        #expect(model.invitePreviews[id] != nil)
        try listPort.emit(.set(index: 0, summary(.joined)))
        for _ in 0..<200_000 {
            if await coordinator.rooms.first?.membership == .joined { break }
            await Task.yield()
        }
        await model.listChanged(.loaded(roomCount: 1))
        #expect(model.invitePreviews[id] == nil)
    }

    @Test("sync indicator appears only while offline or retrying, and clears once running (ROOM_LIST FR-7)")
    func syncIndicator() async {
        let syncPort = FakeSyncPort()
        let session = SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain())
        let sync = SyncCoordinator(port: syncPort, session: session, sleep: { _ in })
        await sync.begin()
        let rooms = RoomListCoordinator(port: FakeRoomListPort())
        let readState = await makeReadState(rooms: rooms)
        let model = RoomListViewModel(session: session, rooms: rooms, readState: readState, sync: sync)
        await model.start()
        #expect(model.syncNotice == nil)
        syncPort.report(.offline)
        for _ in 0..<200_000 where model.syncNotice?.isOffline != true { await Task.yield() }
        #expect(model.syncNotice == .init(text: "Offline — waiting to reconnect", isOffline: true))
        syncPort.report(.failed)
        for _ in 0..<200_000 where model.syncNotice?.isOffline != false { await Task.yield() }
        #expect(model.syncNotice == .init(text: "Sync interrupted — retrying…", isOffline: false))
        syncPort.report(.running)
        for _ in 0..<200_000 where model.syncNotice != nil { await Task.yield() }
        #expect(model.syncNotice == nil)
    }

    @Test("allowlisted bot messages show a concise card preview and update on refresh (ROOM_LIST FR-3)")
    func botCardPreview() async throws {
        let roomID = try RoomID("!bot:x.org")
        let botID = try UserID("@bot:x.org")
        let summary = RoomSummary(
            id: roomID, name: "Tasks", isDirect: false, isEncrypted: false, membership: .joined,
            preview: LatestMessagePreview(
                text: "📋 Work:", senderName: "TodoBot", isOwn: false, senderID: botID,
                formattedBody: "📋 <b>Work:</b><br/>• [<b>#1</b>] Ship<br/>• [<b>#2</b>] <del>Plan</del> ✅"))
        let coordinator = RoomListCoordinator(port: FakeRoomListPort(rooms: [summary]))
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        if case .loaded(_, let rows) = model.content {
            #expect(rows.first?.preview == "TodoBot: 📋 Work:")
        } else {
            Issue.record("expected loaded room list")
        }

        model.botSenders = { [botID.rawValue] }
        await model.refresh()
        if case .loaded(_, let rows) = model.content {
            #expect(rows.first?.preview == "TodoBot: Work · 1 open")
        } else {
            Issue.record("expected loaded room list")
        }
    }

    @Test("room list pages large accounts in slices of pageSize and resets visibleLimit on filter change")
    func roomListPaging() async throws {
        var summaries: [RoomSummary] = []
        for i in 0..<5 {
            summaries.append(RoomSummary(
                id: try RoomID("!r\(i):x.org"), name: "Room \(i)",
                isDirect: i == 0, isEncrypted: false, membership: .joined))
        }
        let coordinator = RoomListCoordinator(port: FakeRoomListPort(rooms: summaries))
        let readState = await makeReadState(rooms: coordinator)
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: coordinator, readState: readState, pageSize: 2)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        if case .loaded(let count, let rows) = model.content {
            #expect(count == 5 && rows.count == 2 && model.canShowMore)
        } else {
            Issue.record("expected loaded room list")
        }

        await model.showMore()
        if case .loaded(let count, let rows) = model.content {
            #expect(count == 5 && rows.count == 4 && model.canShowMore)
        }

        await model.showMore()
        if case .loaded(let count, let rows) = model.content {
            #expect(count == 5 && rows.count == 5 && !model.canShowMore)
        }

        model.filter = .rooms
        await model.listChanged(.loaded(roomCount: 5))
        if case .loaded(let count, let rows) = model.content {
            #expect(count == 4 && rows.count == 2 && model.canShowMore && model.visibleLimit == 2)
        }
    }

    @Test("MessageSearchViewModel queries SearchCoordinator, resolves room names and paginates")
    func messageSearchViewModel() async throws {
        let roomA = try RoomID("!a:x.org")
        let port = FakeSearchPort(
            corpus: [
                MessageSearchHit(roomID: roomA, eventID: try EventID("$1"), senderID: "@bob:x.org", senderName: "Bob", body: "deploy checklist", timestamp: Date(timeIntervalSince1970: 100)),
                MessageSearchHit(roomID: roomA, eventID: try EventID("$2"), senderID: "@bob:x.org", senderName: nil, body: "deploy verified", timestamp: Date(timeIntervalSince1970: 200)),
            ],
            pageSize: 1)
        let coordinator = SearchCoordinator(port: port)
        let model = MessageSearchViewModel(coordinator: coordinator) { id in
            id == roomA ? "Ops" : "Unknown"
        }
        await model.start()
        model.query = "deploy"
        await model.submit()
        for _ in 0..<50_000 where model.rows.count < 1 { await Task.yield() }
        #expect(model.rows.count == 1 && model.rows[0].roomName == "Ops" && model.rows[0].sender == "Bob" && model.hasMore)

        await model.loadMore()
        for _ in 0..<50_000 where model.rows.count < 2 { await Task.yield() }
        #expect(model.rows.count == 2 && model.rows[1].sender == "@bob:x.org" && !model.hasMore)

        await model.clear()
        for _ in 0..<50_000 where !model.rows.isEmpty { await Task.yield() }
        #expect(model.rows.isEmpty && model.query.isEmpty)
    }
}
