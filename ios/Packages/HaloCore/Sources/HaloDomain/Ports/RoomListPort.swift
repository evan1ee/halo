import HaloFoundation

/// The ordered room list (docs/matrix/PORTS_CONTRACT.md §2). Implemented by `HaloMatrixAdapter`
/// over `RoomListService`; faked in `HaloTestSupport`.
public protocol RoomListPort: Sendable {
    /// The room list as lossless diffs (apply with `RoomListReducer`) and the sync responses they include, in one ordered
    /// stream: `.synced` arrives after every diff its response caused, so "sync has completed" never overtakes the list
    /// it describes (R-04). The first element puts the consumer in a known state (a `.reset`, or an `.append` onto an
    /// empty list). Every subscription starts over from such a state.
    func updates(filter: RoomListFilter) -> AsyncStream<RoomListUpdate>
    /// Extends the visible window by one page (ROOM_LIST FR-1).
    func loadMore() async throws(HaloError)
    /// Changes the filter of the current subscription; the stream then continues with diffs for it.
    func setFilter(_ filter: RoomListFilter) async throws(HaloError)
    /// Rooms the server reported as left/kicked/banned in sync (`rooms.left`), so dependent state (such as notification
    /// records) can be pruned (R-03).
    func leftRooms() -> AsyncStream<Set<RoomID>>
}

/// One element of `RoomListPort.updates(filter:)`.
public enum RoomListUpdate: Sendable {
    case diff(RoomListDiff)
    /// Several diffs that only make sense together (a room moving is a remove and an insert); applied as one change, so no
    /// list between them is ever shown (M19-3). The first update of a subscription is still a `.diff(.reset)`.
    case diffs([RoomListDiff])
    /// A sync response has been applied; carries the complete set of joined/invited rooms the SDK knows at that point.
    case synced(Set<RoomID>)
}

public extension RoomListPort {
    func leftRooms() -> AsyncStream<Set<RoomID>> { AsyncStream { $0.finish() } }

    /// Only the diffs of `updates(filter:)`.
    func rooms(filter: RoomListFilter) -> AsyncStream<RoomListDiff> {
        let updates = updates(filter: filter)
        return AsyncStream { continuation in
            let task = Task {
                for await update in updates {
                    switch update {
                    case .diff(let diff): continuation.yield(diff)
                    case .diffs(let diffs): for diff in diffs { continuation.yield(diff) }
                    case .synced: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
