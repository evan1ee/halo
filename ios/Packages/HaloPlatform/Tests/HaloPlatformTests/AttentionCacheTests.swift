import Foundation
import HaloFoundation
import Testing
@testable import HaloPlatform

@Suite("AttentionCache")
struct AttentionCacheTests {
    @Test("the app stores per-room unread badge counts with timestamp, migrates legacy v1 rooms, and tracks foreground state (D82)")
    func cache() throws {
        let suite = "halo.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = AttentionCache(suiteName: suite)
        let a = try RoomID("!a:x.org"), b = try RoomID("!b:x.org")
        #expect(cache.roomCounts().isEmpty)
        #expect(cache.updatedAt() == nil)

        // Legacy v1 array migrates seamlessly to 1 per room until overwritten.
        UserDefaults(suiteName: suite)?.set([a.rawValue], forKey: "attentionRooms.v1")
        #expect(cache.roomCounts() == [a: 1])

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        cache.store([a: 10, b: 2], at: t1)
        #expect(cache.roomCounts() == [a: 10, b: 2])
        #expect(cache.roomIDs() == [a, b])
        #expect(cache.updatedAt() == t1)

        cache.store([b: 3])
        #expect(cache.roomCounts() == [b: 3])
        #expect(cache.rooms() == ["!b:x.org"])

        #expect(!cache.isForeground())
        cache.setForeground(true)
        #expect(cache.isForeground())
        cache.setForeground(false)
        #expect(!cache.isForeground())
    }
}
