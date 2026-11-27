import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("SearchIndexer", .timeLimit(.minutes(1)))
struct SearchIndexerTests {
    private final class Stage: Sendable {
        let index = FakeSearchIndex()
        let source = FakeMessageIndexSource()
        let rooms = Mutex<[RoomID]>([])
        let conditions = Mutex(SearchIndexPolicy.Conditions())
        let indexer: SearchIndexer

        init(rooms: [RoomID]) {
            let index = index, source = source
            let roomBox = RoomBox(rooms), conditionBox = ConditionBox()
            self.roomBox = roomBox
            self.conditionBox = conditionBox
            indexer = SearchIndexer(
                index: index, source: source, rooms: { roomBox.value.withLock { $0 } }, conditions: { conditionBox.value.withLock { $0 } },
                sleep: { duration in
                    // The idle waits would spin: only a cancelled (nudged) one ends at once.
                    if duration >= SearchIndexer.busyInterval, duration != SearchIndexer.settleDelay { try await Task.sleep(for: .seconds(60)) } else { await Task.yield() }
                })
        }
        let roomBox: RoomBox
        let conditionBox: ConditionBox
    }
    private final class RoomBox: Sendable {
        let value: Mutex<[RoomID]>
        init(_ rooms: [RoomID]) { value = Mutex(rooms) }
    }
    private final class ConditionBox: Sendable { let value = Mutex(SearchIndexPolicy.Conditions()) }

    private func room(_ name: String) throws -> RoomID { try RoomID("!\(name):x.org") }
    private func entries(_ room: RoomID, _ numbers: Range<Int>) throws -> [SearchIndexEntry] { try numbers.map { try FakeMessageIndexSource.entry(room, $0) } }

    private func wait(_ indexer: SearchIndexer, _ condition: (SearchIndexStatus) -> Bool) async -> SearchIndexStatus {
        for await status in await indexer.statuses() where condition(status) { return status }
        return SearchIndexStatus()
    }
    private func until(_ condition: () async -> Bool) async {
        while await !condition() { await Task.yield() }
    }

    @Test("reads every room back to its start, most recent room first, in slices, and says when it is done")
    func history() async throws {
        let a = try room("a"), b = try room("b")
        let stage = Stage(rooms: [a, b])
        stage.source.add(try entries(a, 0..<35), to: a)
        stage.source.add(try entries(b, 0..<3), to: b)
        await stage.indexer.begin()
        let status = await wait(stage.indexer) { $0.phase == .done }
        #expect(status.completeRooms == 2 && status.totalRooms == 2 && status.isComplete && status.statistics.messages == 38)
        #expect(stage.source.reads.map(\.room) == [a, a, a, a, b])
        #expect(stage.source.followed == [a, b])
        #expect(stage.source.batchesEnded >= 1, "what was loaded is let go at the end")
        await stage.indexer.stop()
        #expect(stage.source.isStopped)
    }

    @Test("a restart goes on where the last slice ended")
    func resume() async throws {
        let a = try room("a")
        let stage = Stage(rooms: [a])
        let all = try entries(a, 0..<100)
        stage.source.add(all, to: a)
        try await stage.index.apply([.slice(SearchHistorySlice(entries: Array(all[40...]), oldest: all[40].event), .history(a))])
        await stage.indexer.begin()
        _ = await wait(stage.indexer) { $0.phase == .done }
        #expect(stage.source.reads.first?.from == all[40].event)
        #expect(stage.index.bodies.count == 100)
    }

    @Test("what sync brings is written at once; a catch-up compares the touched rooms with the server and reads what is missing")
    func live() async throws {
        let a = try room("a"), b = try room("b")
        let stage = Stage(rooms: [a, b])
        stage.source.add(try entries(a, 0..<4), to: a)
        stage.source.add(try entries(b, 0..<4), to: b)
        await stage.indexer.begin()
        _ = await wait(stage.indexer) { $0.phase == .done }
        let before = stage.source.reads.count
        // Twenty messages while away; sync only brings the newest three of a, and two of b's two.
        let missedA = try entries(a, 4..<24), newB = try entries(b, 4..<6)
        stage.source.add(missedA, to: a)
        stage.source.add(newB, to: b)
        stage.source.yield(SearchLiveBatch(events: (missedA[17...] + newB).map { .message($0) }, touched: [a, b], isCatchUp: true))
        await until { stage.index.bodies.count == 24 }
        #expect(stage.source.reads.dropFirst(before).allSatisfy { $0.room == a }, "nothing missing in b")
        #expect(stage.source.reads.count > before)
    }

