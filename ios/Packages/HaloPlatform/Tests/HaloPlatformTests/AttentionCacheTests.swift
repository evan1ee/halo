import Foundation
import HaloFoundation
import Testing
@testable import HaloPlatform

@Suite("AttentionCache")
struct AttentionCacheTests {
    @Test("the app stores the attention set and the extension adds a room idempotently")
    func cache() throws {
        let suite = "halo.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = AttentionCache(suiteName: suite)
        let a = try RoomID("!a:x.org"), b = try RoomID("!b:x.org")
        #expect(cache.rooms().isEmpty)
        cache.store([a])
        #expect(cache.adding(b) == 2)
        #expect(cache.adding(b) == 2)  // the same room again doesn't count twice
        cache.store([b])  // the app's recomputation overwrites whatever the extension added
        #expect(cache.rooms() == ["!b:x.org"])
        #expect(cache.roomIDs() == [b])
        #expect(!cache.isForeground())
        cache.setForeground(true)
        #expect(cache.isForeground())
        cache.setForeground(false)
        #expect(!cache.isForeground())
    }
}
