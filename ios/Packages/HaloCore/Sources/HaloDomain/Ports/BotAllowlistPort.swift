import HaloFoundation

/// Reads and writes the user's allowlisted bot accounts in Matrix account data (`one.mbm.halo.bot_allowlist`).
public protocol BotAllowlistPort: Sendable {
    /// Returns the stored allowlist, or `nil` when absent or written by a newer Halo version.
    func load() async throws(HaloError) -> BotAllowlist?
    /// Stores the allowlist; throws `.unsupported` rather than overwriting a newer Halo version's schema.
    func save(_ allowlist: BotAllowlist) async throws(HaloError)
}
