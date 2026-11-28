import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("DraftCoordinator")
struct DraftCoordinatorTests {
    private let room = try! RoomID("!r:x.org")

    @Test("a draft is remembered, stored, and loaded from the store in a new run")
    func roundTrip() async {
        let store = FakeDrafts()
        let first = DraftCoordinator(store: store)
        await first.save("half a thought", for: room)
        #expect(store.stored[room] == "half a thought")
        let second = DraftCoordinator(store: store)
        #expect(await second.draft(for: room) == "half a thought")
        await second.save("", for: room)
        #expect(store.stored[room] == nil)
        #expect(await second.draft(for: room) == "")
    }

    @Test("drafts typed before the store exists are written when it is attached")
    func lateStore() async {
        let coordinator = DraftCoordinator()
        await coordinator.save("typed early", for: room)
        #expect(await coordinator.draft(for: room) == "typed early")
        let store = FakeDrafts()
        await coordinator.attach(store)
        #expect(store.stored[room] == "typed early")
    }

    @Test("storage errors never lose or block the text")
    func failingStore() async {
        let store = FakeDrafts()
        store.setFailing(true)
        let coordinator = DraftCoordinator(store: store)
        await coordinator.save("kept", for: room)
        #expect(await coordinator.draft(for: room) == "kept")
        #expect(await DraftCoordinator(store: store).draft(for: room) == "")
    }

    @Test("reset drops the previous account's drafts and store; the next store gets none of them")
    func resetOnAccountChange() async {
        let first = FakeDrafts()
        let coordinator = DraftCoordinator(store: first)
        await coordinator.save("for A only", for: room)
        await coordinator.reset()
        #expect(await coordinator.draft(for: room) == "")
        await coordinator.save("typed while signed out", for: room)
        #expect(first.stored[room] == "for A only")
        await coordinator.reset()
        let second = FakeDrafts()
        await coordinator.attach(second)
        #expect(second.stored.isEmpty)
        #expect(await coordinator.draft(for: room) == "")
    }

    @Test("F-09: a slow write of an older draft can't land after a newer one (writes keep the order they were made in)")
    func writesStayInOrder() async throws {
        let room = try RoomID("!r:x.org")
        let store = SlowFirstDraftStore()
        let drafts = DraftCoordinator(store: store)
        let first = Task { await drafts.save("hel", for: room) }
        while !store.firstWriteStarted { await Task.yield() }
        let second = Task { await drafts.save("hello", for: room) }
        for _ in 0..<2_000 { await Task.yield() }  // the newer save runs as far as it can while the older write hangs
        store.releaseFirstWrite()
        await first.value
        await second.value
        #expect(store.writes == ["hel", "hello"])
        #expect(store.stored == "hello")
    }
}

/// A `DraftPort` whose first write hangs until released, as a slow database write would.
private final class SlowFirstDraftStore: DraftPort, Sendable {
    private struct State {
        var writes: [String] = []
        var stored: String?
        var firstStarted = false
        var release: CheckedContinuation<Void, Never>?
        var released = false
    }
    private let state = Mutex(State())

    var writes: [String] { state.withLock { $0.writes } }
    var stored: String? { state.withLock { $0.stored } }
    var firstWriteStarted: Bool { state.withLock { $0.firstStarted } }

    func releaseFirstWrite() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.release = nil }
            return state.release
        }
        waiting?.resume()
    }

    func draft(for room: RoomID) async throws(HaloError) -> String? { stored }

    func save(_ text: String, for room: RoomID) async throws(HaloError) {
        let isFirst = state.withLock { state -> Bool in
            defer { state.firstStarted = true }
            return !state.firstStarted
        }
        if isFirst {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.released { return true }
                    state.release = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        state.withLock { state in
            state.writes.append(text)
            state.stored = text
        }
    }
}
