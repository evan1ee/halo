import HaloFoundation

/// Opens the timeline of one room (docs/matrix/PORTS_CONTRACT.md §2). Implemented by
/// `HaloMatrixAdapter`; faked in `HaloTestSupport`. M1 surface: read-only.
public protocol TimelinePort: Sendable {
    /// Opens `room`'s timeline. Throws `.notFound` if the client doesn't know the room.
    func open(room: RoomID) async throws(HaloError) -> any TimelineSession
}

/// One open timeline. Closing (or dropping) it cancels every upstream subscription.
public protocol TimelineSession: Sendable {
    /// The timeline as lossless, ordered diffs (apply with `ListReducer`). The first element is a `.reset`
    /// or an `.append` onto an empty list; a new call starts over from such a state.
    func items() -> AsyncStream<TimelineDiff>

    /// Loads up to `count` older events. Returns `true` when the start of the room has been reached.
    func paginateBackwards(count: UInt16) async throws(HaloError) -> Bool

    func close() async
}
