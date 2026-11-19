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
        #expect(model.content == .loaded(count: 2, names: ["General", "Unnamed room"]))
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
}
