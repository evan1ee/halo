import Foundation
import Testing
@testable import HaloDomain

@Suite("UnreadChatsSnapshot")
struct UnreadChatsSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let names = ["!a:x": "Alpha", "!b:x": "Beta", "!c:x": "Gamma"]

    @Test("rows are the named chats with unread messages, most unread first, then by name")
    func ordering() {
        let snapshot = UnreadChatsSnapshot(counts: ["!a:x": 2, "!b:x": 5, "!c:x": 2, "!z:x": 0], names: names, updatedAt: now)
        #expect(snapshot.rows.map(\.name) == ["Beta", "Alpha", "Gamma"])
        #expect(snapshot.rows.map(\.unread) == [5, 2, 2])
        #expect(snapshot.moreCount == 0)
    }

    @Test("the list is capped and the rest are counted, including chats whose names are unknown")
    func cap() {
        let counts = ["!a:x": 4, "!b:x": 3, "!c:x": 2, "!unknown:x": 9]
        let snapshot = UnreadChatsSnapshot(counts: counts, names: names, updatedAt: now, limit: 2)
        #expect(snapshot.rows.map(\.name) == ["Alpha", "Beta"])
        #expect(snapshot.moreCount == 2)
    }

    @Test("without names it shows no chats and explains how to turn them on; without a date it says to open Halo")
    func emptyStates() {
        let noNames = UnreadChatsSnapshot(counts: ["!a:x": 3], names: [:], updatedAt: now)
        #expect(noNames.rows.isEmpty && !noNames.namesAvailable)
        #expect(noNames.summary.contains("Chats in Siri and Spotlight"))
        #expect(UnreadChatsSnapshot(counts: [:], names: names, updatedAt: nil).summary == "Open Halo to see your unread chats.")
        #expect(UnreadChatsSnapshot(counts: [:], names: names, updatedAt: now).summary == "No unread messages.")
    }
}
