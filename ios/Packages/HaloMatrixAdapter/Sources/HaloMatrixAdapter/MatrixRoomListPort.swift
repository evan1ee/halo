import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `RoomListPort` over `RoomListService.allRooms()` with dynamic adapters (SDK_INTEGRATION §6).
///
/// Raw SDK diffs are queued in arrival order by the listener (which never blocks the SDK thread,
/// AGENTS.md §8) and mapped to domain diffs by one consumer task, so order is preserved.
public final class MatrixRoomListPort: RoomListPort {
    private struct Subscription {
        let id: UUID
        let controller: RoomListDynamicEntriesController
    }

    private let session: MatrixSessionPort
    private let pageSize: UInt32
    private let current = Mutex<Subscription?>(nil)

    public init(session: MatrixSessionPort, pageSize: UInt32 = 50) {
        self.session = session
        self.pageSize = pageSize
    }

    public func rooms(filter: RoomListFilter) -> AsyncStream<RoomListDiff> {
        let (output, continuation) = AsyncStream<RoomListDiff>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let task = Task { [session, pageSize] in
            let (raw, rawContinuation) = AsyncStream<[RoomListEntriesUpdate]>.makeStream(bufferingPolicy: .unbounded)
            do {
                let kind = try Self.kind(for: filter)
                let service = try await session.roomListService()
                let list = try await service.allRooms()
                let result = list.entriesWithDynamicAdapters(pageSize: pageSize, listener: Listener(rawContinuation))
                let controller = result.controller()
                _ = controller.setFilter(kind: kind)
                current.withLock { $0 = Subscription(id: id, controller: controller) }
                // Keeps the SDK subscription alive until this task ends.
                let handle = result.entriesStream()
                defer { handle.cancel() }
                for await updates in raw {
                    for update in updates { continuation.yield(try await Self.map(update)) }
                }
            } catch {
                // The stream ends; the consumer resubscribes (RoomListCoordinator) and gets a fresh `.reset`.
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            self?.current.withLock { if $0?.id == id { $0 = nil } }
        }
        return output
    }

    public func loadMore() async throws(HaloError) {
        guard let subscription = current.withLock({ $0 }) else { throw .internal(code: "NO_ROOM_LIST_SUBSCRIPTION") }
        subscription.controller.addOnePage()
    }

    public func setFilter(_ filter: RoomListFilter) async throws(HaloError) {
        guard let subscription = current.withLock({ $0 }) else { throw .internal(code: "NO_ROOM_LIST_SUBSCRIPTION") }
        _ = subscription.controller.setFilter(kind: try Self.kind(for: filter))
    }

    // MARK: Mapping

    /// `.unread` needs read-state inputs and arrives with the unread engine (M1); asking for it now is
    /// an explicit error, not a silently wrong list.
    static func kind(for filter: RoomListFilter) throws(HaloError) -> RoomListEntriesDynamicFilterKind {
        switch filter {
        case .all: .all(filters: [.nonSpace, .nonLeft])
        case .favourites: .all(filters: [.nonSpace, .nonLeft, .favourite])
        case .invites: .invite
        case .people: .all(filters: [.nonSpace, .nonLeft, .category(expect: .people)])
        case .rooms: .all(filters: [.nonSpace, .nonLeft, .category(expect: .group)])
        case .unread: throw .unsupported("FILTER_UNREAD_M1")
        }
    }

    static func map(_ update: RoomListEntriesUpdate) async throws(HaloError) -> RoomListDiff {
        switch update {
        case .append(let rooms): .append(try await summaries(rooms))
        case .clear: .clear
        case .pushFront(let room): .pushFront(try await summary(room))
        case .pushBack(let room): .pushBack(try await summary(room))
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let room): .insert(index: Int(index), try await summary(room))
        case .set(let index, let room): .set(index: Int(index), try await summary(room))
        case .remove(let index): .remove(index: Int(index))
        case .truncate(let length): .truncate(length: Int(length))
        case .reset(let rooms): .reset(try await summaries(rooms))
        }
    }

    private static func summaries(_ rooms: [Room]) async throws(HaloError) -> [RoomSummary] {
        var result: [RoomSummary] = []
        result.reserveCapacity(rooms.count)
        for room in rooms { result.append(try await summary(room)) }
        return result
    }

    static func summary(_ room: Room) async throws(HaloError) -> RoomSummary {
        // An unparseable ID is a contract break with the SDK: fail the subscription instead of dropping a
        // row, which would shift every later index.
        try RoomSummary(
            id: RoomID(room.id()),
            name: room.displayName(),
            isDirect: await room.isDirect(),
            isEncrypted: await room.isEncrypted(),
            membership: membership(room.membership())
        )
    }

    static func membership(_ value: MatrixRustSDK.Membership) -> HaloDomain.Membership {
        switch value {
        case .invited: .invited
        case .joined: .joined
        case .left: .left
        case .knocked: .knocked
        case .banned: .banned
        }
    }
}

private final class Listener: RoomListEntriesListener {
    private let continuation: AsyncStream<[RoomListEntriesUpdate]>.Continuation
    init(_ continuation: AsyncStream<[RoomListEntriesUpdate]>.Continuation) { self.continuation = continuation }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) { continuation.yield(roomEntriesUpdate) }
}
