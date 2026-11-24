import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("Sticker pack management domain")
struct StickerPackManagementDomainTests {
    @Test("renaming updates display_name while preserving images, metadata and unknown keys")
    func renamePreservesUnknownFields() throws {
        let original: [String: Any] = [
            "images": ["wave": ["url": "mxc://x/wave", "body": "Wave"]],
            "pack": ["display_name": "Old", "usage": ["sticker"], "avatar_url": "mxc://x/avatar", "custom": true],
            "extra_top": 42,
        ]
        let renamed = try ImagePackBuilder.renaming(to: "  New Name  ", in: original)
        let pack = try #require(renamed["pack"] as? [String: Any])
        #expect(pack["display_name"] as? String == "New Name")
        #expect(pack["avatar_url"] as? String == "mxc://x/avatar")
        #expect(pack["custom"] as? Bool == true)
        #expect(renamed["extra_top"] as? Int == 42)
        let images = try #require(renamed["images"] as? [String: Any])
        #expect(images["wave"] != nil)
    }

    @Test("renaming rejects blank names")
    func renameRejectsBlank() {
        #expect(throws: HaloError.invalidInput("EMPTY_PACK_NAME")) {
            _ = try ImagePackBuilder.renaming(to: "   ", in: ["images": [:]])
        }
    }

    @Test("adding merges new stickers and rejects duplicates or overflow")
    func addStickersMergesAndValidates() throws {
        let base: [String: Any] = [
            "images": ["existing": ["url": "mxc://x/existing", "body": "Existing"]],
            "pack": ["display_name": "Cats", "usage": ["sticker"]],
        ]
        let addedImage = NewStickerImage(data: Data([1, 2, 3]), mimeType: "image/png", width: 512, height: 512, shortcode: "meow")
        let updated = try ImagePackBuilder.adding(uploaded: [(addedImage, "mxc://x/meow")], to: base)
        let images = try #require(updated["images"] as? [String: Any])
        #expect(images.count == 2)
        #expect((images["meow"] as? [String: Any])?["url"] as? String == "mxc://x/meow")

        let duplicate = NewStickerImage(data: Data([1]), mimeType: "image/png", width: 10, height: 10, shortcode: "existing")
        #expect(throws: HaloError.invalidInput("DUPLICATE_SHORTCODE")) {
            _ = try ImagePackBuilder.adding(uploaded: [(duplicate, "mxc://x/dup")], to: base)
        }
    }

    @Test("removing deletes a single sticker and returns nil when absent")
    func removeSingleSticker() throws {
        let base: [String: Any] = [
            "images": [
                "one": ["url": "mxc://x/1"],
                "two": ["url": "mxc://x/2"],
            ],
            "pack": ["display_name": "Cats"],
        ]
        let updated = try #require(ImagePackBuilder.removing(shortcode: "one", from: base))
        let images = try #require(updated["images"] as? [String: Any])
        #expect(images["one"] == nil)
        #expect(images["two"] != nil)
        #expect(ImagePackBuilder.removing(shortcode: "missing", from: base) == nil)
    }

    @Test("PackRegistry.removingPackRoom removes only the target room")
    func removingPackRoom() throws {
        let roomA = try RoomID("!a:x.org")
        let roomB = try RoomID("!b:x.org")
        let content: [String: Any] = ["version": 1, "rooms": [roomA.rawValue, roomB.rawValue]]
        let updated = try #require(PackRegistry.removingPackRoom(roomA, in: content))
        #expect(updated["rooms"] as? [String] == [roomB.rawValue])
        #expect(PackRegistry.removingPackRoom(roomA, in: ["version": 2, "rooms": [roomA.rawValue]]) == nil)
    }
}
