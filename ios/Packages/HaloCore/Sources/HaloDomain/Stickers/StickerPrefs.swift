import Foundation
import HaloFoundation

/// Favourites and recents, stored in account data `one.mbm.halo.sticker_prefs` (D51, STICKERS §3). Pure.
public struct StickerPrefs: Sendable, Equatable {
    public struct Recent: Sendable, Equatable {
        public let sticker: StickerRef
        /// Milliseconds since 1970 of the last use.
        public let usedAt: Int64

        public init(sticker: StickerRef, usedAt: Int64) {
            self.sticker = sticker
            self.usedAt = usedAt
        }
    }

    public static let maximumRecents = 30
    public static let version = 1

    public private(set) var favourites: [StickerRef]
    /// Newest first.
    public private(set) var recents: [Recent]

    public init(favourites: [StickerRef] = [], recents: [Recent] = []) {
        self.favourites = favourites
        self.recents = Array(Self.normalised(recents).prefix(Self.maximumRecents))
    }

    /// The account-data content `{version, favourites: [{room, pack, shortcode}], recents: [{room, pack, shortcode, ts}]}`.
    public func accountData() -> Data {
        func entry(_ ref: StickerRef) -> [String: Any] { ["room": ref.pack.room.rawValue, "pack": ref.pack.stateKey, "shortcode": ref.shortcode] }
        let object: [String: Any] = [
            "version": Self.version,
            "favourites": favourites.map(entry),
            "recents": recents.map { var e = entry($0.sticker); e["ts"] = $0.usedAt; return e },
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Reads account-data content. Malformed entries are skipped; unparsable content, or a newer `version`, gives `nil`
    /// (the caller then leaves the stored data alone instead of overwriting something it doesn't understand).
    public static func fromAccountData(_ data: Data) -> StickerPrefs? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (object["version"] as? Int ?? 1) <= version else { return nil }
        func ref(_ e: [String: Any]) -> StickerRef? {
            guard let room = (e["room"] as? String).flatMap({ try? RoomID($0) }), let pack = e["pack"] as? String, let shortcode = e["shortcode"] as? String else { return nil }
            return StickerRef(pack: PackRef(room: room, stateKey: pack), shortcode: shortcode)
        }
        let favourites = (object["favourites"] as? [[String: Any]] ?? []).compactMap(ref)
        let recents: [Recent] = (object["recents"] as? [[String: Any]] ?? []).compactMap { e in
            guard let r = ref(e), let ts = (e["ts"] as? Int64) ?? (e["ts"] as? Int).map(Int64.init) else { return nil }
            return Recent(sticker: r, usedAt: ts)
        }
        var unique: [StickerRef] = []
        for f in favourites where !unique.contains(f) { unique.append(f) }
        return StickerPrefs(favourites: unique, recents: recents)
    }

    public func isFavourite(_ sticker: StickerRef) -> Bool { favourites.contains(sticker) }

    public mutating func toggleFavourite(_ sticker: StickerRef) {
        if let index = favourites.firstIndex(of: sticker) { favourites.remove(at: index) } else { favourites.append(sticker) }
    }

    /// Records a use: moves the sticker to the front of the recents.
    public mutating func recordUse(_ sticker: StickerRef, at time: Date) {
        let stamp = Int64((time.timeIntervalSince1970 * 1000).rounded())
        self = StickerPrefs(favourites: favourites, recents: recents + [Recent(sticker: sticker, usedAt: stamp)])
    }

    /// Combines two devices' prefs: the union of favourites (keeping this side's order, then the other's new ones), and the
    /// newest use of each sticker in the recents, capped. Commutative for recents, idempotent for both.
    public func merged(with other: StickerPrefs) -> StickerPrefs {
        StickerPrefs(favourites: favourites + other.favourites.filter { !favourites.contains($0) }, recents: recents + other.recents)
    }

    /// Newest use per sticker, newest first; ties break on the sticker's room and shortcode so the order is deterministic.
    private static func normalised(_ recents: [Recent]) -> [Recent] {
        var newest: [StickerRef: Recent] = [:]
        for recent in recents where recent.usedAt >= (newest[recent.sticker]?.usedAt ?? Int64.min) { newest[recent.sticker] = recent }
        return newest.values.sorted {
            if $0.usedAt != $1.usedAt { return $0.usedAt > $1.usedAt }
            return ($0.sticker.pack.room.rawValue, $0.sticker.pack.stateKey, $0.sticker.shortcode) < ($1.sticker.pack.room.rawValue, $1.sticker.pack.stateKey, $1.sticker.shortcode)
        }
    }
}

/// Search over the visible packs (STICKERS FR-4). Pure.
public enum StickerSearch {
    /// Stickers whose shortcode or body contains `query` (case-insensitive), best first: favourites, then recents (newest
    /// first), then the rest in pack order. Prefix matches rank above substring matches within each group. A blank query matches nothing.
    public static func search(_ query: String, in packs: [StickerPack], prefs: StickerPrefs) -> [Sticker] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        struct Hit { let sticker: Sticker; let order: Int; let isPrefix: Bool }
        var hits: [Hit] = []
        var order = 0
        for pack in packs where pack.offersStickers {
            for sticker in pack.stickers {
                let fields = [sticker.shortcode.lowercased(), (sticker.body ?? "").lowercased()]
                if fields.contains(where: { $0.contains(needle) }) {
                    hits.append(Hit(sticker: sticker, order: order, isPrefix: fields.contains { $0.hasPrefix(needle) }))
                }
                order += 1
            }
        }
        func group(_ hit: Hit) -> Int {
            if prefs.isFavourite(hit.sticker.ref) { return 0 }
            return prefs.recents.contains { $0.sticker == hit.sticker.ref } ? 1 : 2
        }
        func recency(_ hit: Hit) -> Int { prefs.recents.firstIndex { $0.sticker == hit.sticker.ref } ?? Int.max }
        return hits.sorted { a, b in
            if group(a) != group(b) { return group(a) < group(b) }
            if a.isPrefix != b.isPrefix { return a.isPrefix }
            if group(a) == 1, recency(a) != recency(b) { return recency(a) < recency(b) }
            return a.order < b.order
        }.map(\.sticker)
    }
}
