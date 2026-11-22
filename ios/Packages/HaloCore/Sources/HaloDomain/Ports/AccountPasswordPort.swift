import HaloFoundation

/// Changing the account password (docs/features/SETTINGS.md §3 → Account → Change password).
public protocol AccountPasswordPort: Sendable {
    /// Whether this account's password is managed by Halo's homeserver login. `false` for accounts that signed in through an
    /// external identity service (their password is changed on that service's web page).
    func canChangePassword() async -> Bool

    /// Sets `new`, proving `current`. Other sessions stay signed in. Throws `.invalidInput("CURRENT_PASSWORD")` when `current`
    /// is wrong and `.invalidInput("NEW_PASSWORD")` when the homeserver refuses `new` (too weak or reused).
    func changePassword(current: String, new: String) async throws(HaloError)
}