    @Test("edits, deletions, left rooms; rooms left while the app was closed")
    func changes() async throws {
        let a = try room("a"), b = try room("b"), gone = try room("gone")
        let stage = Stage(rooms: [a, b])
        stage.source.setJoined([a, b])
        try await stage.index.apply([.live([.message(try FakeMessageIndexSource.entry(gone, 1, "old room"))])])
        let one = try FakeMessageIndexSource.entry(a, 1, "one"), two = try FakeMessageIndexSource.entry(a, 2, "two"), three = try FakeMessageIndexSource.entry(b, 3, "three")
        await stage.indexer.begin()
        stage.source.yield(SearchLiveBatch(events: [.message(one), .message(two), .message(three)], touched: [a, b]))
        stage.source.yield(SearchLiveBatch(events: [.edit(a, target: one.event, sender: one.sender, SearchableContent(kind: .message, body: "one changed")), .removed(a, two.event)], touched: [a]))
        await until { stage.index.bodies == ["one changed", "three", "old room"] }
        stage.source.yield(SearchLiveBatch(events: [.message(try FakeMessageIndexSource.entry(b, 4, "last words"))], touched: [], left: [b], isCatchUp: true))
        await until { stage.index.bodies == ["one changed"] }
    }

    @Test("a room list that is still loading never removes a room's messages or stops listening")
    func partialList() async throws {
        let a = try room("a"), b = try room("b")
        let stage = Stage(rooms: [a, b])
        stage.source.setJoined([a, b])
        stage.source.add(try entries(a, 0..<3), to: a)
        stage.source.add(try entries(b, 0..<3), to: b)
        await stage.indexer.begin()
        _ = await wait(stage.indexer) { $0.phase == .done }
        stage.roomBox.value.withLock { $0 = [a] }
        stage.source.yield(SearchLiveBatch(events: [.message(try FakeMessageIndexSource.entry(a, 9, "marker"))], touched: [a], isCatchUp: true))
        await until { stage.index.bodies.contains("marker") }
        for _ in 0..<2_000 { await Task.yield() }
        #expect(try await stage.index.statistics().messages == 7)
    }

    @Test("stopping doesn't wait for a call that hangs")
    func stopsAtOnce() async throws {
        let a = try room("a")
        let stage = Stage(rooms: [a])
        stage.source.add(try entries(a, 0..<3), to: a)
        stage.source.hangReads()
        await stage.indexer.begin()
        await until { !stage.source.reads.isEmpty }
        await stage.indexer.stop()
        #expect(stage.source.isStopped)
    }

    @Test("pauses for the person, power, heat, mobile data; goes on when that ends", arguments: [SearchIndexPolicy.Pause.user, .lowPower, .hot, .mobileData, .offline, .background])
    func pauses(_ pause: SearchIndexPolicy.Pause) async throws {
        let a = try room("a")
        let stage = Stage(rooms: [a])
        stage.source.add(try entries(a, 0..<3), to: a)
        stage.conditionBox.value.withLock { conditions in
            switch pause {
            case .user: conditions.pausedByUser = true
            case .lowPower: conditions.lowPower = true
            case .hot: conditions.isHot = true
            case .mobileData: conditions.onMobileData = true
            case .offline: conditions.offline = true
            case .background: conditions.mayRun = false
            case .busy, .storageFull: break
            }
        }
        await stage.indexer.begin()
        _ = await wait(stage.indexer) { $0.phase == .paused(pause) }
        #expect(stage.source.reads.isEmpty)
        // Messages that arrive are still written.
        stage.source.yield(SearchLiveBatch(events: [.message(try FakeMessageIndexSource.entry(a, 9, "live"))], touched: [a]))
        await until { stage.index.bodies.contains("live") }
        stage.conditionBox.value.withLock { $0 = .init() }
        await until {
            await stage.indexer.conditionsChanged()
            return await stage.indexer.status.phase == .done
        }
    }

    @Test("a room the server doesn't give is left out; a network error tries again later and loses nothing")
    func errors() async throws {
        let a = try room("a"), b = try room("b")
        let stage = Stage(rooms: [a, b])
        stage.source.add(try entries(a, 0..<3), to: a)
        stage.source.add(try entries(b, 0..<3), to: b)
        stage.source.fail(a, with: .forbidden)
        await stage.indexer.begin()
        let status = await wait(stage.indexer) { $0.phase == .done }
        #expect(status.completeRooms == 2 && stage.index.bodies.count == 3)

        let offline = Stage(rooms: [a])
        offline.source.add(try entries(a, 0..<3), to: a)
        offline.source.fail(a, with: .network(retryable: true))
        await offline.indexer.begin()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(offline.index.bodies.isEmpty)
        offline.source.fail(a, with: nil)
        await until {
            await offline.indexer.conditionsChanged()
            return await offline.indexer.status.phase == .done
        }
        #expect(offline.index.bodies.count == 3)
    }

