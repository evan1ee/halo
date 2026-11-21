import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPersistence

@Suite("BotTaskStore")
struct BotTaskStoreTests {
    private let room = try! RoomID("!r:x.org")

    private func database() throws -> HaloDatabase {
        try HaloDatabase(path: FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(UUID().uuidString).sqlite").path)
    }

    private func entry(_ id: String, title: String = "t", status: BotTaskEntry.Status = .open, source: String? = "$s", at: TimeInterval) throws -> BotTaskEntry {
        BotTaskEntry(
            key: .init(room: room, bot: "@bot:x.org", kind: .todo, id: id), title: title, status: status,
            sourceEventID: try source.map { try EventID($0) }, asOf: Date(timeIntervalSince1970: at), detail: "owner")
    }

    @Test("entries round-trip, newest first")
    func roundTrip() async throws {
        let store = BotTaskStore(database: try database(), account: try UserID("@a:x.org"))
        try await store.upsert([try entry("1", at: 10), try entry("2", title: "second", at: 20)])
        let all = try await store.entries()
        #expect(all.map(\.key.id) == ["2", "1"] && all[0].title == "second" && all[0].detail == "owner" && all[1].sourceEventID?.rawValue == "$s")
        #expect(all[0].asOf == Date(timeIntervalSince1970: 20))
    }

    @Test("an older entry never replaces a newer one; an equal or newer one does; a missing source keeps the stored one; repeats change nothing")
    func monotonic() async throws {
        let store = BotTaskStore(database: try database(), account: try UserID("@a:x.org"))
        try await store.upsert([try entry("1", title: "new", status: .completed, at: 20)])
        try await store.upsert([try entry("1", title: "stale", status: .open, at: 10)])
        var stored = try await store.entries()
        #expect(stored.count == 1 && stored[0].title == "new" && stored[0].status == .completed)
        try await store.upsert([try entry("1", title: "newest", status: .deleted, source: nil, at: 30)])
        try await store.upsert([try entry("1", title: "newest", status: .deleted, source: nil, at: 30)])
        stored = try await store.entries()
        #expect(stored.count == 1 && stored[0].title == "newest" && stored[0].status == .deleted && stored[0].sourceEventID?.rawValue == "$s")
    }

    @Test("rows are scoped by account, and removeAll empties only the account's rows")
    func scopingAndRemoval() async throws {
        let db = try database()
        let a = BotTaskStore(database: db, account: try UserID("@a:x.org"))
        let b = BotTaskStore(database: db, account: try UserID("@b:x.org"))
        try await a.upsert([try entry("1", at: 1)])
        try await b.upsert([try entry("1", at: 1)])
        try await a.removeAll()
        #expect(try await a.entries().isEmpty)
        #expect(try await b.entries().count == 1)
    }

    @Test("prune deletes only the account's entries older than the cutoff")
    func pruning() async throws {
        let db = try database()
        let a = BotTaskStore(database: db, account: try UserID("@a:x.org"))
        let b = BotTaskStore(database: db, account: try UserID("@b:x.org"))
        try await a.upsert([try entry("old", at: 10), try entry("new", at: 100)])
        try await b.upsert([try entry("old", at: 10)])
        try await a.prune(before: Date(timeIntervalSince1970: 50))
        #expect(try await a.entries().map(\.key.id) == ["new"])
        #expect(try await b.entries().count == 1)
    }
}
