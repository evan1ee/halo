import Foundation
import Testing
@testable import HaloDomain

@Suite("UnreadWidgetSnapshot")
struct UnreadWidgetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("the total and chat count come from the stored per-room counts; zero counts are ignored")
    func totals() {
        let snapshot = UnreadWidgetSnapshot(counts: ["!a:x": 3, "!b:x": 2, "!c:x": 0], updatedAt: now)
        #expect(snapshot.totalUnread == 5)
        #expect(snapshot.chatCount == 2)
        #expect(snapshot.summary == "5 unread messages in 2 chats.")
    }

    @Test("summary wording: never opened, none, one, one chat")
    func wording() {
        #expect(UnreadWidgetSnapshot(counts: [:], updatedAt: nil).summary == "Open Halo to see your unread messages.")
        #expect(UnreadWidgetSnapshot(counts: [:], updatedAt: now).summary == "No unread messages.")
        #expect(UnreadWidgetSnapshot(counts: ["!a:x": 1], updatedAt: now).summary == "1 unread message.")
        #expect(UnreadWidgetSnapshot(counts: ["!a:x": 4], updatedAt: now).summary == "4 unread messages in 1 chat.")
    }

    @Test("the number is capped at 99+")
    func cap() {
        #expect(UnreadWidgetSnapshot(counts: ["!a:x": 99], updatedAt: now).countText == "99")
        #expect(UnreadWidgetSnapshot(counts: ["!a:x": 100], updatedAt: now).countText == "99+")
    }

    @Test("counts become stale after six hours, and never for a missing date")
    func stale() {
        let snapshot = UnreadWidgetSnapshot(counts: [:], updatedAt: now)
        #expect(!snapshot.isStale(at: now.addingTimeInterval(UnreadWidgetSnapshot.staleAfter)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(UnreadWidgetSnapshot.staleAfter + 1)))
        #expect(!UnreadWidgetSnapshot(counts: [:], updatedAt: nil).isStale(at: now))
    }
}