    @Test("keys that arrive make older messages searchable without opening the room (AC-SRCH-1, AC-SRCH-2)")
    func keys() async throws {
        let a = try room("a")
        let stage = Stage(rooms: [a])
        stage.source.add(try entries(a, 0..<3), to: a, readable: false)
        await stage.indexer.begin()
        let status = await wait(stage.indexer) { $0.phase == .done }
        #expect(status.statistics.undecryptable == 3 && stage.index.bodies.isEmpty)
        stage.source.makeReadable(a)
        await stage.indexer.keysArrived()
        await until { stage.index.bodies.count == 3 }
    }

    @Test("a failed write of a sync response is made up for from the server")
    func failedWrite() async throws {
        let a = try room("a")
        let stage = Stage(rooms: [a])
        stage.source.add(try entries(a, 0..<3), to: a)
        await stage.indexer.begin()
        _ = await wait(stage.indexer) { $0.phase == .done }
        stage.index.fail(with: .storage(.unavailable))
        let new = try FakeMessageIndexSource.entry(a, 3, "while full")
        stage.source.add([new], to: a)
        stage.source.yield(SearchLiveBatch(events: [.message(new)], touched: [a]))
        for _ in 0..<2_000 { await Task.yield() }
        stage.index.fail(with: nil)
        await until {
            await stage.indexer.conditionsChanged()
            return stage.index.bodies.contains("while full")
        }
    }

    @Test("clients are dropped after twenty rooms")
    func clients() async throws {
        let rooms = try (0..<45).map { try room("r\($0)") }
        let stage = Stage(rooms: rooms)
        for room in rooms { stage.source.add(try entries(room, 0..<2), to: room) }
        await stage.indexer.begin()
        _ = await wait(stage.indexer) { $0.phase == .done }
        #expect(stage.source.batchesEnded == 3)
    }

    @Test("an active search wakes remote history immediately, prioritizes the queried room, and streams hits progressively")
    func activeSearchStreamsRemoteHistoryFirst() async throws {
        let a = try room("a"), b = try room("b")
        let index = FakeSearchIndex(), source = FakeMessageIndexSource()
        source.add([try FakeMessageIndexSource.entry(a, 1, "needle in room a")], to: a)
        source.add([try FakeMessageIndexSource.entry(b, 1, "needle in room b")], to: b)
        let coordinator = SearchCoordinator(
            port: LocalMessageSearch(index: index, source: source, joined: { [a, b] }, ignored: { [] }),
            sleep: { _ in })
        let indexer = SearchIndexer(
            index: index, source: source, rooms: { [a, b] }, conditions: { .init() },
            onWrite: { changed in await coordinator.refresh(in: changed) },
            sleep: { duration in
                // Settle delay would sleep 60 s unless cancelled by `setActiveQuery`!
                if duration == SearchIndexer.settleDelay { try await Task.sleep(for: .seconds(60)) } else { await Task.yield() }
            })
        await indexer.begin()
        await indexer.noteActivity()  // simulate prior navigation busy state

        // Search scoped to room `b`: local index is empty at first, then `setActiveQuery` cancels settleDelay and indexes `b` BEFORE `a`!
        let scoped = SearchQuery(text: "needle", room: b)
        await coordinator.search(scoped, now: true)
        await indexer.setActiveQuery(scoped)

        await until { await coordinator.snapshot.hits.map(\.body) == ["needle in room b"] }
        #expect(source.reads.first?.room == b)
        await indexer.stop()
    }
}

