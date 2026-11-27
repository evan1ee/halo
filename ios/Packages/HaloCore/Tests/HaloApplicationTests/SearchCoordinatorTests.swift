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

    @Test("local results appear immediately on every keystroke while remote verification runs once after typing pauses")
    func debounce() async throws {
        let port = FakeSearchPort(corpus: [try hit(1, "hello")])
        let gate = Gate()
        var remoteQueries: [SearchQuery?] = []
        let remoteRecorder = QueryRecorder()
        let coordinator = SearchCoordinator(
            port: port,
            onRemoteQuery: { await remoteRecorder.record($0) },
            sleep: { _ in try await gate.wait() })
        for text in ["h", "he", "hel"] { await coordinator.search(SearchQuery(text: text)) }
        // Local cached hits are already shown BEFORE the typing-pause gate opens!
        let immediate = await settled(coordinator) { !$0.isLoading && $0.query.text == "hel" }
        #expect(immediate.hits.map(\.body) == ["hello"])
        #expect(port.recheckBatches.isEmpty)
        while await gate.waiting < 1 { await Task.yield() }
        await gate.open()
        while port.recheckBatches.isEmpty { await Task.yield() }
        remoteQueries = await remoteRecorder.values
        // Outdated remote passes for "h" and "he" were cancelled; only "hel" triggered remote work!
        #expect(port.recheckBatches.count == 1)
        #expect(remoteQueries == [SearchQuery(text: "hel")])
    }

    @Test("local hits appear immediately while slow remote verification runs in the background, and edits/deletions update in place without losing paged rows")
    func progressiveLocalThenRemoteVerification() async throws {
        let hits = try (1...4).map { try hit($0, "item \($0)") }
        let port = FakeSearchPort(corpus: hits, pageSize: 2)
        // item 4 will be reported deleted remotely; item 3 will be reported edited remotely.
        port.setRemoteRecheck(.gone, for: hits[3].id)
        port.setRemoteRecheck(.edited(SearchableContent(kind: .message, body: "item 3 (edited)")), for: hits[2].id)
        port.holdRechecks()

        let coordinator = SearchCoordinator(port: port, sleep: { _ in })
        await coordinator.search(SearchQuery(text: "item"), now: true)

        // Page 1 cached hits appear immediately without waiting for the held remote server check.
        let instant = await settled(coordinator) { !$0.isLoading && !$0.hits.isEmpty }
        #expect(instant.hits.map(\.body) == ["item 4", "item 3"] && instant.hasMore)
        while !port.isHoldingRecheck { await Task.yield() }

        // User scrolls and loads page 2 while page 1's remote verification is still in flight!
        await coordinator.loadMore()
        #expect(await coordinator.snapshot.hits.map(\.body) == ["item 4", "item 3", "item 2", "item 1"])

        // Remote verification completes: item 4 is removed, item 3 is updated, and page 2's rows are preserved!
        port.releaseRechecks()
        let updated = await settled(coordinator) { $0.hits.count == 3 }
        #expect(updated.hits.map(\.body) == ["item 3 (edited)", "item 2", "item 1"])
    }

    @Test("a stale remote recheck from an outdated query never overwrites newer search results")
    func staleRemoteRecheckIgnored() async throws {
        let oldHit = try hit(1, "alpha old")
        let newHit = try hit(2, "beta new")
        let port = FakeSearchPort(corpus: [oldHit, newHit])
        port.setRemoteRecheck(.edited(SearchableContent(kind: .message, body: "alpha mutated")), for: oldHit.id)
        port.holdRechecks()

        let coordinator = SearchCoordinator(port: port, sleep: { _ in })
        await coordinator.search(SearchQuery(text: "alpha"), now: true)
        _ = await settled(coordinator) { !$0.isLoading && $0.query.text == "alpha" }
        while !port.isHoldingRecheck { await Task.yield() }

        // Switch query before old remote recheck finishes.
        await coordinator.search(SearchQuery(text: "beta"), now: true)
        let beta = await settled(coordinator) { !$0.isLoading && $0.query.text == "beta" }
        #expect(beta.hits.map(\.body) == ["beta new"])

        port.releaseRechecks()
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await coordinator.snapshot.hits.map(\.body) == ["beta new"])
    }

    @Test("progressive index refresh merges newer remote hits even when hasMore is true and preserves loadMore pages")
    func refreshMergesAcrossPagesAndHasMore() async throws {
        let index = FakeSearchIndex(), source = FakeMessageIndexSource(), room = try RoomID("!a:x.org")
        index.setCheckedAt(Date())
        // Seed 30 cached messages (> pageSize 25, so hasMore == true).
        try await index.apply([.live(try (1...30).map { .message(try FakeMessageIndexSource.entry(room, $0, "topic \($0)")) })])
        let coordinator = SearchCoordinator(
            port: LocalMessageSearch(index: index, source: source, joined: { [room] }, ignored: { [] }),
            sleep: { _ in })

        await coordinator.search(SearchQuery(text: "topic"), now: true)
        let firstPage = await settled(coordinator) { !$0.isLoading && $0.hits.count == 25 }
        #expect(firstPage.hasMore && firstPage.hits.first?.body == "topic 30")

        // Even with hasMore == true, a newly indexed remote message appears at the top on refresh!
        try await index.apply([.live([.message(try FakeMessageIndexSource.entry(room, 31, "topic 31"))])])
        await coordinator.refresh(in: [room])
        let afterRefresh = await coordinator.snapshot
        #expect(afterRefresh.hits.first?.body == "topic 31")
        #expect(afterRefresh.hits.count == 25 && afterRefresh.hasMore)

        // Load second page (total 31 hits), then receive a live edit + another remote message: no truncation back to 25!
        await coordinator.loadMore()
        #expect(await coordinator.snapshot.hits.count == 31)
        let editedTarget = try FakeMessageIndexSource.entry(room, 30)
        try await index.apply([.live([
            .edit(room, target: editedTarget.event, sender: editedTarget.sender, SearchableContent(kind: .message, body: "topic 30 updated")),
            .message(try FakeMessageIndexSource.entry(room, 32, "topic 32")),
        ])])
        await coordinator.refresh(in: [room])
        let merged = await coordinator.snapshot
        #expect(merged.hits.count >= 31)
        #expect(merged.hits[0].body == "topic 32" && merged.hits[1].body == "topic 31" && merged.hits[2].body == "topic 30 updated")
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

    private actor QueryRecorder {
        var values: [SearchQuery?] = []
        func record(_ query: SearchQuery?) { values.append(query) }
    }
}
