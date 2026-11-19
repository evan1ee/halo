import Foundation
import HaloFoundation

/// Secrets in the Keychain (docs/security/SECURITY.md §3). Implemented by `HaloPlatform` with
/// `afterFirstUnlockThisDeviceOnly`, non-synchronisable items in the shared access group
/// `<TeamID>.one.mbm.halo.shared` (D63).
public protocol KeychainPort: Sendable {
    /// `nil` if the item doesn't exist; `.storage(.unavailable)` before the first unlock.
    func read(_ item: KeychainItem) async throws(HaloError) -> Data?
    func write(_ data: Data, for item: KeychainItem) async throws(HaloError)
    /// Deleting an item that doesn't exist succeeds.
    func delete(_ item: KeychainItem) async throws(HaloError)
}

/// The Keychain items Halo owns (SECURITY §3). `HaloPlatform` maps them to versioned item names
/// (`session.v1`, `sdk-store-passphrase.v1`, `halo-db-key.v1`, docs/data/MIGRATIONS.md §4) and keys
/// account-scoped items by the account's directory hash (PERSISTENCE §1), never by the raw user ID.
public enum KeychainItem: Sendable, Hashable {
    /// The signed-in session. One account in the MVP (SYSTEM_DESIGN §4).
    case session
    case sdkStorePassphrase(AccountID)
    case haloDatabaseKey(AccountID)
}
