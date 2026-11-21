import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPersistence

@Suite("DraftStore")
struct DraftStoreTests {
    private let room = try! RoomID("!r:x.org")

    private func database() throws -> HaloDatabase {
        try HaloDatabase(path: FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(UUID().uuidString).sqlite").path, observesSuspensionNotifications: false)
    }

    @Test("a draft is stored, replaced, and deleted by blank text")
    func roundTrip() async throws {
        let store = DraftStore(database: try database(), account: try UserID("@a:x.org"))
        #expect(try await store.draft(for: room) == nil)
        try await store.save("hello", for: room)
        try await store.save("hello world", for: room)
        #expect(try await store.draft(for: room) == "hello world")
        try await store.save("  \n", for: room)
        #expect(try await store.draft(for: room) == nil)
    }

    @Test("drafts are scoped by account and room")
    func scoping() async throws {
        let db = try database()
        let a = DraftStore(database: db, account: try UserID("@a:x.org"))
        let b = DraftStore(database: db, account: try UserID("@b:x.org"))
        try await a.save("mine", for: room)
        #expect(try await b.draft(for: room) == nil)
        #expect(try await a.draft(for: try RoomID("!other:x.org")) == nil)
    }
}
