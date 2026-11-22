import Foundation
import HaloDomain
import Testing
@testable import HaloPlatform

@Suite("SystemChatShortcutStore")
struct SystemChatShortcutStoreTests {
    private func makeFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID().uuidString)/chat-shortcuts.json")
    }

    @Test("replace stores the chats for intents, and clear removes the file")
    func roundTrip() async {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = SystemChatShortcutStore(file: file, indexName: nil)
        #expect(store.load().isEmpty)
        let chats = [ChatShortcut(id: "!a:x.org", name: "Alpha"), ChatShortcut(id: "!b:x.org", name: "Beta")]
        await store.replace(with: chats)
        #expect(store.load() == chats)
        await store.clear()
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a damaged file reads as no chats")
    func damaged() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: file)
        #expect(SystemChatShortcutStore(file: file, indexName: nil).load().isEmpty)
    }

    @Test("a Spotlight identifier opens only a valid room ID")
    func spotlightIdentifier() {
        #expect(HaloSpotlight.roomID(fromIdentifier: "!a:x.org")?.rawValue == "!a:x.org")
        #expect(HaloSpotlight.roomID(fromIdentifier: "not a room") == nil)
        #expect(HaloSpotlight.roomID(fromIdentifier: nil) == nil)
    }
}
