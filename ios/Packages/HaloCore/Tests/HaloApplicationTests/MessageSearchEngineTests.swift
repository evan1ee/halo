import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

/// The search lifecycle that used to live, untested, in the app target (audit F-02): which index is open, when it closes and is
/// deleted, when a background task is asked for, and what the indexer is told it may do.
@MainActor
@Suite("MessageSearchEngine (audit F-02)")
struct MessageSearchEngineTests {
    private let alice = try! UserID("@alice:x.org")
    private let bob = try! UserID("@bob:x.org")

    private final class Calls: Sendable {
        private let state = Mutex((scheduled: 0, removedAll: 0))
        var scheduled: Int { state.withLock { $0.scheduled } }
        var removedAll: Int { state.withLock { $0.removedAll } }
        func schedule() { state.withLock { $0.scheduled += 1 } }
        func removeAll() { state.withLock { $0.removedAll += 1 } }
    }

    private func engine(
        preferences: PreferencesStore? = nil, device: MessageSearchEngine.DeviceState = .init(), calls: Calls = Calls()
    ) -> MessageSearchEngine {
        let session = SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain())
        return MessageSearchEngine(
            source: FakeMessageIndexSource(), rooms: RoomListCoordinator(port: FakeRoomListPort()), profiles: FakeProfilePort(),
            encryption: EncryptionCoordinator(port: FakeEncryptionPort(recoveryKey: nil), session: session),
            preferences: preferences ?? PreferencesStore(port: FakePreferencesPort()),
            environment: .init(device: { device }, scheduleProcessing: { calls.schedule() }, removeAllIndexes: { calls.removeAll() }))
    }

    @Test("signing in opens the account's index once and lets the first sync go; the same account again reuses it", .timeLimit(.minutes(1)))
    func attachOncePerAccount() async {
        let search = engine()
        let made = Mutex<[FakeSearchIndex]>([])
        let make: @MainActor () -> any AccountSearchIndexPort = {
            let index = FakeSearchIndex()
            made.withLock { $0.append(index) }
            return index
        }
        await search.attach(alice, index: make)
        await search.gate.wait()  // returns at once: the gate is open
        #expect(search.isAttached && made.withLock { $0.count } == 1 && made.withLock { $0[0].resumes } == 1)

        await search.attach(alice, index: make)
        #expect(made.withLock { $0.count } == 1, "the same account keeps its open index")

        await search.attach(bob, index: make)
        #expect(made.withLock { $0.count } == 2, "another account gets its own index")
        #expect(!made.withLock { $0[0].destroyed }, "switching accounts closes the old index but doesn't delete it")
        await search.detach(deletingIndex: false)
    }

    @Test("signing out deletes the index and every index file, and resets the status (AC-SRCH-8)")
    func detachDeletes() async {
        let calls = Calls()
        let search = engine(calls: calls)
        let index = FakeSearchIndex()
        await search.attach(alice) { index }
        await search.detach(deletingIndex: true)
        #expect(index.destroyed && calls.removedAll == 1)
        #expect(!search.isAttached && search.status == SearchIndexStatus())
        #expect(search.settingsStatusIsHidden)
    }

    @Test("the index file closes before the phone locks and opens again after unlock (D124)")
    func lockAndUnlock() async {
        let search = engine()
        let index = FakeSearchIndex()
        await search.attach(alice) { index }
        await search.phoneWillLock()
        #expect(index.suspensions.count == 1)
        await search.phoneUnlocked()
        #expect(index.resumes == 2, "once at sign-in, once after unlock")
        await search.detach(deletingIndex: false)
    }

    @Test("leaving the foreground with history left asks for a processing task, unless the user paused reading history")
    func backgroundProcessing() async {
        let calls = Calls()
        let preferences = PreferencesStore(port: FakePreferencesPort())
        let search = engine(preferences: preferences, calls: calls)
        await search.setForeground(false)
        #expect(calls.scheduled == 0, "no account, nothing to read")

        await search.attach(alice) { FakeSearchIndex() }
        await search.setForeground(true)
        await search.setForeground(false)
        #expect(calls.scheduled == 1)

        preferences.searchHistoryPaused = true
        await search.setForeground(true)
        await search.setForeground(false)
        #expect(calls.scheduled == 1, "paused by the user: no background task")
        await search.detach(deletingIndex: false)
    }

    @Test("the indexer is told the device's state and the user's choices, and may run only in front or in a processing task")
    func conditions() async {
        let preferences = PreferencesStore(port: FakePreferencesPort())
        preferences.searchHistoryOnMobileData = true
        let search = engine(preferences: preferences, device: .init(lowPower: true, isHot: false, onMobileData: true, offline: false))
        var conditions = search.conditions()
        #expect(conditions.lowPower && conditions.onMobileData && conditions.mobileDataAllowed && !conditions.offline)
        #expect(!conditions.mayRun, "in the background without a processing task, history waits")
        await search.setForeground(true)
        conditions = search.conditions()
        #expect(conditions.mayRun)
    }

    @Test("M20-11: room-scoped coordinator searches only its room, refreshes on live writes, and never disturbs global search", .timeLimit(.minutes(1)))
    func roomSearchCoordinatorIsolation() async throws {
        let roomA = try RoomID("!roomA:x.org"), roomB = try RoomID("!roomB:x.org")
        let source = FakeMessageIndexSource()
        source.setJoined([roomA, roomB])
        let rooms = RoomListCoordinator(port: FakeRoomListPort())
        let session = SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain())
        let search = MessageSearchEngine(
            source: source, rooms: rooms, profiles: FakeProfilePort(),
            encryption: EncryptionCoordinator(port: FakeEncryptionPort(recoveryKey: nil), session: session),
            preferences: PreferencesStore(port: FakePreferencesPort()))

        let index = FakeSearchIndex()
        try await index.apply([.live([
            .message(SearchIndexEntry(
                room: roomA, event: try EventID("$a1"), sender: alice, senderName: "Alice", threadRoot: nil,
                timestamp: Date(timeIntervalSince1970: 100), content: SearchableContent(kind: .message, body: "quarterly report"))),
            .message(SearchIndexEntry(
                room: roomB, event: try EventID("$b1"), sender: bob, senderName: "Bob", threadRoot: nil,
                timestamp: Date(timeIntervalSince1970: 200), content: SearchableContent(kind: .message, body: "quarterly review"))),
        ])])
        await search.attach(alice) { index }

        // Global search finds both rooms.
        await search.coordinator.search(SearchQuery(text: "quarterly"), now: true)
        for _ in 0..<200_000 {
            if await search.coordinator.snapshot.hits.count == 2 { break }
            await Task.yield()
        }
        #expect(await search.coordinator.snapshot.hits.count == 2)

        // Independent room search finds only roomA and leaves global search untouched.
        let roomCoordinator = search.makeRoomSearchCoordinator()
        await roomCoordinator.search(SearchQuery(text: "quarterly", room: roomA), now: true)
        for _ in 0..<200_000 {
            if await roomCoordinator.snapshot.hits.count == 1 { break }
            await Task.yield()
        }
        let roomHits = await roomCoordinator.snapshot.hits
        #expect(roomHits.map(\.eventID) == [try EventID("$a1")])
        #expect(await search.coordinator.snapshot.hits.count == 2, "global search stays intact")

        // A live write in roomA refreshes the room coordinator automatically.
        source.yield(SearchLiveBatch(events: [
            .message(SearchIndexEntry(
                room: roomA, event: try EventID("$a2"), sender: alice, senderName: "Alice", threadRoot: nil,
                timestamp: Date(timeIntervalSince1970: 300), content: SearchableContent(kind: .message, body: "quarterly update"))),
        ], touched: [roomA]))
        for _ in 0..<200_000 {
            if await roomCoordinator.snapshot.hits.count == 2 { break }
            await Task.yield()
        }
        #expect(await roomCoordinator.snapshot.hits.map(\.eventID) == [try EventID("$a2"), try EventID("$a1")])

        await search.detach(deletingIndex: false)
        #expect(await roomCoordinator.snapshot.hits.isEmpty)
    }
}

private extension MessageSearchEngine {
    /// Settings shows nothing for an account that isn't attached.
    var settingsStatusIsHidden: Bool { !isAttached }
}
