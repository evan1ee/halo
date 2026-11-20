import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureRoomList

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
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()), rooms: coordinator)
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

    @Test("a failed list shows a message, an idle list shows nothing")
    func failures() async {
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()),
            rooms: RoomListCoordinator(port: FakeRoomListPort()))
        await model.listChanged(.failed(.internal(code: "X")))
        #expect(model.content == .failed("The room list couldn't be loaded. Pull to try again."))
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
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()), rooms: coordinator,
            receipts: ReadReceiptCoordinator(port: FakeReadMarkerPort()))
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(2), hasUnread: true, lastActivity: Date(timeIntervalSince1970: 100))]))
        await model.positionsChanged([id: Date(timeIntervalSince1970: 100)])
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
        let model = RoomListViewModel(session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()), rooms: coordinator)
        await model.start()
        for _ in 0..<50_000 { await Task.yield() }  // the signed-out fake session has stopped the (idle) list by now
        await coordinator.start()
        for _ in 0..<200_000 { if case .loaded = model.content { break }; await Task.yield() }
        try port.emit(.set(index: 0, room(3)))
        for _ in 0..<200_000 { if model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(3), hasUnread: true, lastActivity: Date(timeIntervalSince1970: 100))]) { break }; await Task.yield() }
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(3), hasUnread: true, lastActivity: Date(timeIntervalSince1970: 100))]))
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
        let port = FakeRoomPort(details: RoomDetails(id: id, name: nil, topic: nil, isDirect: false, isEncrypted: false, joinedMemberCount: 0, notificationMode: .allMessages))
        let model = RoomListViewModel(
            session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()), rooms: coordinator, actions: port)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { await model.listChanged(status); break }
        }
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "Book club", display: .dot, hasUnread: true, isInvite: true, inviter: "Ann")]))
        await model.acceptInvite(id)
        #expect(port.acceptedInvites == [id] && model.actionError == nil)
        await model.declineInvite(id)
        #expect(port.declinedInvites == [id])
        port.fail(with: .notFound)
        await model.acceptInvite(id)
        #expect(model.actionError != nil)
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
        let model = RoomListViewModel(session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()), rooms: coordinator, actions: actions)
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
        let model = RoomListViewModel(session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()), rooms: coordinator)
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
        let model = RoomListViewModel(session: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()), rooms: coordinator, media: MediaLoader(port: port))
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
