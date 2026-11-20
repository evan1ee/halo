import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPersistence

@Suite("ReadIntentStore")
struct ReadIntentStoreTests {
    private let room = try! RoomID("!r:x.org")
    private func e(_ n: Int) -> EventID { try! EventID("$e\(n)") }
    private func t(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n)) }

    private func store(_ account: String = "@a:x.org") throws -> ReadIntentStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(UUID().uuidString).sqlite").path
        return ReadIntentStore(database: try HaloDatabase(path: path), account: try UserID(account))
    }

    @Test("an intent only moves forward and a sent intent never goes back to pending")
    func monotonic() async throws {
        let store = try store()
        try await store.save(ReadIntent(room: room, event: e(2), timestamp: t(20), createdAt: t(100)))
        try await store.save(ReadIntent(room: room, event: e(1), timestamp: t(10), createdAt: t(101)))
        #expect(try await store.all().map(\.event) == [e(2)])
        try await store.save(ReadIntent(room: room, event: e(2), timestamp: t(20), isSent: true, createdAt: t(100)))
        try await store.save(ReadIntent(room: room, event: e(2), timestamp: t(20), isSent: false, createdAt: t(102)))
        #expect(try await store.all().first?.isSent == true)
        try await store.save(ReadIntent(room: room, event: e(3), timestamp: t(30), createdAt: t(103)))
        let intent = try #require(try await store.all().first)
        #expect(intent.event == e(3) && intent.isSent == false && intent.timestamp == t(30))
    }

    /// P8 (UNREAD_REGRESSION_TESTS §2): concurrent upserts, in a seeded random order, never leave a room behind its newest intent.
    @Test("P8: concurrent upserts end at the newest intent")
    func concurrentUpserts() async throws {
        for seed in UInt64(1)...25 {
            let store = try store()
            var rng = SeededRandomNumberGenerator(seed: seed)
            let order = Array(1...30).shuffled(using: &rng)
            await withTaskGroup(of: Void.self) { group in
                for n in order {
                    group.addTask {
                        try? await store.save(ReadIntent(room: room, event: e(n), timestamp: t(n), createdAt: t(100 + n)))
                    }
                }
            }
            let intent = try #require(try await store.all().first, "seed \(seed)")
            #expect(intent.event == e(30) && intent.timestamp == t(30), "seed \(seed)")
        }
    }

    @Test("sent intents expire, unsent ones never do")
    func expiry() async throws {
        let store = try store()
        let other = try RoomID("!o:x.org")
        try await store.save(ReadIntent(room: room, event: e(1), timestamp: t(1), isSent: true, createdAt: t(10)))
        try await store.save(ReadIntent(room: other, event: e(2), timestamp: t(2), createdAt: t(10)))
        try await store.removeSent(createdBefore: t(50))
        #expect(try await store.all().map(\.room) == [other])
    }

    @Test("rows are scoped by account")
    func accounts() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(UUID().uuidString).sqlite").path
        let db = try HaloDatabase(path: path)
        let a = ReadIntentStore(database: db, account: try UserID("@a:x.org"))
        let b = ReadIntentStore(database: db, account: try UserID("@b:x.org"))
        try await a.save(ReadIntent(room: room, event: e(1), timestamp: t(1), createdAt: t(1)))
        #expect(try await b.all().isEmpty)
    }
}