@Suite("LocalMessageSearch", .timeLimit(.minutes(1)))
struct LocalMessageSearchTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func stage(_ count: Int, checkedAt: Date = Date(timeIntervalSince1970: 0), ignored: Set<UserID> = [], joined: Bool = true, sleep: @escaping SearchCoordinator.Sleep = { _ in try await Task.sleep(for: .seconds(60)) }) async throws
        -> (LocalMessageSearch, FakeSearchIndex, FakeMessageIndexSource, RoomID) {
        let room = try RoomID("!a:x.org")
        let index = FakeSearchIndex(), source = FakeMessageIndexSource()
        index.setCheckedAt(checkedAt)
        try await index.apply([.live(try (0..<count).map { .message(try FakeMessageIndexSource.entry(room, $0, "word \($0)")) })])
        let now = now
        return (LocalMessageSearch(index: index, source: source, joined: { joined ? [room] : [] }, ignored: { ignored }, now: { now }, sleep: sleep), index, source, room)
    }

    @Test("pages newest first, every row once")
    func pages() async throws {
        let (search, _, source, _) = try await stage(60)
        var bodies: [String] = [], cursor: SearchCursor?, pages = 0
        repeat {
            let page = try await search.search(SearchQuery(text: "word"), after: cursor)
            bodies += page.hits.map(\.body)
            cursor = page.next
            pages += 1
        } while cursor != nil
        #expect(bodies == (0..<60).reversed().map { "word \($0)" } && pages == 3)
        #expect(source.rechecked.count == 60)
    }

    @Test("deleted messages are never shown and leave the index; edited ones show their new text (AC-SRCH-6)")
    func rechecks() async throws {
        let (search, index, source, room) = try await stage(3)
        source.set(.gone, for: try FakeMessageIndexSource.entry(room, 2).event)
        source.set(.edited(SearchableContent(kind: .message, body: "word changed")), for: try FakeMessageIndexSource.entry(room, 1).event)
        #expect(try await search.search(SearchQuery(text: "word"), after: nil).hits.map(\.body) == ["word changed", "word 0"])
        #expect(!index.bodies.contains("word 2"))
    }

    @Test("a page whose rows are all gone goes on to the next")
    func emptyPage() async throws {
        let (search, _, source, room) = try await stage(30)
        for number in 5..<30 { source.set(.gone, for: try FakeMessageIndexSource.entry(room, number).event) }
        #expect(try await search.search(SearchQuery(text: "word"), after: nil).hits.count == 5)
    }

    @Test("ignored people and rooms that aren't joined are left out")
    func hidden() async throws {
        let (search, _, _, _) = try await stage(3, ignored: [try UserID("@bob:x.org")])
        #expect(try await search.search(SearchQuery(text: "word"), after: nil).hits.isEmpty)
        let (other, _, _, _) = try await stage(3, joined: false)
        #expect(try await other.search(SearchQuery(text: "word"), after: nil).hits.isEmpty)
    }

    @Test("without a network the index's rows are shown after a moment, not held back; fresh rows aren't asked about again")
    func offline() async throws {
        let (failing, _, source, _) = try await stage(3)
        source.failRechecks(with: .network(retryable: true))
        #expect(try await failing.search(SearchQuery(text: "word"), after: nil).hits.count == 3)
        let (hanging, _, hung, _) = try await stage(30, sleep: { _ in })
        hung.hangRechecks()
        #expect(try await hanging.search(SearchQuery(text: "word"), after: nil).hits.count == 25)
        let (fresh, _, asked, _) = try await stage(3, checkedAt: now.addingTimeInterval(-60))
        #expect(try await fresh.search(SearchQuery(text: "word"), after: nil).hits.count == 3 && asked.rechecked.isEmpty)
    }

    @Test("a query without a word is empty, without an error (AC-SRCH-7)")
    func nothing() async throws {
        let (search, _, _, _) = try await stage(3)
        for query in ["", "***", "()", "😀"] { #expect(try await search.search(SearchQuery(text: query), after: nil) == SearchPage(hits: [], next: nil)) }
    }

    @Test("searchLocal returns immediately without waiting for hanging remote rechecks, and cancelling recheck exits at once")
    func instantLocalAndCancellableRecheck() async throws {
        let (search, _, hung, _) = try await stage(5, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        hung.hangRechecks()
        // `searchLocal` never touches remote `recheck`, returning all 5 cached hits immediately.
        let local = try await search.searchLocal(SearchQuery(text: "word"), after: nil)
        #expect(local.hits.count == 5 && hung.rechecked.isEmpty)

        // Cancelling a background `recheck` finishes immediately instead of waiting for `recheckTimeout` (60 s here).
        let task = Task { try await search.recheck(local.hits) }
        while hung.rechecked.isEmpty { await Task.yield() }
        task.cancel()
        let deltas = (try? await task.value) ?? [:]
        #expect(deltas.isEmpty)
    }
}

@Suite("SearchStartGate", .timeLimit(.minutes(1)))
struct SearchStartGateTests {
    @Test("waits until opened, or until patience ends")
    func gate() async {
        let patient = SearchStartGate(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        async let waiting: Void = patient.wait()
        for _ in 0..<100 { await Task.yield() }
        await patient.open()
        await waiting
        await patient.wait()
        let impatient = SearchStartGate(sleep: { _ in })
        await impatient.wait()
    }
}
