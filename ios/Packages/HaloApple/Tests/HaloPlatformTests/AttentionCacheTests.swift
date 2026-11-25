import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPlatform

@Suite("AttentionCache")
struct AttentionCacheTests {
    @Test("per-room unread badge counts are stored with their time, and legacy v1 rooms migrate (D82)")
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
        cache.storeDisplayed([a: 10, b: 2], at: t1)
        #expect(cache.roomCounts() == [a: 10, b: 2])
        #expect(cache.roomIDs() == [a, b])
        #expect(cache.updatedAt() == t1)
        // Upgraded from a version without a baseline: what is shown is the base.
        #expect(cache.baseline() == AttentionBaseline(counts: [a: 10, b: 2], evaluatedAt: t1))

        cache.storeDisplayed([b: 3])
        #expect(cache.roomCounts() == [b: 3])
        #expect(cache.rooms() == ["!b:x.org"])
    }

    @Test("the extension changes only what is shown; the app's evaluation stays its base until the app writes again")
    func baseline() throws {
        let suite = "halo.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = AttentionCache(suiteName: suite)
        let a = try RoomID("!a:x.org"), b = try RoomID("!b:x.org"), old = try RoomID("!old:x.org")
        let at = Date(timeIntervalSince1970: 1_700_000_000), synced = at.addingTimeInterval(-60)
        cache.store(BadgeSnapshot(
            attentionCounts: [a: 3], evaluatedAt: at,
            syncedThrough: [a: synced, b: synced, old: at.addingTimeInterval(-30 * 24 * 3600)]))
        #expect(cache.roomCounts() == [a: 3] && cache.updatedAt() == at)
        cache.storeDisplayed([a: 4, b: 1])
        #expect(cache.roomCounts() == [a: 4, b: 1])  // widgets
        #expect(cache.baseline() == AttentionBaseline(
            counts: [a: 3], displayed: [a: 4, b: 1], evaluatedAt: at, syncedThrough: [a: synced, b: synced]))
        cache.store(BadgeSnapshot(attentionCounts: [:], evaluatedAt: at.addingTimeInterval(5)))
        #expect(cache.roomCounts().isEmpty && cache.baseline().counts.isEmpty)
    }

    @Test("the foreground flag ends by itself: an app killed in front doesn't stop the extension from updating the badge (R-08)")
    func foregroundLease() throws {
        let suite = "halo.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = AttentionCache(suiteName: suite)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!cache.isForeground(at: start))
        cache.setForeground(true, at: start)
        #expect(cache.isForeground(at: start.addingTimeInterval(AttentionCache.foregroundRenewal * 2)))
        #expect(!cache.isForeground(at: start.addingTimeInterval(AttentionCache.foregroundLease)))
        cache.setForeground(true, at: start)
        cache.setForeground(false, at: start)
        #expect(!cache.isForeground(at: start))
        // The flag of an older version, left set by a kill, means nothing.
        let oldFlag = "appForeground.v1"
        UserDefaults(suiteName: suite)?.set(true, forKey: oldFlag)
        #expect(!cache.isForeground(at: start))
    }

    @Test("a widget is stale when it last rendered other counts, whoever stored the current ones")
    func staleWidgets() throws {
        let suite = "halo.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = AttentionCache(suiteName: suite)
        let a = try RoomID("!a:x.org")
        cache.storeDisplayed([a: 8])
        #expect(cache.staleWidgets().isEmpty)  // no widget on the Home Screen
        cache.markRendered(cache.counts(), widget: "unread")
        #expect(cache.staleWidgets().isEmpty)
        cache.storeDisplayed([a: 3])  // the extension; iOS ignored its reload
        cache.markRendered([:], widget: "chats")
        #expect(cache.staleWidgets() == ["chats", "unread"])
        cache.markRendered(cache.counts(), widget: "unread")
        #expect(cache.staleWidgets() == ["chats"])
    }
}
