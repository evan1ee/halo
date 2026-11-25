import Foundation
import HaloFoundation

/// Allowlisted bot accounts whose recognised messages render as cards, stored in account data `one.mbm.halo.bot_allowlist`
/// (docs/data/DATA_MODELS.md, docs/features/SETTINGS.md §3). Pure.
public struct BotAllowlist: Sendable, Equatable {
    public static let version = 1
    public static let eventType = "one.mbm.halo.bot_allowlist"

    /// Unique bot user IDs in the user's chosen order.
    public let bots: [UserID]

    public init(bots: [UserID] = []) {
        var unique: [UserID] = []
        for bot in bots where !unique.contains(bot) { unique.append(bot) }
        self.bots = unique
    }

    /// Account-data JSON `{ "bots": ["@bot:server"], "version": 1 }`.
    public func accountData() -> Data {
        let object: [String: Any] = [
            "version": Self.version,
            "bots": bots.map(\.rawValue),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Parses account-data JSON. Malformed entries are skipped; unparsable content or a newer `version` returns `nil`
    /// so an older Halo leaves data written by a newer version untouched.
    public static func fromAccountData(_ data: Data) -> BotAllowlist? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { fromContent($0) }
    }

    /// Same, for the parsed content.
    public static func fromContent(_ content: [String: Any]) -> BotAllowlist? {
        guard (content["version"] as? Int ?? 1) <= version else { return nil }
        let raw = content["bots"] as? [String] ?? []
        return BotAllowlist(bots: raw.compactMap { try? UserID($0) })
    }

    /// `content` holding this list; unknown keys stay (D54).
    public func content(replacing content: [String: Any]?) -> [String: Any] {
        var content = content ?? [:]
        content["version"] = Self.version
        content["bots"] = bots.map(\.rawValue)
        return content
    }

    /// This list with the edit `old` → `new` applied: what `new` dropped is removed, what it gained is appended, and entries
    /// the editor didn't know (another device's, or not loaded yet) stay.
    public func applying(from old: BotAllowlist, to new: BotAllowlist) -> BotAllowlist {
        if bots == old.bots { return new }
        let removed = Set(old.bots).subtracting(new.bots), known = Set(old.bots)
        return BotAllowlist(bots: bots.filter { !removed.contains($0) } + new.bots.filter { !known.contains($0) })
    }
}
