import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloPlatform

@Suite("AccountDataEraser")
struct AccountDataEraserTests {
    private func make() throws -> (AccountDataLocations, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-eraser-\(UUID().uuidString)", isDirectory: true)
        let locations = AccountDataLocations(
            stores: root.appendingPathComponent("matrix", isDirectory: true),
            shareInbox: root.appendingPathComponent("share-inbox", isDirectory: true),
            search: root.appendingPathComponent("search", isDirectory: true),
            chatShortcuts: root.appendingPathComponent("chat-shortcuts.json"))
        return (locations, root)
    }

    private func fill(_ locations: AccountDataLocations) throws {
        let fm = FileManager.default
        for directory in [locations.stores.appendingPathComponent("halo"), locations.stores.appendingPathComponent("store-1"), locations.shareInbox, locations.search.appendingPathComponent("abc")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent("file"))
        }
        try Data("[]".utf8).write(to: locations.chatShortcuts)
    }

    @Test("sign-out leaves nothing: stores, share inbox, search index, shortcuts, the database key and the KLIPY shelf are gone (AC-AUTH-4)")
    func erases() async throws {
        let (locations, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try fill(locations)
        let keychain = InMemoryKeychain()
        let user = try UserID("@alice:example.org")
        try await keychain.write(Data(repeating: 1, count: 32), for: .haloDatabaseKey(user))
        let suite = "halo-eraser-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        await KlipyShelfStore(account: user, defaults: defaults).save(KlipyShelf())
        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("halo.klipy.shelf.") })
        #expect(AccountDataEraser.leftovers(in: locations).count == 4)

        await AccountDataEraser.erase(locations, account: user, keychain: keychain, defaults: defaults)

        #expect(AccountDataEraser.leftovers(in: locations).isEmpty)
        #expect(try await keychain.read(.haloDatabaseKey(user)) == nil)
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("halo.klipy.shelf.") })
        // Nothing else in the container either.
        let rest = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(rest.isEmpty, "\(rest)")
    }

    @Test("with no account known (restored backup, killed sign-out) the files still go, and erasing twice is harmless")
    func erasesLeftovers() async throws {
        let (locations, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try fill(locations)
        await AccountDataEraser.erase(locations, account: nil, keychain: InMemoryKeychain())
        await AccountDataEraser.erase(locations, account: nil, keychain: InMemoryKeychain())
        #expect(AccountDataEraser.leftovers(in: locations).isEmpty)
    }

    @Test("stores, staged shares, search index and shortcuts are excluded from backups, and the flag reaches new files (AC-SEC-4)")
    func excludedFromBackup() throws {
        let (locations, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try fill(locations)
        AccountDataEraser.excludeFromBackup(locations)
        for url in locations.all {
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "\(url.lastPathComponent)")
        }
        // The folders are made and flagged before anything is written to them.
        let (fresh, freshRoot) = try make()
        defer { try? FileManager.default.removeItem(at: freshRoot) }
        AccountDataEraser.prepareStoreFolders(fresh)
        #expect(try fresh.stores.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try fresh.shareInbox.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(!FileManager.default.fileExists(atPath: fresh.search.path))
    }
}
