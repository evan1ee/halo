import CryptoKit
import Foundation
import HaloDomain
import HaloFoundation
import Security

/// `KeychainPort` over the Security framework (docs/security/SECURITY.md §3).
///
/// Items are generic passwords, `afterFirstUnlockThisDeviceOnly`, non-synchronisable, in the shared
/// access group so the NSE reads what the app wrote. Names are versioned (`session.v1`, …) and
/// account-scoped items are keyed by a hash of the user ID, never the raw ID.
public struct KeychainStore: KeychainPort {
    private let service: String
    private let accessGroup: String?

    /// - Parameters:
    ///   - service: the Keychain service, the project namespace root (`one.mbm.halo`, D63).
    ///   - accessGroup: `<TeamID>.one.mbm.halo.shared`; `nil` in tests, which run without entitlements.
    public init(service: String, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func read(_ item: KeychainItem) async throws(HaloError) -> Data? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .storage(.corrupted) }
            return data
        case errSecItemNotFound: return nil
        default: throw Self.map(status)
        }
    }

    public func write(_ data: Data, for item: KeychainItem) async throws(HaloError) {
        let update = SecItemUpdate(baseQuery(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess: return
        case errSecItemNotFound:
            var add = baseQuery(item)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Self.map(status) }
        default: throw Self.map(update)
        }
    }

    public func delete(_ item: KeychainItem) async throws(HaloError) {
        let status = SecItemDelete(baseQuery(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.map(status) }
    }

    // MARK: Internals

    private func baseQuery(_ item: KeychainItem) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.accountName(item),
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func accountName(_ item: KeychainItem) -> String {
        switch item {
        case .session: "session.v1"
        case .sdkStorePassphrase(let account): "sdk-store-passphrase.v1.\(directoryHash(account))"
        case .haloDatabaseKey(let account): "halo-db-key.v1.\(directoryHash(account))"
        }
    }

    /// The first 16 hex digits of SHA-256 of the user ID (PERSISTENCE §1): stable, not reversible by sight.
    static func directoryHash(_ account: AccountID) -> String {
        SHA256.hash(data: Data(account.rawValue.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Before the first unlock after a reboot the Keychain is unreadable: that is a retryable
    /// `.unavailable`, not a missing item (ERROR_HANDLING).
    static func map(_ status: OSStatus) -> HaloError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .storage(.unavailable)
        case errSecDecode, errSecDataNotAvailable: .storage(.corrupted)
        default: .internal(code: "KEYCHAIN_\(status)")
        }
    }
}
