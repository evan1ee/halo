import Foundation
import HaloFoundation

/// Reads the content of an `m.room.image_pack` event (STICKERS §3, §8). Pure and total: malformed input yields `nil` or
/// a pack with fewer images, never a crash. Images with a bad shortcode are kept and flagged (the spec says to show them).
public enum ImagePackParser {
    public static func parse(_ json: Data, ref: PackRef, source: PackSource) -> StickerPack? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return parse(object, ref: ref, source: source)
    }

    public static func parse(_ content: [String: Any], ref: PackRef, source: PackSource) -> StickerPack? {
        guard let images = content["images"] as? [String: Any] else { return nil }
        let pack = content["pack"] as? [String: Any]
        let usage: Set<PackUsage> = {
            let listed = (pack?["usage"] as? [String] ?? []).compactMap(PackUsage.init(rawValue:))
            return listed.isEmpty ? [.sticker, .emoticon] : Set(listed)
        }()
        // The dictionary has no order; sort for a stable panel.
        let stickers: [Sticker] = images.keys.sorted().compactMap { shortcode in
            guard let image = images[shortcode] as? [String: Any], let url = image["url"] as? String, url.hasPrefix("mxc://") else { return nil }
            return Sticker(
                pack: ref, shortcode: shortcode, body: image["body"] as? String, url: url, info: info(image["info"] as? [String: Any]),
                hasValidShortcode: ShortcodeRules.isValid(shortcode))
        }
        let name = (pack?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ref.stateKey
        return StickerPack(
            ref: ref, displayName: name, avatarURL: pack?["avatar_url"] as? String, usage: usage,
            attribution: pack?["attribution"] as? String, stickers: stickers, source: source)
    }

    private static func info(_ raw: [String: Any]?) -> StickerInfo? {
        guard let raw else { return nil }
        return StickerInfo(width: raw["w"] as? Int, height: raw["h"] as? Int, mimeType: raw["mimetype"] as? String, size: raw["size"] as? Int)
    }
}

/// The shortcode grammar `^[A-Za-z0-9_-]{1,100}$` and generation of valid shortcodes (STICKERS FR-7, AC-S5).
public enum ShortcodeRules {
    public static func isValid(_ shortcode: String) -> Bool {
        guard (1...100).contains(shortcode.utf8.count) else { return false }
        return shortcode.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }
    }

    /// A valid shortcode from a file name: extension dropped, anything outside the grammar becomes `_`, repeated and
    /// edge underscores trimmed, length capped; `sticker` if nothing is left. Not unique: see `unique`.
    public static func make(fromFilename name: String) -> String {
        var stem = name
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex { stem = String(stem[..<dot]) }
        var result = ""
        for scalar in stem.unicodeScalars {
            let character = Character(scalar)
            let ok = scalar.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
            let next: Character = ok ? character : "_"
            if next == "_", result.last == "_" { continue }
            result.append(next)
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.count > 100 { result = String(result.prefix(100)) }
        return result.isEmpty ? "sticker" : result
    }

    /// `base`, or `base-2`, `base-3`… when `taken` already holds it; still within the length limit.
    public static func unique(_ base: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while true {
            let suffix = "-\(n)"
            let candidate = String(base.prefix(100 - suffix.count)) + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
