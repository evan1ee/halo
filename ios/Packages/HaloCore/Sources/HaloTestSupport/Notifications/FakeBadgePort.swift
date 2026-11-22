import HaloDomain
import HaloFoundation
import Synchronization

/// Records the per-room badge counts it was given (D82).
public final class FakeBadgePort: BadgePort {
    private let updates = Mutex<[[RoomID: Int]]>([])

    public init() {}

    public var countsHistory: [[RoomID: Int]] { updates.withLock { $0 } }
    public var history: [Set<RoomID>] { updates.withLock { $0.map { Set($0.keys) } } }
    public var badge: Int { updates.withLock { $0.last?.values.reduce(0, +) ?? 0 } }

    public func update(attentionCounts: [RoomID: Int]) async { updates.withLock { $0.append(attentionCounts) } }
    public func lastAttention() async -> [RoomID: Int] { updates.withLock { $0.last ?? [:] } }
    public func reset() async { updates.withLock { $0.append([:]) } }
    /// Seeds what an earlier launch stored.
    public func preload(_ counts: [RoomID: Int]) { updates.withLock { $0 = [counts] } }
    /// Convenience: seeds stored rooms with a count of 1 each.
    public func preload(_ rooms: Set<RoomID>) { preload(Dictionary(uniqueKeysWithValues: rooms.map { ($0, 1) })) }
}
