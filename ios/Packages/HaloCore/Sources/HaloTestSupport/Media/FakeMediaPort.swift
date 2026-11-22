import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory `MediaPort`. Unknown references are `.notFound`; `delay` lets tests hold a download open.
public final class FakeMediaPort: MediaPort {
    private struct State {
        var items: [MediaRef: Data] = [:]
        var thumbnailCalls = 0
        var contentCalls = 0
        var nextError: HaloError?
    }

    private let state = Mutex(State())

    public init() {}

    public func add(_ ref: MediaRef, data: Data) { state.withLock { $0.items[ref] = data } }
    public func failNext(with error: HaloError) { state.withLock { $0.nextError = error } }
    public var thumbnailCalls: Int { state.withLock { $0.thumbnailCalls } }
    public var contentCalls: Int { state.withLock { $0.contentCalls } }

    public func thumbnail(_ ref: MediaRef, width: Int, height: Int) async throws(HaloError) -> Data {
        try await fetch(ref, thumbnail: true)
    }

    public func content(_ ref: MediaRef) async throws(HaloError) -> Data {
        try await fetch(ref, thumbnail: false)
    }

    private func fetch(_ ref: MediaRef, thumbnail: Bool) async throws(HaloError) -> Data {
        // Yield once so concurrent callers genuinely overlap (exercises in-flight deduplication).
        await Task.yield()
        return try state.withLock { (state) throws(HaloError) in
            if thumbnail { state.thumbnailCalls += 1 } else { state.contentCalls += 1 }
            if let error = state.nextError {
                state.nextError = nil
                throw error
            }
            guard let data = state.items[ref] else { throw .notFound }
            return data
        }
    }
}
