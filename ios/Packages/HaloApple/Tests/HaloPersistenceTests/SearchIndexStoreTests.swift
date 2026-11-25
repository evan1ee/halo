import Foundation
import GRDB
import HaloDomain
import HaloFoundation
import Synchronization
import Testing
@testable import HaloPersistence

@Suite("SearchIndexStore")
struct SearchIndexStoreTests {
    private final class Stage: Sendable {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-search-\(UUID().uuidString)")
        let clock = Mutex(Date(timeIntervalSince1970: 2_000_000))
        let readable = Mutex(true)
        let cipher: FieldCipher
        init() throws { cipher = try FieldCipher(keyData: Data(repeating: 7, count: 32)) }
        func store() -> SearchIndexStore {
            SearchIndexStore(directory: directory, cipher: cipher, isReadable: { self.readable.withLock { $0 } }, now: { self.clock.withLock { $0 } })
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private let roomA = "!a:x.org", roomB = "!b:x.org"

    private func entry(_ id: String, _ body: String, room: String = "!a:x.org", sender: String = "@bob:x.org", name: String? = "Bob", at: Double = 1000, kind: SearchKind = .message, thread: String? = nil) throws -> SearchIndexEntry {
        SearchIndexEntry(
            room: try RoomID(room), event: try EventID("$\(id)"), sender: try UserID(sender), senderName: name, threadRoot: try thread.map { try EventID($0) },
            timestamp: Date(timeIntervalSince1970: at), content: SearchableContent(kind: kind, body: body))
    }

    private func live(_ entries: SearchIndexEntry...) -> [SearchIndexOperation] { [.live(entries.map { .message($0) })] }

    private func find(_ store: SearchIndexStore, _ query: String, room: String? = nil, filter: SearchFilter = .all, excluding: Set<UserID> = [], after: SearchCursor? = nil, limit: Int = 30) async throws -> [SearchIndexHit] {
        guard let match = SearchTokeniser.matchExpression(query) else { return [] }
        return try await store.hits(match: match, room: try room.map { try RoomID($0) }, kinds: filter.kinds, excluding: excluding, after: after, limit: limit)
    }

    private func ids(_ hits: [SearchIndexHit]) -> [String] { hits.map(\.entry.event.rawValue) }

    @Test("finds words, CJK inside sentences, sender names; newest first (AC-SRCH-5)")
    func finds() async throws {
        let stage = try Stage(), store = stage.store()
        try await store.apply(live(
            try entry("1", "Das Café am Platz", at: 10), try entry("2", "今天去AppleStore", at: 30, thread: "$root"), try entry("3", "cafe again", room: roomB, sender: "@eve:x.org", name: "Eve Müller", at: 20)))
        #expect(ids(try await find(store, "cafe")) == ["$3", "$1"])
        for query in ["今天", "天去", "apple", "AppleStore"] { #expect(ids(try await find(store, query)) == ["$2"], "\(query)") }
        #expect(try await find(store, "天今").isEmpty)
        #expect(ids(try await find(store, "muller")) == ["$3"])
        #expect(try await find(store, "今天").first?.entry.threadRoot?.rawValue == "$root")
        #expect(ids(try await find(store, "cafe", room: roomA)) == ["$1"])
        #expect(ids(try await find(store, "cafe", excluding: [try UserID("@eve:x.org")])) == ["$1"])
    }

    @Test("no query is an error (AC-SRCH-7)", arguments: ["\"", "*", "a OR b", "NEAR(", "col:x", "-", "😀", "﷽", "x\" OR \"y", "ʰ", "ﾞ", "\u{0}", "²", "a AND", "{a b}", "^a", "a + b", "ඞ", "㍿", "\u{1E900}"])
    func safety(_ query: String) async throws {
        let stage = try Stage(), store = stage.store()
        try await store.apply(live(try entry("1", "x y z \(query)")))
        _ = try await find(store, query)
    }

    @Test("filters by kind and pages without repeating or missing rows with equal times")
    func filtersAndPages() async throws {
        let stage = try Stage(), store = stage.store()
        try await store.apply([.live(try (0..<25).map { .message(try entry("m\($0)", "same word", at: Double(100 + $0 / 10))) })])
        try await store.apply(live(try entry("f", "word.pdf", kind: .file), try entry("l", "word https://x", kind: .link), try entry("p", "word", kind: .media)))
        var seen: [String] = [], cursor: SearchCursor?
        repeat {
            let page = try await find(store, "same", after: cursor, limit: 7)
            seen += ids(page)
            cursor = page.count == 7 ? page.last?.cursor : nil
        } while cursor != nil
        #expect(seen.count == 25 && Set(seen).count == 25)
        #expect(ids(try await find(store, "word", filter: .files)) == ["$f"])
        #expect(ids(try await find(store, "word", filter: .links)) == ["$l"])
        #expect(ids(try await find(store, "word", filter: .media)) == ["$p"])
        #expect(try await find(store, "word", filter: .messages).count == 26)
    }

    @Test("edits by the sender only, deletions, the same message twice, a wrong clock")
    func changes() async throws {
        let stage = try Stage(), store = stage.store()
        try await store.apply(live(try entry("1", "first words"), try entry("2", "from the future", at: 9e9)))
        try await store.apply(live(try entry("1", "first words")))
        let room = try RoomID(roomA), bob = try UserID("@bob:x.org"), target = try EventID("$1")
        try await store.apply([.live([.edit(room, target: target, sender: try UserID("@eve:x.org"), SearchableContent(kind: .message, body: "hacked"))])])
        #expect(try await find(store, "hacked").isEmpty)
        try await store.apply([.live([.edit(room, target: target, sender: bob, SearchableContent(kind: .message, body: "second version"))])])
        let found1 = try await find(store, "first"), found2 = try await find(store, "second")
        #expect(found1.isEmpty && found2.count == 1)
        #expect(try await find(store, "bob").count == 2, "the sender's name is still found")
        #expect(try await find(store, "future").first?.entry.timestamp == Date(timeIntervalSince1970: 2_000_000))
        try await store.apply([.live([.removed(room, target)])])
        #expect(try await find(store, "second").isEmpty)
        #expect(try await store.statistics().messages == 1)
    }

    @Test("deleted text leaves the file")
    func secureDelete() async throws {
        let stage = try Stage(), store = stage.store()
        try await store.apply(live(try entry("1", "verysecretword")))
        try await store.apply([.live([.removed(try RoomID(roomA), try EventID("$1"))])])
        await store.suspend(rooms: [])  // closes, which checkpoints the log into the file
        let data = try Data(contentsOf: stage.directory.appendingPathComponent("search-index.sqlite"))
        #expect(data.range(of: Data("verysecretword".utf8)) == nil)
    }

    @Test("history: position after each slice, complete at the start, blocked when it can't go on")
    func history() async throws {
        let stage = try Stage(), store = stage.store()
        let a = try RoomID(roomA), b = try RoomID(roomB)
        #expect(try await store.nextWork(rooms: [a, b], limit: 5) == [.start(a), .start(b)])
        let first = SearchHistorySlice(entries: [try entry("2", "two", at: 20), try entry("3", "three", at: 30)], undecryptable: [try EventID("$u")], oldest: try EventID("$2"), oldestTime: Date(timeIntervalSince1970: 20))
        try await store.apply([.slice(first, .history(a))])
        #expect(try await store.nextWork(rooms: [a, b], limit: 5) == [.history(a, before: try EventID("$2")), .start(b)])
        #expect(try await store.coverage()[a]?.oldest == Date(timeIntervalSince1970: 20))
        #expect(try await store.statistics().undecryptable == 1)
        // The same slice again (the app was killed after it): nothing twice.
        try await store.apply([.slice(first, .history(a))])
        #expect(try await store.coverage()[a]?.state == .blocked, "no progress")
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("1", "one", at: 10)], oldest: try EventID("$1"), reachedStart: true), .history(a))])
        #expect(try await store.coverage()[a]?.state == .complete)
        #expect(try await store.nextWork(rooms: [a, b], limit: 5) == [.start(b)])
        try await store.apply([.blocked(b)])
        #expect(try await store.nextWork(rooms: [a, b], limit: 5).isEmpty)
        #expect(try await store.statistics().messages == 3)
    }

    @Test("a room with possibly missed messages is checked, then read back to a known one")
    func gaps() async throws {
        let stage = try Stage(), store = stage.store()
        let a = try RoomID(roomA)
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("1", "one")], oldest: try EventID("$1"), reachedStart: true), .history(a))])
        try await store.apply([.check([a, try RoomID("!never:x.org")])])
        #expect(try await store.nextWork(rooms: [a], limit: 5) == [.check(a)])
        #expect(try await store.known([try EventID("$1"), try EventID("$9")], in: a) == [try EventID("$1")])
        try await store.apply([.checked(a, gapFrom: try EventID("$9"))])
        #expect(try await store.nextWork(rooms: [a], limit: 5) == [.gap(a, before: try EventID("$9"))])
        // Not there yet: the next slice goes on from its oldest event.
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("8", "eight"), try entry("9", "nine")], other: [try EventID("$s")], oldest: try EventID("$8")), .gap(a, before: try EventID("$9")))])
        #expect(try await store.nextWork(rooms: [a], limit: 5) == [.gap(a, before: try EventID("$8"))])
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("1", "one"), try entry("7", "seven"), try entry("8", "eight")], oldest: try EventID("$1")), .gap(a, before: try EventID("$8")))])
        #expect(try await store.nextWork(rooms: [a], limit: 5).isEmpty)
        #expect(try await store.coverage()[a]?.state == .complete)
        #expect(try await store.known([try EventID("$s"), try EventID("$7")], in: a).count == 2)
    }

    @Test("a message without a key is asked for again, later each time, and found once its key is there (AC-SRCH-2)")
    func keys() async throws {
        let stage = try Stage(), store = stage.store()
        let a = try RoomID(roomA), u = try EventID("$u")
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("1", "one")], undecryptable: [u], oldest: try EventID("$1"), reachedStart: true), .history(a))])
        #expect(try await store.nextWork(rooms: [a], limit: 5).isEmpty)
        stage.clock.withLock { $0 += 61 }
        #expect(try await store.nextWork(rooms: [a], limit: 5) == [.retry(a, around: u)])
        try await store.apply([.slice(SearchHistorySlice(undecryptable: [u], oldest: u), .retry(a, around: u))])
        stage.clock.withLock { $0 += 61 }
        #expect(try await store.nextWork(rooms: [a], limit: 5).isEmpty)
        try await store.retryUndecryptableNow()
        #expect(try await store.nextWork(rooms: [a], limit: 5) == [.retry(a, around: u)])
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("u", "now readable")], oldest: u), .retry(a, around: u))])
        #expect(try await store.nextWork(rooms: [a], limit: 5).isEmpty)
        #expect(ids(try await find(store, "readable")) == ["$u"])
        #expect(try await store.statistics().undecryptable == 0)
        #expect(try await store.coverage()[a]?.state == .complete, "a retry doesn't move the room's position")
    }

    @Test("the SDK's answer about shown rows: changed, gone, or the same")
    func rechecks() async throws {
        let stage = try Stage(), store = stage.store()
        let a = try RoomID(roomA)
        try await store.apply(live(try entry("1", "stays"), try entry("2", "changes"), try entry("3", "goes")))
        stage.clock.withLock { $0 += 5000 }
        try await store.record([(a, try EventID("$1"), .unchanged), (a, try EventID("$2"), .edited(SearchableContent(kind: .message, body: "different"))), (a, try EventID("$3"), .gone)])
        #expect(try await find(store, "stays").first?.checkedAt == Date(timeIntervalSince1970: 2_005_000))
        let changed = try await find(store, "changes"), different = try await find(store, "different"), goes = try await find(store, "goes")
        #expect(changed.isEmpty && different.count == 1 && goes.isEmpty)
    }

    @Test("left rooms, clearing, and nothing left after destroying (AC-SRCH-6, AC-SRCH-8)")
    func removal() async throws {
        let stage = try Stage(), store = stage.store()
        try await store.apply(live(try entry("1", "word"), try entry("2", "word", room: roomB)))
        #expect(try await store.indexedRooms().count == 2)
        try await store.apply([.live(try (0..<250).map { .message(try entry("many\($0)", "word", room: roomB)) })])
        try await store.apply([.removeRooms([try RoomID(roomB)])])
        #expect(ids(try await find(store, "word")) == ["$1"])
        #expect(try await store.indexedRooms() == [try RoomID(roomA)])
        try await store.clear()
        #expect(try await find(store, "word").isEmpty)
        #expect(try await store.indexedRooms().isEmpty)
        store.destroy()
        #expect(!FileManager.default.fileExists(atPath: stage.directory.path))
    }

    @Test("while locked: nothing readable, writes are held encrypted, planned work goes on, all of it arrives after unlocking")
    func locked() async throws {
        let stage = try Stage(), store = stage.store()
        let a = try RoomID(roomA), b = try RoomID(roomB)
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("5", "five")], oldest: try EventID("$5")), .history(a))])
        await store.suspend(rooms: [a, b])
        stage.readable.withLock { $0 = false }
        await #expect(throws: HaloError.storage(.unavailable)) { _ = try await find(store, "five") }
        #expect(try await store.nextWork(rooms: [a, b], limit: 5) == [.history(a, before: try EventID("$5")), .start(b)])
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("4", "fourplain")], oldest: try EventID("$4")), .history(a))])
        try await store.apply([.slice(SearchHistorySlice(entries: [try entry("b", "other", room: roomB)], oldest: try EventID("$b"), reachedStart: true), .history(b))])
        try await store.apply(live(try entry("6", "six")))
        #expect(try await store.nextWork(rooms: [a, b], limit: 5) == [.history(a, before: try EventID("$4"))])
        for name in ["search-holding", "search-plan"] {
            let data = try Data(contentsOf: stage.directory.appendingPathComponent(name))
            #expect(data.range(of: Data("fourplain".utf8)) == nil && data.range(of: Data("x.org".utf8)) == nil)
        }
        // Another process start, still locked, then unlocked.
        let later = stage.store()
        #expect(try await later.nextWork(rooms: [a, b], limit: 5) == [.history(a, before: try EventID("$4"))])
        stage.readable.withLock { $0 = true }
        for word in ["fourplain", "other", "six"] { #expect(try await find(later, word).count == 1, "\(word)") }
        #expect(try await later.coverage()[b]?.state == .complete)
        #expect(!FileManager.default.fileExists(atPath: stage.directory.appendingPathComponent("search-holding").path))
    }

    @Test("a file that can't be opened now is kept, not deleted, and what arrives meanwhile is held")
    func refusedOpen() async throws {
        let stage = try Stage()
        var store = stage.store()
        try await store.apply(live(try entry("1", "precious")))
        await store.suspend(rooms: [])
        let path = stage.directory.appendingPathComponent("search-index.sqlite").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)  // as iOS refuses a protected file while locked
        store = stage.store()
        await #expect(throws: HaloError.storage(.unavailable)) { _ = try await store.statistics() }
        try await store.apply(live(try entry("2", "while locked")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try await find(store, "precious").count == 1)
        #expect(try await find(store, "locked").count == 1)
    }

    @Test("a damaged file and one of another version are replaced by an empty index")
    func rebuild() async throws {
        let stage = try Stage()
        var store = stage.store()
        try await store.apply(live(try entry("1", "word")))
        await store.suspend(rooms: [])
        let path = stage.directory.appendingPathComponent("search-index.sqlite")
        do {
            let queue = try DatabaseQueue(path: path.path)
            try await queue.write { try $0.execute(sql: "PRAGMA user_version = 99") }
            try queue.close()
        }
        store = stage.store()
        #expect(try await store.statistics().messages == 0)
        await store.suspend(rooms: [])
        try Data(repeating: 1, count: 9000).write(to: path)
        store = stage.store()
        #expect(try await store.statistics().messages == 0)
        try await store.apply(live(try entry("1", "word")))
        #expect(try await find(store, "word").count == 1)
    }
}
