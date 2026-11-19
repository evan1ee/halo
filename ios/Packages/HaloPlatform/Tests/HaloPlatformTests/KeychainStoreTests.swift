import Foundation
import HaloDomain
import HaloFoundation
import Security
import Testing
@testable import HaloPlatform

@Suite("KeychainStore")
struct KeychainStoreTests {
    private func store() -> KeychainStore {
        KeychainStore(service: "one.mbm.halo.tests.\(UUID().uuidString)", accessGroup: nil)
    }

    @Test("a missing item reads as nil and deleting it succeeds")
    func missing() async throws {
        let store = store()
        #expect(try await store.read(.session) == nil)
        try await store.delete(.session)
    }

    @Test("write, overwrite, read and delete round-trip")
    func roundTrip() async throws {
        let store = store()
        try await store.write(Data("one".utf8), for: .session)
        try await store.write(Data("two".utf8), for: .session)
        #expect(try await store.read(.session) == Data("two".utf8))
        try await store.delete(.session)
        #expect(try await store.read(.session) == nil)
    }

    @Test("account-scoped items are separate per account and never use the raw user ID in their name")
    func accountScoping() async throws {
        let store = store()
        let alice = try UserID("@alice:example.org")
        let bob = try UserID("@bob:example.org")
        try await store.write(Data("a".utf8), for: .sdkStorePassphrase(alice))
        try await store.write(Data("b".utf8), for: .sdkStorePassphrase(bob))
        #expect(try await store.read(.sdkStorePassphrase(alice)) == Data("a".utf8))
        #expect(try await store.read(.sdkStorePassphrase(bob)) == Data("b".utf8))
        #expect(try await store.read(.haloDatabaseKey(alice)) == nil)
        #expect(!KeychainStore.accountName(.sdkStorePassphrase(alice)).contains("alice"))
        try await store.delete(.sdkStorePassphrase(alice))
        try await store.delete(.sdkStorePassphrase(bob))
    }

    @Test("a locked Keychain is unavailable, not missing")
    func statusMapping() {
        #expect(KeychainStore.map(errSecInteractionNotAllowed) == .storage(.unavailable))
        #expect(KeychainStore.map(errSecDecode) == .storage(.corrupted))
        #expect(KeychainStore.map(-1) == .internal(code: "KEYCHAIN_-1"))
    }
}
