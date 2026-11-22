import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureSearch

@Suite("MessageSearchViewModel (FeatureSearch)")
struct MessageSearchViewModelTests {
    @Test("MessageSearchViewModel queries SearchCoordinator, resolves room names and paginates")
    @MainActor
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
