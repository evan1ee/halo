import Testing
@testable import HaloDesignSystem

@Suite("avatarInitial")
struct AvatarTests {
    @Test("first letter, upper-cased; Matrix sigils skipped; a fallback for nothing")
    func initials() {
        #expect(avatarInitial(for: "ann") == "A")
        #expect(avatarInitial(for: "@bob:x.org") == "B")
        #expect(avatarInitial(for: "#room") == "R")
        #expect(avatarInitial(for: "123") == "1")
        #expect(avatarInitial(for: "") == "?")
    }

    @Test("avatar colour index is deterministic, in range, and spreads across the palette")
    func colorIndex() {
        let count = 8
        let first = avatarColorIndex(for: "Timeline fixture", count: count)
        #expect((0..<count).contains(first))
        #expect(avatarColorIndex(for: "Timeline fixture", count: count) == first)
        let spread = Set(["Timeline fixture", "Sticker pack: cats", "Unread fixture", "Encrypted evidence", "Ann", "Bob", "Carol", "Dave"].map {
            avatarColorIndex(for: $0, count: count)
        })
        #expect(spread.count >= 3)
        #expect(avatarColorIndex(for: "Ann", count: 0) == 0)
    }
}
