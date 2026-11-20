import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `RoomListPort` over the client's rooms and the classic sync loop (D73, V-RS-7; SDK_INTEGRATION §6): `Client.rooms()` is
/// every known room, a sync response names the rooms it changed, and only those summaries are rebuilt. The list is
/// ordered by the latest event (invites first) and every change is published as a `.reset` of the whole list, which
/// the coordinator's reducer applies like any other diff. There is nothing to page: all rooms are present at once.
public final class MatrixRoomListPort: RoomListPort {
    private struct Subscription {
        let id: UUID
        let refresh: AsyncStream<Void>.Continuation
        let filter: FilterBox
    }

    private final class FilterBox: Sendable {
        private let value: Mutex<RoomListFilter>
        init(_ filter: RoomListFilter) { value = Mutex(filter) }
        var current: RoomListFilter { get { value.withLock { $0 } } set { value.withLock { $0 = newValue } } }
    }

    private let session: MatrixSessionPort
    private let current = Mutex<Subscription?>(nil)

    public init(session: MatrixSessionPort, pageSize: UInt32 = 50) { self.session = session }

    public func rooms(filter: RoomListFilter) -> AsyncStream<RoomListDiff> {
        let (output, continuation) = AsyncStream<RoomListDiff>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let (refresh, refreshContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let filterBox = FilterBox(filter)
        let task = Task { [session] in
            do {
                _ = try Self.kind(for: filter)
                let client = try await session.signedInClient()
                let settings = await client.getNotificationSettings()
                var summaries: [String: RoomSummary] = [:]
                var last: [RoomSummary]?
                func publish(changed: Set<String>?) async throws(HaloError) {
                    let known = client.rooms().filter { !$0.isSpace() && [.joined, .invited].contains($0.membership()) }
                    var present: Set<String> = []
                    for room in known {
                        let roomID = room.id()
                        present.insert(roomID)
                        if summaries[roomID] == nil || changed?.contains(roomID) == true { summaries[roomID] = try await Self.summary(room, settings) }
                    }
                    summaries = summaries.filter { present.contains($0.key) }
                    var list: [RoomSummary] = []
                    let chosen = filterBox.current
                    for room in known {
                        guard let summary = summaries[room.id()], try await Self.includes(chosen, room: room, summary: summary) else { continue }
                        list.append(summary)
                    }
                    list.sort(by: Self.order)
                    if list != last {
                        last = list
                        continuation.yield(.reset(list))
                    }
                }
                try await publish(changed: nil)
                let changes = await session.syncChanges()
                // Sync responses and filter changes feed one loop, so the list is rebuilt one change at a time.
                let (events, eventContinuation) = AsyncStream<Set<String>?>.makeStream(bufferingPolicy: .unbounded)
                let forward = Task {
                    for await change in changes { eventContinuation.yield(change.joined.union(change.invited).union(change.left)) }
                }
                let refreshes = Task { for await _ in refresh { eventContinuation.yield(nil) } }
                defer { forward.cancel(); refreshes.cancel(); eventContinuation.finish() }
                for await changed in events { try await publish(changed: changed) }
            } catch {
                // The stream ends; the consumer resubscribes (RoomListCoordinator) and gets a fresh `.reset`.
            }
            continuation.finish()
        }
        current.withLock { $0 = Subscription(id: id, refresh: refreshContinuation, filter: filterBox) }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            refreshContinuation.finish()
            self?.current.withLock { if $0?.id == id { $0 = nil } }
        }
        return output
    }

    /// Nothing to page: classic sync delivers every room.
    public func loadMore() async throws(HaloError) {}

    public func setFilter(_ filter: RoomListFilter) async throws(HaloError) {
        guard let subscription = current.withLock({ $0 }) else { throw .internal(code: "NO_ROOM_LIST_SUBSCRIPTION") }
        _ = try Self.kind(for: filter)
        subscription.filter.current = filter
        subscription.refresh.yield()
    }

    // MARK: Mapping

    /// `.unread` needs read-state inputs and arrives with the unread engine (M1); asking for it now is
    /// an explicit error, not a silently wrong list.
    static func kind(for filter: RoomListFilter) throws(HaloError) {
        if case .unread = filter { throw .unsupported("FILTER_UNREAD_M1") }
    }

    static func includes(_ filter: RoomListFilter, room: Room, summary: RoomSummary) async throws(HaloError) -> Bool {
        switch filter {
        case .all: return true
        case .invites: return summary.membership == .invited
        case .people: return summary.membership == .joined && summary.isDirect
        case .rooms: return summary.membership == .joined && !summary.isDirect
        case .favourites:
            guard summary.membership == .joined else { return false }
            return (try? await room.roomInfo())?.isFavourite ?? false
        case .unread: throw .unsupported("FILTER_UNREAD_M1")
        }
    }

