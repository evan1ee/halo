import HaloDomain
import HaloFoundation

/// Keeps the app badge equal to the number of rooms that need attention, recomputed from the read states on every
/// change (D5, D9: never incremented). One writer in the app; the notification extension only adds a room it just
/// fetched (UNREAD_STATE §2, C5).
public actor BadgeCoordinator {
    public private(set) var attentionRooms: Set<RoomID> = []
    /// The first evaluation always writes, even an empty set: the extension may have added rooms to the badge while
    /// the app wasn't running, and only a recomputation can take them away again.
    private var hasWritten = false

    private let rooms: RoomListCoordinator
    private let port: any BadgePort
    private var task: Task<Void, Never>?

    public init(rooms: RoomListCoordinator, port: any BadgePort) {
        self.rooms = rooms
        self.port = port
    }

    deinit { task?.cancel() }

    /// Starts following the room list. Call once at launch.
    public func begin() async {
        guard task == nil else { return }
        let states = await rooms.readStates()
        task = Task { [weak self] in
            for await states in states { await self?.apply(states) }
        }
    }

    /// The badge value for the current states.
    public var badge: Int { attentionRooms.count }

    private func apply(_ states: [RoomReadState]) async {
        let attention = Set(states.filter(\.attention).map(\.roomID))
        guard attention != attentionRooms || !hasWritten else { return }
        hasWritten = true
        attentionRooms = attention
        await port.update(attentionRooms: attention)
    }
}
