import Foundation
import HaloDesignSystem
import SwiftUI
import Testing

@Suite("RoomRow VoiceOver accessibility summary (DESIGN_SYSTEM §9, AC-UX-8)")
struct RoomRowAccessibilityTests {
    @Test("combines name, unread count, preview and timestamp into one natural label")
    func unreadCountRow() {
        let label = RoomRow<EmptyView>.accessibilitySummary(
            name: "Alice",
            preview: "See you at 10:30!",
            timestamp: "10:42",
            isMuted: false,
            isFavourite: false,
            indicator: .count(3)
        )
        #expect(label == "Alice, 3 unread messages, last message See you at 10:30!, 10:42")
    }

    @Test("uses singular for 1 unread message or 1 mention, and includes favourite/muted flags")
    func singularAndFlags() {
        let oneUnread = RoomRow<EmptyView>.accessibilitySummary(
            name: "Bob",
            preview: nil,
            timestamp: "Yesterday",
            isMuted: true,
            isFavourite: true,
            indicator: .count(1)
        )
        #expect(oneUnread == "Bob, Favourite, Muted, 1 unread message, Yesterday")

        let oneMention = RoomRow<EmptyView>.accessibilitySummary(
            name: "Design Ops",
            preview: "Check tokens",
            timestamp: nil,
            isMuted: false,
            isFavourite: false,
            indicator: .mentions(1)
        )
        #expect(oneMention == "Design Ops, 1 mention, last message Check tokens")
    }

    @Test("omits unread phrase when indicator is none and describes approximate/dot")
    func noneAndApproximate() {
        let read = RoomRow<EmptyView>.accessibilitySummary(
            name: "General",
            preview: "Hi",
            timestamp: "Mon",
            isMuted: false,
            isFavourite: false,
            indicator: .none
        )
        #expect(read == "General, last message Hi, Mon")

        let approx = RoomRow<EmptyView>.accessibilitySummary(
            name: "Encrypted",
            preview: nil,
            timestamp: nil,
            isMuted: false,
            isFavourite: false,
            indicator: .approximate
        )
        #expect(approx == "Encrypted, unread messages")
    }

    @Test("splits sender prefixes from multi-line and single-line previews while ignoring plain text and URLs")
    func previewPrefixSplit() {
        let own = RoomRow<EmptyView>.splitPreviewPrefix("You: Image")
        #expect(own?.prefix == "You:")
        #expect(own?.body == " Image")

        let multiline = RoomRow<EmptyView>.splitPreviewPrefix("shirdn: port: 7890\nsocks-port: 7891...")
        #expect(multiline?.prefix == "shirdn:")
        #expect(multiline?.body == " port: 7890\nsocks-port: 7891...")

        #expect(RoomRow<EmptyView>.splitPreviewPrefix("Plain message without sender") == nil)
        #expect(RoomRow<EmptyView>.splitPreviewPrefix("https://example.com/a: b") == nil)
        #expect(RoomRow<EmptyView>.splitPreviewPrefix("First line\nSecond: line") == nil)
    }

    @Test("Localizable.xcstrings exists and is a valid String Catalog with English source language")
    func stringCatalogIsValid() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/App/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalog)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "en")
        #expect(json["version"] as? String == "1.0")
        let strings = try #require(json["strings"] as? [String: Any])
        #expect(strings["%lld unread messages"] != nil)
        #expect(strings["%lld members"] != nil)
        #expect(strings["Chats"] != nil)
    }
}