    /// Invites first, then the newest latest event first; rooms without events last, ties by id for a stable order.
    static func order(_ a: RoomSummary, _ b: RoomSummary) -> Bool {
        let aInvite = a.membership == .invited, bInvite = b.membership == .invited
        if aInvite != bInvite { return aInvite }
        switch (a.latestEvent?.timestamp, b.latestEvent?.timestamp) {
        case (let x?, let y?) where x != y: return x > y
        case (nil, .some): return false
        case (.some, nil): return true
        default: return a.id.rawValue < b.id.rawValue
        }
    }

    static func summary(_ room: Room, _ settings: NotificationSettings) async throws(HaloError) -> RoomSummary {
        // An unparseable ID is a contract break with the SDK: fail the subscription instead of dropping a
        // row, which would shift every later index.
        let isDirect = await room.isDirect()
        let isEncrypted = await room.isEncrypted()
        let read = await readCounts(of: room, settings: settings, isEncrypted: isEncrypted, isOneToOne: isDirect)
        return try RoomSummary(
            id: RoomID(room.id()),
            name: room.displayName(),
            isDirect: isDirect,
            isEncrypted: isEncrypted,
            membership: membership(room.membership()),
            read: read,
            latestEvent: latestEvent(await room.latestEvent()),
            ownReadThrough: await ownReadThrough(of: room, counts: read),
            isFavourite: (try? await room.roomInfo())?.isFavourite ?? false
        )
    }

    /// Event id → time for resolved receipt targets; an event's time never changes.
    private static let eventTimes = Mutex<[String: Date]>([:])

    /// The time of the event the user's newest own receipt points at (read from another device). Only rooms that
    /// look unread are resolved, so quiet rooms cost nothing; a failed lookup leaves the room as unread, the safe error.
    static func ownReadThrough(of room: Room, counts: RoomReadCounts) async -> Date? {
        let looksUnread = counts.server.notification > 0 || counts.server.highlight > 0 || counts.sdk.unreadMessages > 0
            || counts.sdk.unreadNotifications > 0 || counts.isMarkedUnread
        guard looksUnread else { return nil }
        let me = room.ownUserId()
        var newest: (eventId: String, receipt: UInt64)?
        for type in [ReceiptType.read, .readPrivate] {
            guard let found = try? await room.loadUserReceipt(receiptType: type, thread: .unthreaded, userId: me) else { continue }
            let at = found.receipt.timestamp ?? 0
            if newest == nil || at >= newest!.receipt { newest = (found.eventId, at) }
        }
        guard let eventId = newest?.eventId else { return nil }
        if let known = eventTimes.withLock({ $0[eventId] }) { return known }
        guard let event = try? await room.loadOrFetchEvent(eventId: eventId) else { return nil }
        let time = Date(timeIntervalSince1970: Double(event.timestamp()) / 1000)
        eventTimes.withLock { $0[eventId] = time }
        return time
    }

    /// The room's unread counts and effective notification mode. A mode that can't be read counts as "all messages":
    /// showing too much attention is the safe error (a missed message is worse than an extra dot).
    static func readCounts(of room: Room, settings: NotificationSettings, isEncrypted: Bool, isOneToOne: Bool) async -> RoomReadCounts {
        let info = try? await room.roomInfo()
        var mode = NotificationMode.allMessages
        if let effective = try? await settings.getRoomNotificationSettings(roomId: room.id(), isEncrypted: isEncrypted, isOneToOne: isOneToOne) {
            mode = Self.mode(effective.mode)
        }
        guard let info else { return RoomReadCounts(mode: mode, server: .zero, sdk: .zero, isMarkedUnread: false) }
        return RoomReadCounts(
            mode: mode,
            server: ServerCounts(notification: Int(info.notificationCount), highlight: Int(info.highlightCount)),
            sdk: SDKCounts(unreadMessages: Int(info.numUnreadMessages), unreadNotifications: Int(info.numUnreadNotifications), unreadMentions: Int(info.numUnreadMentions)),
            isMarkedUnread: info.isMarkedUnread)
    }

    /// The newest event for the read-state policy. Invites and rooms without events have none; a local echo is the
    /// user's own event (its time is when it was queued).
    static func latestEvent(_ value: LatestEventValue) -> LatestEventRef? {
        func date(_ ms: Timestamp) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
        switch value {
        case .none, .remoteInvite: return nil
        case .remote(let timestamp, _, let isOwn, _, _): return LatestEventRef(timestamp: date(timestamp), senderIsSelf: isOwn)
        case .local(let timestamp, _, _, _, _): return LatestEventRef(timestamp: date(timestamp), senderIsSelf: true)
        }
    }

    static func mode(_ mode: RoomNotificationMode) -> NotificationMode {
        switch mode {
        case .allMessages: .allMessages
        case .mentionsAndKeywordsOnly: .mentionsAndKeywords
        case .mute: .mute
        }
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
