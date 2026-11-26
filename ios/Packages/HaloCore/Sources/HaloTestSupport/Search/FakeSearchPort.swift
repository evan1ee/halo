import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `SearchPort`: a substring search over a corpus, newest first. `hold` keeps answers back until `release`, so tests can make
/// an answer arrive late.
public final class FakeSearchPort: SearchPort {
    private struct State {
        var nextError: HaloError?
        var queries: [SearchQuery] = []
        var recheckBatches: [[MessageSearchHit]] = []
        var remoteRechecks: [String: SearchRecheck] = [:]
        var held: [String: [CheckedContinuation<Void, Never>]] = [:]
        var holds: Set<String> = []
        var heldRechecks: [CheckedContinuation<Void, Never>] = []
        var holdsRechecks = false
    }

    private let corpus: [MessageSearchHit]
    private let pageSize: Int
    private let state = Mutex(State())

    public init(corpus: [MessageSearchHit] = [], pageSize: Int = 20) {
        self.corpus = corpus.sorted { $0.timestamp > $1.timestamp }
        self.pageSize = max(1, pageSize)
    }

    public func failNext(with error: HaloError) { state.withLock { $0.nextError = error } }
    public var queries: [SearchQuery] { state.withLock { $0.queries } }
    public var recheckBatches: [[MessageSearchHit]] { state.withLock { $0.recheckBatches } }

    /// Configures a remote server recheck outcome (`.edited` or `.gone`) for `hitID` (`MessageSearchHit.id`).
    public func setRemoteRecheck(_ result: SearchRecheck, for hitID: String) {
        state.withLock { $0.remoteRechecks[hitID] = result }
    }

    /// Holds background `recheck` calls until `releaseRechecks()`.
    public func holdRechecks() { state.withLock { $0.holdsRechecks = true } }

    public var isHoldingRecheck: Bool { state.withLock { !$0.heldRechecks.isEmpty } }

    public func releaseRechecks() {
        let waiting = state.withLock { state in
            state.holdsRechecks = false
            defer { state.heldRechecks = [] }
            return state.heldRechecks
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Answers to `text` wait for `release`.
    public func hold(_ text: String) { state.withLock { _ = $0.holds.insert(text) } }

    public func release(_ text: String) {
        let waiting = state.withLock { state in
            state.holds.remove(text)
            return state.held.removeValue(forKey: text) ?? []
        }
        for continuation in waiting { continuation.resume() }
    }

    public func isHolding(_ text: String) -> Bool { state.withLock { !($0.held[text] ?? []).isEmpty } }

    public func search(_ query: SearchQuery, after cursor: SearchCursor?) async throws(HaloError) -> SearchPage {
        state.withLock { $0.queries.append(query) }
        await withCheckedContinuation { continuation in
            let waits = state.withLock { state in
                guard state.holds.contains(query.text) else { return false }
                state.held[query.text, default: []].append(continuation)
                return true
            }
            if !waits { continuation.resume() }
        }
        if let error = state.withLock({ state in
            defer { state.nextError = nil }
            return state.nextError
        }) { throw error }
        guard !query.text.isEmpty else { return SearchPage(hits: [], next: nil) }
        let matching = corpus.filter { hit in
            hit.body.localizedCaseInsensitiveContains(query.text) && (query.room == nil || hit.roomID == query.room) && query.filter.kinds.contains(hit.kind)
        }
        let start = Int(cursor?.row ?? 0), end = min(start + pageSize, matching.count)
        guard start < end else { return SearchPage(hits: [], next: nil) }
        return SearchPage(hits: Array(matching[start..<end]), next: end < matching.count ? SearchCursor(timestamp: 0, row: Int64(end)) : nil)
    }

    public func recheck(_ hits: [MessageSearchHit]) async throws(HaloError) -> [String: SearchRecheck] {
        if Task.isCancelled { throw .cancelled }
        state.withLock { $0.recheckBatches.append(hits) }
        await withCheckedContinuation { continuation in
            let waits = state.withLock { state in
                guard state.holdsRechecks else { return false }
                state.heldRechecks.append(continuation)
                return true
            }
            if !waits { continuation.resume() }
        }
        if Task.isCancelled { throw .cancelled }
        return state.withLock { state in
            var deltas: [String: SearchRecheck] = [:]
            for hit in hits {
                if let result = state.remoteRechecks[hit.id] {
                    deltas[hit.id] = result
                }
            }
            return deltas
        }
    }
}
