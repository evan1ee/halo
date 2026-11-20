import HaloDomain
import HaloFoundation
import HaloTestSupport
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
}
