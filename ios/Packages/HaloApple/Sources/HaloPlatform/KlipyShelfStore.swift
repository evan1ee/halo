import CryptoKit
import Foundation
import HaloDomain
import HaloFoundation

/// `KlipyShelfPort` in `UserDefaults` (D98): the account's KLIPY favourites and recents as JSON — item metadata and
/// URLs only, never media. Keyed by a hash of the account, so no Matrix ID is written even as a key (AGENTS §4.6).
public struct KlipyShelfStore: KlipyShelfPort, @unchecked Sendable {
    // @unchecked: UserDefaults is documented thread-safe; the struct holds nothing else mutable.
    private let defaults: UserDefaults
    let key: String

    public init(account: UserID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let digest = SHA256.hash(data: Data(account.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        key = "halo.klipy.shelf." + digest.prefix(32)
    }

    public func load() async -> KlipyShelf {
        guard let data = defaults.data(forKey: key), let shelf = try? JSONDecoder().decode(KlipyShelf.self, from: data) else { return KlipyShelf() }
        return shelf
    }

    public func save(_ shelf: KlipyShelf) async {
        guard let data = try? JSONEncoder().encode(shelf) else { return }
        defaults.set(data, forKey: key)
    }
}
