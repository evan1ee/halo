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
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(2), hasUnread: true)]))
        await model.positionsChanged([id: Date(timeIntervalSince1970: 100)])
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A")]))
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
        for _ in 0..<200_000 { if model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(3), hasUnread: true)]) { break }; await Task.yield() }
        #expect(model.content == .loaded(count: 1, rows: [.init(id: id, name: "A", display: .count(3), hasUnread: true)]))
    }
}
