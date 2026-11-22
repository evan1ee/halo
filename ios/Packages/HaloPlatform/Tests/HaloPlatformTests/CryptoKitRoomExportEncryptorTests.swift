import Foundation
import HaloDomain
import HaloFoundation
import HaloPlatform
import Testing

@Suite("CryptoKitRoomExportEncryptor (D32)")
struct CryptoKitRoomExportEncryptorTests {
    @Test("round-trips plaintext with PBKDF2-HMAC-SHA256 + AES-256-GCM and uses fresh salt/nonce per call")
    func roundTrip() throws {
        // Use lower iterations in unit tests for speed while exercising the exact same KDF + AEAD code path.
        let encryptor = CryptoKitRoomExportEncryptor(iterations: 1_000)
        let plaintext = Data("{\"room\":\"Design\",\"messages\":[\"hello\"]}".utf8)

        let first = try encryptor.encrypt(plaintext, passphrase: "correct horse battery staple")
        let second = try encryptor.encrypt(plaintext, passphrase: "correct horse battery staple")

        #expect(first != second)
        #expect(try encryptor.decrypt(first, passphrase: "correct horse battery staple") == plaintext)
        #expect(try encryptor.decrypt(second, passphrase: "correct horse battery staple") == plaintext)
    }

    @Test("wrong passphrase and tampered ciphertext fail cleanly")
    func rejectsWrongPassphraseAndTampering() throws {
        let encryptor = CryptoKitRoomExportEncryptor(iterations: 1_000)
        let archive = try encryptor.encrypt(Data("secret history".utf8), passphrase: "long-valid-passphrase")

        #expect(throws: HaloError.forbidden) {
            _ = try encryptor.decrypt(archive, passphrase: "wrong-valid-passphrase")
        }

        // Flip a byte in the base64 ciphertext string inside the JSON envelope.
        var text = try #require(String(data: archive, encoding: .utf8))
        let range = try #require(text.range(of: "\"ciphertext\" : \""))
        let idx = range.upperBound
        let replacement = text[idx] == "A" ? "B" : "A"
        text.replaceSubrange(idx...idx, with: replacement)

        #expect(throws: HaloError.self) {
            _ = try encryptor.decrypt(Data(text.utf8), passphrase: "long-valid-passphrase")
        }
    }

    @Test("rejects passphrases shorter than minimumPassphraseLength")
    func rejectsShortPassphrase() {
        let encryptor = CryptoKitRoomExportEncryptor(iterations: 1_000)
        #expect(throws: HaloError.self) {
            _ = try encryptor.encrypt(Data("data".utf8), passphrase: "short")
        }
    }
}
