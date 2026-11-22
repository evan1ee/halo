import HaloFoundation
import HaloDomain
import Synchronization

/// A `HiddenRoomsPort` whose answer the test sets.
public final class FakeHiddenRooms: HiddenRoomsPort {
    private let rooms: Mutex<Set<RoomID>>
    public init(_ rooms: Set<RoomID> = []) { self.rooms = Mutex(rooms) }
    public func set(_ value: Set<RoomID>) { rooms.withLock { $0 = value } }
    public func hiddenRooms() async -> Set<RoomID> { rooms.withLock { $0 } }
}
