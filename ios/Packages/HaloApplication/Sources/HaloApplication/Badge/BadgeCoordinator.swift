import Foundation
import HaloDomain
import HaloFoundation

/// Keeps the app badge equal to the number of rooms that need attention, recomputed from the room list's read inputs
/// and the notification records on every change (D5, D9: never incremented). Because Synapse's native sliding sync
/// serves no notification counts (V-RS-7), the room list alone can't show unread: a notifying event the extension
/// fetched is a record (rule E4) that counts until the user reads the room here. The extension doesn't write the
/// badge from its own counter: it recomputes the same union (UNREAD_STATE §2, C5).
public actor BadgeCoordinator {
    public private(set) var attentionRooms: Set<RoomID> = []
    /// The first evaluation always writes, even an empty set, so a stale badge can be cleared.
    private var hasWritten = false

    private let rooms: RoomListCoordinator
    private let records: any NotificationRecordPort
    private let port: any BadgePort
    private var inputs: [RoomReadInputs] = []
    private var tasks: [Task<Void, Never>] = []

    public init(rooms: RoomListCoordinator, records: any NotificationRecordPort, port: any BadgePort) {
        self.rooms = rooms
        self.records = records
        self.port = port
    }

    deinit { for task in tasks { task.cancel() } }

    /// Starts following the room list and the records. Call once at launch.
    public func begin() async {
        guard tasks.isEmpty else { return }
        let roomInputs = await rooms.readInputs()
        let changes = records.changes()
        tasks = [
            Task { [weak self] in for await inputs in roomInputs { await self?.roomsChanged(inputs) } },
            Task { [weak self] in for await _ in changes { await self?.recompute() } },
        ]
    }

    /// The badge value for the current states.
    public var badge: Int { attentionRooms.count }

    /// The attention set for `inputs` and `records`: every room whose state needs attention, plus rooms that have
    /// records but aren't in the loaded list (their only evidence is the push).
    public static func attention(inputs: [RoomReadInputs], records: [NotificationRecord]) -> Set<RoomID> {
        let byRoom = Dictionary(grouping: records, by: \.roomID)
        var result: Set<RoomID> = []
        for input in inputs {
            let notified = (byRoom[input.roomID] ?? []).map { NotifiedRef(timestamp: $0.timestamp, isMention: $0.isMention) }
            let state = ReadStatePolicy.evaluate(RoomReadInputs(
                roomID: input.roomID, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
                latestEvent: input.latestEvent, localIntent: input.localIntent, unconfirmedNotified: notified))
            if state.attention { result.insert(input.roomID) }
        }
        let known = Set(inputs.map(\.roomID))
        for room in byRoom.keys where !known.contains(room) { result.insert(room) }
        return result
    }

    private func roomsChanged(_ inputs: [RoomReadInputs]) async {
        self.inputs = inputs
        await recompute()
    }

    private func recompute() async {
        let attention = Self.attention(inputs: inputs, records: records.all())
        guard attention != attentionRooms || !hasWritten else { return }
        hasWritten = true
        attentionRooms = attention
        await port.update(attentionRooms: attention)
    }
}
