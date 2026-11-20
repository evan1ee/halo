import Foundation
import HaloFoundation

// Sticker packs as Matrix defines them (docs/features/STICKERS.md §3, §8): `m.room.image_pack` state events. Pure values.

/// Where a pack lives: the room that holds it and the state key that names it.
public struct PackRef: Sendable, Hashable, Codable {
    public let room: RoomID
    public let stateKey: String

    public init(room: RoomID, stateKey: String) {
        self.room = room
        self.stateKey = stateKey
    }
}

public struct StickerInfo: Sendable, Equatable {
    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    public let size: Int?

    public init(width: Int? = nil, height: Int? = nil, mimeType: String? = nil, size: Int? = nil) {
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.size = size
    }
}

public struct Sticker: Sendable, Equatable, Identifiable {
    public let pack: PackRef
    public let shortcode: String
    public let body: String?
    /// The `mxc://` URI of the image.
    public let url: String
    public let info: StickerInfo?
    /// `false` when the shortcode breaks the grammar; the spec says such images are still shown.
    public let hasValidShortcode: Bool
    /// What the media loader needs to show the image; set by the adapter that read the pack, `nil` in pure values.
    public let image: MediaRef?

    public var id: StickerRef { ref }
    public var ref: StickerRef { StickerRef(pack: pack, shortcode: shortcode) }

    /// What a sticker event carries as `body`: the image's body, else the shortcode.
    public var eventBody: String { body ?? shortcode }

    /// The same sticker with its image reference.
    public func with(image: MediaRef?) -> Sticker {
        Sticker(pack: pack, shortcode: shortcode, body: body, url: url, info: info, hasValidShortcode: hasValidShortcode, image: image)
    }

    public init(pack: PackRef, shortcode: String, body: String?, url: String, info: StickerInfo?, hasValidShortcode: Bool = true, image: MediaRef? = nil) {
        self.image = image
        self.pack = pack
        self.shortcode = shortcode
        self.body = body
        self.url = url
        self.info = info
        self.hasValidShortcode = hasValidShortcode
    }
}

public enum PackUsage: String, Sendable, Hashable { case sticker, emoticon }

public enum PackSource: Sendable, Equatable {
    /// Listed in the user's `m.image_pack.rooms`.
    case userEnabled
    /// A pack in the room being viewed.
    case room
    /// Read from the legacy `im.ponies.*` events.
    case legacy
}

public struct StickerPack: Sendable, Equatable, Identifiable {
    public var id: PackRef { ref }
    public let ref: PackRef
    public let displayName: String
    /// The `mxc://` URI of the pack avatar.
    public let avatarURL: String?
    /// Empty in the event means "both"; this holds the resolved set.
    public let usage: Set<PackUsage>
    public let attribution: String?
    public let stickers: [Sticker]
    public let source: PackSource

    public var offersStickers: Bool { usage.contains(.sticker) }

    /// The same pack with `transform` applied to every sticker.
    public func mapStickers(_ transform: (Sticker) -> Sticker) -> StickerPack {
        StickerPack(ref: ref, displayName: displayName, avatarURL: avatarURL, usage: usage, attribution: attribution, stickers: stickers.map(transform), source: source)
    }

    public init(ref: PackRef, displayName: String, avatarURL: String?, usage: Set<PackUsage>, attribution: String?, stickers: [Sticker], source: PackSource) {
        self.ref = ref
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.usage = usage
        self.attribution = attribution
        self.stickers = stickers
        self.source = source
    }
}

/// A sticker named independently of its pack's contents, as favourites and recents store it.
public struct StickerRef: Sendable, Hashable, Codable {
    public let pack: PackRef
    public let shortcode: String

    public init(pack: PackRef, shortcode: String) {
        self.pack = pack
        self.shortcode = shortcode
    }
}
