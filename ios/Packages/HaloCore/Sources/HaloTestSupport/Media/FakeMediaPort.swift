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
        var fileCalls = 0
        var nextError: HaloError?
        var fileGate: CheckedContinuation<Void, Never>?
        var holdNextFile = false
        var fileHoldCancelled = false
    }

    private let state = Mutex(State())

    public init() {}

    public func add(_ ref: MediaRef, data: Data) { state.withLock { $0.items[ref] = data } }
    public func failNext(with error: HaloError) { state.withLock { $0.nextError = error } }
    /// Holds the next `file(...)` call until `releaseHeldFile()` is called or the calling task is cancelled.
    public func holdNextFile() {
        state.withLock {
            $0.holdNextFile = true
            $0.fileHoldCancelled = false
        }
    }
    public func releaseHeldFile() {
        let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.holdNextFile = false
            if let gate = state.fileGate {
                state.fileGate = nil
                return gate
            }
            state.fileHoldCancelled = true
            return nil
        }
        gate?.resume()
    }
    public var thumbnailCalls: Int { state.withLock { $0.thumbnailCalls } }
    public var contentCalls: Int { state.withLock { $0.contentCalls } }
    public var fileCalls: Int { state.withLock { $0.fileCalls } }

    public func thumbnail(_ ref: MediaRef, width: Int, height: Int) async throws(HaloError) -> Data {
        try await fetch(ref, kind: .thumbnail)
    }

    public func content(_ ref: MediaRef) async throws(HaloError) -> Data {
        try await fetch(ref, kind: .content)
    }

    public func file(_ ref: MediaRef, name: String, mimeType: String?, in directory: URL) async throws(HaloError) -> URL {
        let shouldHold = state.withLock { state -> Bool in
            if state.holdNextFile {
                state.holdNextFile = false
                return true
            }
            return false
        }
        if shouldHold {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.fileHoldCancelled {
                            state.fileHoldCancelled = false
                            return true
                        }
                        state.fileGate = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: { [weak self] in
                self?.releaseHeldFile()
            }
            if Task.isCancelled { throw .cancelled }
        }
        let data = try await fetch(ref, kind: .file)
        if Task.isCancelled { throw .cancelled }
        let url = directory.appendingPathComponent(Self.safeFileName(name))
        do { try data.write(to: url, options: .atomic) } catch { throw .storage(.unavailable) }
        return url
    }

    private enum Kind { case thumbnail, content, file }

    private func fetch(_ ref: MediaRef, kind: Kind) async throws(HaloError) -> Data {
        // Yield once so concurrent callers genuinely overlap (exercises in-flight deduplication).
        await Task.yield()
        return try state.withLock { (state) throws(HaloError) in
            switch kind {
            case .thumbnail: state.thumbnailCalls += 1
            case .content: state.contentCalls += 1
            case .file: state.fileCalls += 1
            }
            if let error = state.nextError {
                state.nextError = nil
                throw error
            }
            guard let data = state.items[ref] else { throw .notFound }
            return data
        }
    }
}
