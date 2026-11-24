import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

/// A silent push or an app refresh while the app has no window (BACKGROUND_EXECUTION).
@Suite("BackgroundRefresh")
struct BackgroundRefreshTests {
    private struct Rig {
        let session: SessionCoordinator
        let syncPort = FakeSyncPort()
        let sync: SyncCoordinator
        let rooms = FakeRoomListPort()
        let list: RoomListCoordinator
        let badge = FakeBadgePort()
        let readState: ReadStateCoordinator

        init() throws {
            let sessionPort = FakeSessionPort()
            let url = try #require(URL(string: "https://example.org"))
            sessionPort.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
            sessionPort.addAccount(.init(localpart: "alice", password: "pw"))
            session = SessionCoordinator(port: sessionPort, keychain: InMemoryKeychain())
            sync = SyncCoordinator(port: syncPort, session: session)
            list = RoomListCoordinator(port: rooms)
            readState = ReadStateCoordinator(rooms: list, records: FakeNotificationRecords(), port: badge)
        }

        func signIn() async {
            await session.start()
            await session.discover(server: "example.org")
            await session.loginPassword(username: "alice", password: "pw")
        }

        var refresh: BackgroundRefresh { BackgroundRefresh(session: session, sync: sync, rooms: list, readState: readState) }
    }

    private func summary(notify: Int) throws -> RoomSummary {
        RoomSummary(
            id: try RoomID("!a:x.org"), name: "a", isDirect: false, isEncrypted: false, membership: .joined,
            read: RoomReadCounts(mode: .allMessages, server: ServerCounts(notification: notify, highlight: 0), sdk: .zero, isMarkedUnread: false))
    }

    @Test("when it returns, the counts of its sync are on the icon: iOS suspends the app right after")
    func returnsAfterTheBadge() async throws {
        let rig = try Rig()
        let unread = try summary(notify: 5), rooms = rig.rooms
        rig.syncPort.onSyncOnce {
            try? rooms.emit(.reset([unread]))
            rooms.emitSyncComplete()
        }
        await rig.readState.begin()
        await rig.signIn()
        await rig.list.start()
        // Not `sync.begin()`: after a cold launch this actor hasn't heard yet that the session is ready.
        #expect(await rig.refresh.run())
        #expect(rig.badge.badge == 5)
        #expect(rig.syncPort.syncOnceCalls == 1 && rig.syncPort.startCalls == 0)
    }

    @Test("read on another device: the silent push clears the badge")
    func readElsewhere() async throws {
        let rig = try Rig()
        rig.badge.preload([try RoomID("!a:x.org"): 5])
        let read = try summary(notify: 0), rooms = rig.rooms
        try rooms.emit(.reset([try summary(notify: 5)]))
        rig.syncPort.onSyncOnce {
            try? rooms.emit(.reset([read]))
            rooms.emitSyncComplete()
        }
        await rig.readState.begin()
        await rig.signIn()
        await rig.list.start()
        #expect(await rig.refresh.run())
        #expect(rig.badge.badge == 0)
    }

    @Test("signed out or a failed sync: nothing is touched")
    func nothingToDo() async throws {
        let rig = try Rig()
        rig.badge.preload([try RoomID("!a:x.org"): 5])
        await rig.readState.begin()
        await rig.session.start()
        #expect(await rig.refresh.run() == false)
        #expect(rig.syncPort.syncOnceCalls == 0)
        await rig.signIn()
        await rig.list.start()
        rig.syncPort.failNextSyncOnce(with: .network(retryable: true))
        #expect(await rig.refresh.run() == false)
        #expect(rig.badge.badge == 5)
    }

    @Test("while the foreground loop runs there is no second sync")
    func foregroundLoop() async throws {
        let rig = try Rig()
        await rig.sync.begin()
        await rig.signIn()
        await rig.sync.setForeground(true)
        for await status in await rig.sync.statuses() where status == .running { break }
        #expect(await rig.sync.syncOnceInBackground() == false)
        #expect(rig.syncPort.syncOnceCalls == 0)
    }
}
