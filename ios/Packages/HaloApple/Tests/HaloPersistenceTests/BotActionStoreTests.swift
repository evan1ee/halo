import Foundation
import HaloFoundation
import HaloPersistence
import Testing

@Suite("BotActionStore (v9-bot-action, TD-08)")
struct BotActionStoreTests {
    private func makeStore() throws -> (BotActionStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-bot-action-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try HaloDatabase(path: dir.appendingPathComponent("halo.sqlite").path, observesSuspensionNotifications: false)
        return (BotActionStore(database: db), dir)
    }

    @Test("pending bot action survives reopen and ignores stale updates monotonically")
    func roundTripAndMonotonicUpsert() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let alice = try UserID("@alice:example.org")
        let bot = try UserID("@todo:example.org")
        let room = try RoomID("!room:example.org")

        let initial = PendingBotActionRecord(roomID: room, botSender: bot, itemID: "42", state: .pending, updatedAtMillis: 1000)
        try store.upsert(initial, account: alice)
        #expect(try store.all(account: alice, roomID: room) == [initial])

        // Newer update transitions to noResponse
        let timedOut = PendingBotActionRecord(roomID: room, botSender: bot, itemID: "42", state: .noResponse, updatedAtMillis: 2000)
        try store.upsert(timedOut, account: alice)
        #expect(try store.all(account: alice, roomID: room) == [timedOut])

        // Stale update is ignored (monotonic upsert)
        let stale = PendingBotActionRecord(roomID: room, botSender: bot, itemID: "42", state: .pending, updatedAtMillis: 1500)
        try store.upsert(stale, account: alice)
        #expect(try store.all(account: alice, roomID: room) == [timedOut])

        // Delete clears the record once bot confirms completion
        try store.delete(roomID: room, botSender: bot, itemID: "42", account: alice)
        #expect(try store.all(account: alice, roomID: room).isEmpty)
    }
}
