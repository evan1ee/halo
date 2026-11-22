import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("SearchCoordinator")
struct SearchCoordinatorTests {
    private func makeHit(_ idx: Int, body: String) throws -> MessageSearchHit {
        MessageSearchHit(
            roomID: try RoomID("!r\(idx):x.org"),
            eventID: try EventID("$e\(idx)"),
            senderID: "@alice:x.org",
            senderName: "Alice",
            body: body,
            timestamp: Date(timeIntervalSince1970: Double(100 + idx)))
    }

    @Test("searches across rooms, paginates with loadMore, and clears on empty query")
    func searchAndPaginate() async throws {
        let port = FakeSearchPort(
            corpus: [
                try makeHit(1, body: "hello matrix world"),
                try makeHit(2, body: "matrix search test"),
                try makeHit(3, body: "another matrix message"),
                try makeHit(4, body: "unrelated"),
            ],
            pageSize: 2)
        let coordinator = SearchCoordinator(port: port)
        await coordinator.search("matrix")
        for _ in 0..<50_000 {
            if await coordinator.snapshot.hits.count == 2 { break }
            await Task.yield()
        }
        let first = await coordinator.snapshot
        #expect(first.hits.count == 2 && first.hasMore && !first.isLoading && first.error == nil)

        await coordinator.loadMore()
        for _ in 0..<50_000 {
            if await coordinator.snapshot.hits.count == 3 { break }
            await Task.yield()
        }
        let second = await coordinator.snapshot
        #expect(second.hits.count == 3 && !second.hasMore)

        await coordinator.clear()
        for _ in 0..<50_000 {
            if await coordinator.snapshot.hits.isEmpty { break }
            await Task.yield()
        }
        let cleared = await coordinator.snapshot
        #expect(cleared.hits.isEmpty && cleared.query.isEmpty)
    }

    @Test("port errors are captured in snapshot.error without crashing")
    func reportsFailure() async {
        let port = FakeSearchPort()
        port.failNext(with: .network(retryable: true))
        let coordinator = SearchCoordinator(port: port)
        await coordinator.search("hello")
        let snap = await coordinator.snapshot
        #expect(snap.error == .network(retryable: true) && !snap.isLoading && snap.hits.isEmpty)
    }
}
