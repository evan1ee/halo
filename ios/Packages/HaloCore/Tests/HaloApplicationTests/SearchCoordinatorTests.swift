import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("SearchCoordinator", .timeLimit(.minutes(1)))
struct SearchCoordinatorTests {
    private func hit(_ number: Int, _ body: String, room: String = "!r:x.org", kind: SearchKind = .message) throws -> MessageSearchHit {
        MessageSearchHit(
            roomID: try RoomID(room), eventID: try EventID("$e\(number)"), senderID: "@alice:x.org", senderName: "Alice", body: body,
            timestamp: Date(timeIntervalSince1970: Double(number)), kind: kind)
    }

    private func settled(_ coordinator: SearchCoordinator, _ condition: (SearchCoordinator.Snapshot) -> Bool) async -> SearchCoordinator.Snapshot {
        for await snapshot in await coordinator.snapshots() where condition(snapshot) { return snapshot }
        return .empty
    }

    @Test("pages, filters and clears")
    func pages() async throws {
        let port = FakeSearchPort(corpus: try (1...5).map { try hit($0, "matrix \($0)", kind: $0 == 5 ? .file : .message) }, pageSize: 2)
        let coordinator = SearchCoordinator(port: port, sleep: { _ in })
        await coordinator.search(SearchQuery(text: " matrix "))
        let first = await settled(coordinator) { !$0.isLoading && !$0.hits.isEmpty }
        #expect(first.hits.map(\.body) == ["matrix 5", "matrix 4"] && first.hasMore && first.query.text == "matrix")
        await coordinator.loadMore()
        await coordinator.loadMore()
        let all = await coordinator.snapshot
        #expect(all.hits.count == 5 && !all.hasMore)
        await coordinator.search(SearchQuery(text: "matrix", filter: .files), now: true)
        #expect(await settled(coordinator) { !$0.isLoading }.hits.map(\.body) == ["matrix 5"])
        await coordinator.clear()
        #expect(await coordinator.snapshot == .empty)
    }

    @Test("a late answer to an earlier query is never shown as the new query's (GA-32)")
    func lateAnswer() async throws {
        let port = FakeSearchPort(corpus: [try hit(1, "old result"), try hit(2, "new result")])
        port.hold("old")
        let coordinator = SearchCoordinator(port: port, sleep: { _ in })
        await coordinator.search(SearchQuery(text: "old"), now: true)
        while !port.isHolding("old") { await Task.yield() }
        await coordinator.search(SearchQuery(text: "new"), now: true)
        let answer = await settled(coordinator) { !$0.isLoading }
        #expect(answer.query.text == "new" && answer.hits.map(\.body) == ["new result"])
        port.release("old")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await coordinator.snapshot == answer)
        // The same for a query that was cleared meanwhile.
        port.hold("old")
        await coordinator.search(SearchQuery(text: "old"), now: true)
        while !port.isHolding("old") { await Task.yield() }
        await coordinator.clear()
        port.release("old")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await coordinator.snapshot == .empty)
    }

    @Test("two requests for the next page load one page, and none after a new query (GA-32)")
    func oneNextPage() async throws {
        let port = FakeSearchPort(corpus: try (1...9).map { try hit($0, "word \($0)") }, pageSize: 2)
        let coordinator = SearchCoordinator(port: port, sleep: { _ in })
        await coordinator.search(SearchQuery(text: "word"), now: true)
        _ = await settled(coordinator) { !$0.isLoading }
        port.hold("word")
        async let first: Void = coordinator.loadMore()
        while !port.isHolding("word") { await Task.yield() }
        await coordinator.loadMore()
        #expect(port.queries.count == 2)
        port.release("word")
        await first
        #expect(await coordinator.snapshot.hits.count == 4)
        port.hold("word")
        async let second: Void = coordinator.loadMore()
        while !port.isHolding("word") { await Task.yield() }
        await coordinator.search(SearchQuery(text: "word 1"), now: true)
        port.release("word")
        await second
        #expect(await settled(coordinator) { !$0.isLoading }.hits.map(\.body) == ["word 1"])
    }

    @Test("typing searches once, after the pause")
    func debounce() async throws {
        let port = FakeSearchPort(corpus: [try hit(1, "hello")])
        let gate = Gate()
        let coordinator = SearchCoordinator(port: port, sleep: { _ in try await gate.wait() })
        for text in ["h", "he", "hel"] { await coordinator.search(SearchQuery(text: text)) }
        while await gate.waiting < 1 { await Task.yield() }
        await gate.open()
        #expect(await settled(coordinator) { !$0.isLoading }.hits.count == 1)
        #expect(port.queries.map(\.text) == ["hel"])
    }

    @Test("a query without results finds what the index adds later, without a spinner")
    func refresh() async throws {
        let index = FakeSearchIndex(), source = FakeMessageIndexSource(), room = try RoomID("!a:x.org")
        let coordinator = SearchCoordinator(port: LocalMessageSearch(index: index, source: source, joined: { [room] }, ignored: { [] }), sleep: { _ in })
        await coordinator.search(SearchQuery(text: "later"), now: true)
        #expect(await settled(coordinator) { !$0.isLoading }.hits.isEmpty)
        await coordinator.refresh()
        try await index.apply([.live([.message(try FakeMessageIndexSource.entry(room, 1, "found later"))])])
        await coordinator.refresh()
        #expect(await coordinator.snapshot.hits.map(\.body) == ["found later"])
        await coordinator.clear()
        await coordinator.refresh()
        #expect(await coordinator.snapshot == .empty)
    }

    @Test("errors are reported with their query; a failed next page keeps the results")
    func failure() async throws {
        let port = FakeSearchPort(corpus: try (1...3).map { try hit($0, "word \($0)") }, pageSize: 2)
        let coordinator = SearchCoordinator(port: port, sleep: { _ in })
        port.failNext(with: .storage(.unavailable))
        await coordinator.search(SearchQuery(text: "word"), now: true)
        let failed = await settled(coordinator) { !$0.isLoading }
        #expect(failed.error == .storage(.unavailable) && failed.hits.isEmpty && !failed.hasMore)
        await coordinator.search(SearchQuery(text: "word"), now: true)
        _ = await settled(coordinator) { !$0.isLoading && $0.error == nil }
        port.failNext(with: .network(retryable: true))
        await coordinator.loadMore()
        let snapshot = await coordinator.snapshot
        #expect(snapshot.hits.count == 2 && snapshot.hasMore && snapshot.error == .network(retryable: true))
        await coordinator.loadMore()
        #expect(await coordinator.snapshot.hits.count == 3)
    }

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        var waiting: Int { continuations.count }
        func wait() async throws {
            if !isOpen { await withCheckedContinuation { continuations.append($0) } }
            try Task.checkCancellation()
        }
        func open() {
            isOpen = true
            for continuation in continuations { continuation.resume() }
            continuations = []
        }
    }
}
