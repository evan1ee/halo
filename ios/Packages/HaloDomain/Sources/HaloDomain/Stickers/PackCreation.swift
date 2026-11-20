import Foundation
import HaloFoundation

/// An image of a pack being created, already prepared (STICKERS FR-7, D52: at most 512 px on the long side).
public struct NewStickerImage: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    /// Valid per `ShortcodeRules`; unique within the pack.
    public let shortcode: String
    public let body: String?

    public init(data: Data, mimeType: String, width: Int?, height: Int?, shortcode: String, body: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.shortcode = shortcode
        self.body = body
    }
}

/// Creates a personal pack: an unencrypted private room holding one `m.room.image_pack` event (D48), enabled in the user's
/// `m.image_pack.rooms`. Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol StickerPackCreationPort: Sendable {
    /// Uploads the images and writes the pack. `progress(done, total)` is called after each upload. Throws
    /// `.invalidInput` for no images or an invalid/duplicate shortcode.
    func createPack(name: String, images: [NewStickerImage], progress: @escaping @Sendable (Int, Int) -> Void) async throws(HaloError) -> PackRef
}

/// Pure builders for the events a created pack consists of. Content is a JSON object as `[String: Any]`.
public enum ImagePackBuilder {
    public static let maximumImages = 120
    public static let stateKey = "pack"

    /// The room name of a personal pack ("accepted", STICKERS §11).
    public static func roomName(for packName: String) -> String { "Sticker pack: \(packName)" }

    /// Checks names and images; the message is a stable code for the UI.
    public static func validate(name: String, shortcodes: [String]) throws(HaloError) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput("EMPTY_PACK_NAME") }
        guard !shortcodes.isEmpty else { throw .invalidInput("NO_IMAGES") }
        guard shortcodes.count <= maximumImages else { throw .invalidInput("TOO_MANY_IMAGES") }
        guard shortcodes.allSatisfy(ShortcodeRules.isValid) else { throw .invalidInput("BAD_SHORTCODE") }
        guard Set(shortcodes).count == shortcodes.count else { throw .invalidInput("DUPLICATE_SHORTCODE") }
    }

    /// The `m.room.image_pack` content. `uploaded` pairs each image with the `mxc://` URI it was uploaded to.
    public static func content(name: String, uploaded: [(image: NewStickerImage, url: String)]) -> [String: Any] {
        var images: [String: Any] = [:]
        for (image, url) in uploaded {
            var entry: [String: Any] = ["url": url, "body": image.body ?? image.shortcode]
            var info: [String: Any] = ["mimetype": image.mimeType, "size": image.data.count]
            if let w = image.width { info["w"] = w }
            if let h = image.height { info["h"] = h }
            entry["info"] = info
            images[image.shortcode] = entry
        }
        return ["images": images, "pack": ["display_name": name.trimmingCharacters(in: .whitespacesAndNewlines), "usage": ["sticker"]]]
    }
}

/// Edits the account data that lists packs. Unknown properties are preserved (the spec requires it).
public enum PackRegistry {
    /// `m.image_pack.rooms` with `ref` added: `{ rooms: { roomId: { stateKey: {} } } }`.
    public static func enabling(_ ref: PackRef, in content: [String: Any]?) -> [String: Any] {
        var content = content ?? [:]
        var rooms = content["rooms"] as? [String: Any] ?? [:]
        var packs = rooms[ref.room.rawValue] as? [String: Any] ?? [:]
        if packs[ref.stateKey] == nil { packs[ref.stateKey] = [String: Any]() }
        rooms[ref.room.rawValue] = packs
        content["rooms"] = rooms
        return content
    }

    /// `one.mbm.halo.sticker_rooms` with `room` added: `{ version: 1, rooms: [roomId] }`; used to hide pack rooms from the
    /// room list. Returns `nil` when the stored content is from a newer version (leave it alone).
    public static func recordingPackRoom(_ room: RoomID, in content: [String: Any]?) -> [String: Any]? {
        var content = content ?? ["version": 1]
        guard (content["version"] as? Int ?? 1) <= 1 else { return nil }
        var rooms = content["rooms"] as? [String] ?? []
        if !rooms.contains(room.rawValue) { rooms.append(room.rawValue) }
        content["rooms"] = rooms
        content["version"] = 1
        return content
    }
}
