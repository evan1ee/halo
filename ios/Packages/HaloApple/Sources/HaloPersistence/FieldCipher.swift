import CryptoKit
import Foundation
import HaloDomain
import HaloFoundation

/// Per-account AES-256-GCM field cipher for sensitive text columns in `halo.sqlite` (`draft.body`, `bot_task.title`,
/// `bot_task.detail`; TD-12 / R-16 / NFR-7).
///
/// Ciphertext is stored as `"enc:v1:<base64(nonce || ciphertext || tag)>"`. Existing pre-encryption plaintext rows
/// without the version prefix are returned as-is on read and encrypted transparently on the next write.
public struct FieldCipher: Sendable {
    public static let keyByteCount = 32
    public static let versionPrefix = "enc:v1:"

    private let key: SymmetricKey

    public init(keyData: Data) throws(HaloError) {
        guard keyData.count == Self.keyByteCount else {
            throw .storage(.corrupted)
        }
        self.key = SymmetricKey(data: keyData)
    }

    /// Reads the account's database key from the Keychain, or generates and stores a new 256-bit key on first use.
    public static func loadOrCreate(keychain: any KeychainPort, account: AccountID) async throws(HaloError) -> FieldCipher {
        let item = KeychainItem.haloDatabaseKey(account)
        if let existing = try await keychain.read(item), existing.count == Self.keyByteCount {
            return try FieldCipher(keyData: existing)
        }
        let generated = SymmetricKey(size: .bits256)
        let raw = generated.withUnsafeBytes { Data($0) }
        try await keychain.write(raw, for: item)
        return try FieldCipher(keyData: raw)
    }

    public func encrypt(_ plaintext: String) throws(HaloError) -> String {
        do {
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
            guard let combined = sealed.combined else { throw HaloError.storage(.corrupted) }
            return Self.versionPrefix + combined.base64EncodedString()
        } catch let error as HaloError {
            throw error
        } catch {
            throw .storage(.corrupted)
        }
    }

    public func decrypt(_ stored: String) throws(HaloError) -> String {
        guard stored.hasPrefix(Self.versionPrefix) else {
            // Transparently read pre-TD-12 plaintext rows until they are rewritten.
            return stored
        }
        let encoded = String(stored.dropFirst(Self.versionPrefix.count))
        guard let combined = Data(base64Encoded: encoded) else {
            throw .storage(.corrupted)
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw HaloError.storage(.corrupted)
            }
            return text
        } catch let error as HaloError {
            throw error
        } catch {
            throw .storage(.corrupted)
        }
    }
}
