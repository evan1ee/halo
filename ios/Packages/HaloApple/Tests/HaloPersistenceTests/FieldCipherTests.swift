import Foundation
import GRDB
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPersistence

private actor StubKeychain: KeychainPort {
    private var items: [KeychainItem: Data] = [:]

    func read(_ item: KeychainItem) async throws(HaloError) -> Data? { items[item] }
    func write(_ data: Data, for item: KeychainItem) async throws(HaloError) { items[item] = data }
    func delete(_ item: KeychainItem) async throws(HaloError) { items.removeValue(forKey: item) }
}

@Suite("FieldCipher (TD-12 / NFR-7)")
struct FieldCipherTests {
    private let account = try! UserID("@alice:example.org")
    private let room = try! RoomID("!r:example.org")

    private func database() throws -> HaloDatabase {
        try HaloDatabase(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("halo-cipher-\(UUID().uuidString).sqlite").path,
            observesSuspensionNotifications: false
        )
    }

    @Test("loadOrCreate generates a 32-byte key in Keychain and reuses it on subsequent loads")
    func loadOrCreatePersistsKey() async throws {
        let keychain = StubKeychain()
        let first = try await FieldCipher.loadOrCreate(keychain: keychain, account: account)
        let stored = try await keychain.read(.haloDatabaseKey(account))
        #expect(stored?.count == FieldCipher.keyByteCount)

        let ciphertext = try first.encrypt("secret draft")
        #expect(ciphertext.hasPrefix(FieldCipher.versionPrefix))
        #expect(!ciphertext.contains("secret draft"))

        let second = try await FieldCipher.loadOrCreate(keychain: keychain, account: account)
        #expect(try second.decrypt(ciphertext) == "secret draft")
    }

    @Test("DraftStore encrypts draft.body at rest and transparently reads legacy plaintext")
    func draftStoreEncryption() async throws {
        let db = try database()
        let keychain = StubKeychain()
        let cipher = try await FieldCipher.loadOrCreate(keychain: keychain, account: account)

        // Legacy plaintext row written before TD-12 is still readable.
        let legacyStore = DraftStore(database: db, account: account)
        try await legacyStore.save("legacy plain text", for: room)
        let encryptedStore = DraftStore(database: db, account: account, cipher: cipher)
        #expect(try await encryptedStore.draft(for: room) == "legacy plain text")

        // New write is stored as AES-GCM ciphertext, never plaintext.
        try await encryptedStore.save("top secret message", for: room)
        let rawBody: String? = try await db.pool.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM draft WHERE account = ? AND room_id = ?", arguments: [account.rawValue, room.rawValue])
        }
        #expect(rawBody?.hasPrefix(FieldCipher.versionPrefix) == true)
        #expect(rawBody?.contains("top secret") == false)
        #expect(try await encryptedStore.draft(for: room) == "top secret message")

        // Wrong key rejects tampered/foreign ciphertext.
        let otherCipher = try FieldCipher(keyData: Data(repeating: 0xAB, count: 32))
        let wrongStore = DraftStore(database: db, account: account, cipher: otherCipher)
        await #expect(throws: HaloError.storage(.corrupted)) {
            _ = try await wrongStore.draft(for: room)
        }
    }

    @Test("BotTaskStore encrypts title and detail at rest and round-trips cleanly")
    func botTaskStoreEncryption() async throws {
        let db = try database()
        let cipher = try FieldCipher(keyData: Data(repeating: 0x42, count: 32))
        let store = BotTaskStore(database: db, account: account, cipher: cipher)

        let entry = BotTaskEntry(
            key: .init(room: room, bot: "@bot:example.org", kind: .todo, id: "1"),
            title: "Pay quarterly taxes",
            status: .open,
            sourceEventID: try EventID("$ev1"),
            asOf: Date(timeIntervalSince1970: 100),
            detail: "Assigned to Alice"
        )
        try await store.upsert([entry])

        let raw: (String, String?)? = try await db.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT title, detail FROM bot_task WHERE account = ?", arguments: [account.rawValue])
                .map { ($0["title"] as String, $0["detail"] as String?) }
        }
        #expect(raw?.0.hasPrefix(FieldCipher.versionPrefix) == true)
        #expect(raw?.0.contains("quarterly taxes") == false)
        #expect(raw?.1?.hasPrefix(FieldCipher.versionPrefix) == true)
        #expect(raw?.1?.contains("Alice") == false)

        let loaded = try await store.entries()
        #expect(loaded.count == 1)
        #expect(loaded[0].title == "Pay quarterly taxes")
        #expect(loaded[0].detail == "Assigned to Alice")
    }
}
