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
}
