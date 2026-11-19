import HaloFoundation

/// The ordered room list (docs/matrix/PORTS_CONTRACT.md §2). Implemented by `HaloMatrixAdapter`
/// over `RoomListService`; faked in `HaloTestSupport`.
public protocol RoomListPort: Sendable {
    /// The room list as lossless diffs (apply with `RoomListReducer`). The first element puts the
    /// consumer in a known state (`.reset`, or `.append` onto an empty list). Every subscription
    /// starts over from such a state.
    func rooms(filter: RoomListFilter) -> AsyncStream<RoomListDiff>
    /// Extends the visible window by one page (ROOM_LIST FR-1).
    func loadMore() async throws(HaloError)
    /// Changes the filter of the current subscription; the stream then continues with diffs for it.
    func setFilter(_ filter: RoomListFilter) async throws(HaloError)
}
