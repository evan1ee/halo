import Foundation
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

    private func luminance(_ c: AvatarTint.RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func contrast(_ a: AvatarTint.RGB, _ b: AvatarTint.RGB) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test("every avatar letter meets WCAG AA (>= 4.5:1) on its circle, light and dark (accessibility audit on the chat list)")
    func letterContrast() {
        for hue in AvatarTint.hues + [AvatarTint.neutral] {
            for dark in [false, true] {
                let ratio = contrast(AvatarTint.letter(hue, dark: dark), AvatarTint.background(hue, dark: dark))
                #expect(ratio >= 4.5, "hue \(hue) dark=\(dark): \(ratio)")
            }
        }
    }

    @Test("a name with no letter is grey; the same name always gets the same hue")
    func hueChoice() {
        #expect(AvatarTint.hue(for: "  ") == AvatarTint.neutral)
        #expect(AvatarTint.hue(for: "?") == AvatarTint.neutral)
        #expect(AvatarTint.hue(for: "S10") == AvatarTint.hue(for: "S10"))
        #expect(AvatarTint.hues.contains(AvatarTint.hue(for: "S10")))
    }
}
