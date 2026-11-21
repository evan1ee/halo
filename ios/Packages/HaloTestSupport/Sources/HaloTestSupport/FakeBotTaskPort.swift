import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `BotTaskPort` with the store's rules: a newer-or-equal `asOf` replaces, a missing source keeps the stored one.
public final class FakeBotTaskPort: BotTaskPort {
    private let state = Mutex<(entries: [BotTaskEntry.Key: BotTaskEntry], upserts: Int, error: HaloError?)>(([:], 0, nil))

    public init() {}

    /// Makes every following call throw (nil: stop failing).
    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    /// How many `upsert` calls arrived (including empty ones that were skipped by callers).
    public var upsertCalls: Int { state.withLock { $0.upserts } }

    public func upsert(_ entries: [BotTaskEntry]) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { state in
            state.upserts += 1
            for entry in entries {
                if let stored = state.entries[entry.key] {
                    guard entry.asOf >= stored.asOf else { continue }
                    var merged = entry
                    if merged.sourceEventID == nil { merged.sourceEventID = stored.sourceEventID }
                    state.entries[entry.key] = merged
                } else {
                    state.entries[entry.key] = entry
                }
            }
        }
    }

    public func entries() async throws(HaloError) -> [BotTaskEntry] {
        let (all, error) = state.withLock { (Array($0.entries.values), $0.error) }
        if let error { throw error }
        return all.sorted { ($0.asOf, $1.key) > ($1.asOf, $0.key) }
    }

    public func removeAll() async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.entries = [:] }
    }
}
