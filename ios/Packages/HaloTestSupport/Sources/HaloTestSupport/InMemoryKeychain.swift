import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// A `KeychainPort` backed by a dictionary. `isUnavailable` simulates the Keychain before the first unlock.
public final class InMemoryKeychain: KeychainPort {
    private struct State {
        var items: [KeychainItem: Data] = [:]
        var isUnavailable = false
        var failWrites = false
    }

    private let state = Mutex(State())

    public init() {}

    public var isUnavailable: Bool {
        get { state.withLock { $0.isUnavailable } }
        set { state.withLock { $0.isUnavailable = newValue } }
    }

    /// Makes writes fail with `.storage(.unavailable)` while reads still work.
    public var failWrites: Bool {
        get { state.withLock { $0.failWrites } }
        set { state.withLock { $0.failWrites = newValue } }
    }

    public func stored(_ item: KeychainItem) -> Data? { state.withLock { $0.items[item] } }
    public func store(_ data: Data, for item: KeychainItem) { state.withLock { $0.items[item] = data } }

    public func read(_ item: KeychainItem) async throws(HaloError) -> Data? {
        try state.withLock { (state) throws(HaloError) in
            if state.isUnavailable { throw .storage(.unavailable) }
            return state.items[item]
        }
    }

    public func write(_ data: Data, for item: KeychainItem) async throws(HaloError) {
        try state.withLock { (state) throws(HaloError) in
            if state.isUnavailable || state.failWrites { throw .storage(.unavailable) }
            state.items[item] = data
        }
    }

    public func delete(_ item: KeychainItem) async throws(HaloError) {
        try state.withLock { (state) throws(HaloError) in
            if state.isUnavailable { throw .storage(.unavailable) }
            state.items[item] = nil
        }
    }
}
