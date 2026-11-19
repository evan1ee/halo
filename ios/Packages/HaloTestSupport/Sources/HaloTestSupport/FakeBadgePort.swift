import HaloDomain
import HaloFoundation
import Synchronization

/// Records the attention sets it was given.
public final class FakeBadgePort: BadgePort {
    private let updates = Mutex<[Set<RoomID>]>([])

    public init() {}

    public var history: [Set<RoomID>] { updates.withLock { $0 } }
    public var badge: Int { updates.withLock { $0.last?.count ?? 0 } }

    public func update(attentionRooms: Set<RoomID>) async { updates.withLock { $0.append(attentionRooms) } }
}
