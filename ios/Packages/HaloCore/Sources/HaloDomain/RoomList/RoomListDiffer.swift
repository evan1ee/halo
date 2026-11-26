import Foundation

/// The diffs that turn one room list into the next (ROADMAP M19-3, ROOM_LIST §4): a room that changed is one `set`, a room that
/// moved is one `remove` and one `insert`, a new or gone room is one `insert` or `remove`. Applying them in order to `old` gives
/// `new` exactly, so the order stays the SDK's (AC-RL-2) and no room is listed twice.
public enum RoomListDiffer {
    /// When the change needs more than this share of the list in operations, one `reset` is cheaper and clearer.
    static let resetShare = 0.5

    public static func diffs(from old: [RoomSummary], to new: [RoomSummary]) -> [RoomListDiff] {
        guard !old.isEmpty else { return new.isEmpty ? [] : [.reset(new)] }
        guard old != new else { return [] }
        var ops: [RoomListDiff] = []
        var current = old
        let wanted = Set(new.map(\.id))
        for index in current.indices.reversed() where !wanted.contains(current[index].id) {
            ops.append(.remove(index: index))
            current.remove(at: index)
        }
        let budget = max(8, Int(Double(max(old.count, new.count)) * resetShare))
        for (index, room) in new.enumerated() {
            if index < current.count, current[index].id == room.id {
                if current[index] != room {
                    ops.append(.set(index: index, room))
                    current[index] = room
                }
            } else {
                if let from = current[(index < current.count ? index : current.count)...].firstIndex(where: { $0.id == room.id }) {
                    ops.append(.remove(index: from))
                    current.remove(at: from)
                }
                ops.append(.insert(index: index, room))
                current.insert(room, at: min(index, current.count))
            }
            if ops.count > budget { return [.reset(new)] }
        }
        return ops
    }
}
