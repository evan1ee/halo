/// Fan-out of a "latest value wins" state to any number of subscribers. Not thread-safe: owned by
/// one actor, which calls it only from its own isolation.
struct SnapshotBroadcaster<Value: Sendable> {
    private var continuations: [Int: AsyncStream<Value>.Continuation] = [:]
    private var nextID = 0

    /// A stream that starts with `current` and then receives every published value. Single-value
    /// snapshot stream, so `.bufferingNewest(1)` is allowed (CONCURRENCY §3).
    mutating func subscribe(current: Value) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(current)
        continuations[nextID] = continuation
        nextID += 1
        return stream
    }

    /// Sends `value` to every live subscriber and forgets the ones whose stream has ended.
    mutating func publish(_ value: Value) {
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) { continuations[id] = nil }
        }
    }

    mutating func finishAll() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }
}
