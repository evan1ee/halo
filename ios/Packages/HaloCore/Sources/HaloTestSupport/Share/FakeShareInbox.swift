import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory `ShareInboxPort`.
public final class FakeShareInbox: ShareInboxPort {
    private struct State {
        var payloads: [SharePayload] = []
        var files: [String: Data] = [:]
        var discarded: [String] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func stage(_ payload: SharePayload, files: [String: Data] = [:]) {
        state.withLock {
            $0.payloads.append(payload)
            $0.files.merge(files) { $1 }
        }
    }

    public var discarded: [String] { state.withLock { $0.discarded } }

    public func pending() throws(HaloError) -> [SharePayload] { state.withLock { $0.payloads } }

    public func data(of item: SharedItem, in payload: SharePayload) throws(HaloError) -> Data {
        guard let data = state.withLock({ $0.files[item.id] }) else { throw .notFound }
        return data
    }

    public func discard(_ payload: SharePayload) {
        state.withLock {
            $0.payloads.removeAll { $0.id == payload.id }
            $0.discarded.append(payload.id)
        }
    }
}
