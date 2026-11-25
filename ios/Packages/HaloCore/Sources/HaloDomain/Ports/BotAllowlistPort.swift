import HaloFoundation

/// Reads and changes the user's allowlisted bot accounts in Matrix account data (`one.mbm.halo.bot_allowlist`).
public protocol BotAllowlistPort: Sendable {
    /// Returns the stored allowlist, or `nil` when the account has none or a newer Halo version wrote it. Throws when that
    /// isn't known (nothing local yet and the server can't be asked).
    func load() async throws(HaloError) -> BotAllowlist?
    /// Applies the edit `old` → `new` to the list the server has now and returns the result; throws `.unsupported` rather than
    /// overwriting a newer Halo version's schema.
    func change(from old: BotAllowlist, to new: BotAllowlist) async throws(HaloError) -> BotAllowlist
}
