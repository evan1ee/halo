import CommonCrypto
import CryptoKit
import Foundation
import HaloDomain
import HaloFoundation
import Security

/// Passphrase-based AES-256-GCM room export encryptor using PBKDF2-HMAC-SHA256 (D32, D63, R-P2-EXPORT).
public struct CryptoKitRoomExportEncryptor: RoomExportEncryptor {
    public static let formatIdentifier = "one.mbm.halo.room_export.v1"
    public static let defaultIterations: UInt32 = 100_000
    private static let saltByteCount = 16
    private static let keyByteCount = 32

    private struct Envelope: Codable {
        let format: String
        let kdf: String
        let iterations: UInt32
        let cipher: String
        let salt: String
        let nonce: String
        let ciphertext: String
        let tag: String
    }

    private let iterations: UInt32

    public init(iterations: UInt32 = CryptoKitRoomExportEncryptor.defaultIterations) {
        self.iterations = max(1, iterations)
    }

    public func encrypt(_ plaintext: Data, passphrase: String) throws(HaloError) -> Data {
        guard passphrase.count >= Self.minimumPassphraseLength else {
            throw .invalidInput("PASSPHRASE_TOO_SHORT")
        }
        let salt = try Self.randomBytes(count: Self.saltByteCount)
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw .internal(code: "EXPORT_ENCRYPT_FAILED")
        }

        let envelope = Envelope(
            format: Self.formatIdentifier,
            kdf: "pbkdf2-hmac-sha256",
            iterations: iterations,
            cipher: "aes-256-gcm",
            salt: salt.base64EncodedString(),
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(envelope)
        } catch {
            throw .internal(code: "EXPORT_ENCODE_FAILED")
        }
    }

    public func decrypt(_ archive: Data, passphrase: String) throws(HaloError) -> Data {
        guard passphrase.count >= Self.minimumPassphraseLength else {
            throw .invalidInput("PASSPHRASE_TOO_SHORT")
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: archive)
        } catch {
            throw .storage(.corrupted)
        }
        guard envelope.format == Self.formatIdentifier,
              envelope.kdf == "pbkdf2-hmac-sha256",
              envelope.cipher == "aes-256-gcm",
              envelope.iterations >= 1,
              let salt = Data(base64Encoded: envelope.salt),
              let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag)
        else {
            throw .storage(.corrupted)
        }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw .forbidden
        }
    }

    private static func randomBytes(count: Int) throws(HaloError) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw .internal(code: "EXPORT_RANDOM_FAILED")
        }
        return bytes
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws(HaloError) -> SymmetricKey {
        let passwordData = Data(passphrase.utf8)
        var derived = Data(count: keyByteCount)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBuf in
            salt.withUnsafeBytes { saltBuf in
                passwordData.withUnsafeBytes { passBuf in
                    guard let derivedPtr = derivedBuf.bindMemory(to: UInt8.self).baseAddress,
                          let saltPtr = saltBuf.bindMemory(to: UInt8.self).baseAddress,
                          let passPtr = passBuf.bindMemory(to: Int8.self).baseAddress
                    else { return Int32(kCCParamError) }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr,
                        passwordData.count,
                        saltPtr,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr,
                        keyByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw .internal(code: "EXPORT_KDF_FAILED")
        }
        return SymmetricKey(data: derived)
    }
}
