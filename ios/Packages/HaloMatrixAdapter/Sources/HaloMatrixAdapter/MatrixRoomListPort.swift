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

    final class EventTimeCache: Sendable {
        private let entries = Mutex<[String: Date]>([:])
        private let limit: Int

        init(limit: Int = 2_000) { self.limit = limit }

        func get(_ key: String) -> Date? { entries.withLock { $0[key] } }

        func set(_ key: String, _ value: Date) {
            entries.withLock { cache in
                if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
                cache[key] = value
            }
        }

        func clear() { entries.withLock { $0.removeAll() } }
    }

    private let session: MatrixSessionPort
    private let hasRecords: @Sendable (RoomID) -> Bool
    private let current = Mutex<Subscription?>(nil)
    private let leftObservers = Mutex<[UUID: AsyncStream<Set<RoomID>>.Continuation]>([:])
    private let syncObservers = Mutex<[UUID: AsyncStream<Set<RoomID>>.Continuation]>([:])
    /// Instance-scoped, bounded event id → time cache for resolved receipt targets (R-27); cleared on stream end.
    private let eventTimes = EventTimeCache()

    public init(session: MatrixSessionPort, pageSize: UInt32 = 50, hasRecords: @escaping @Sendable (RoomID) -> Bool = { _ in false }) {
        self.session = session
        self.hasRecords = hasRecords
    }

    public func rooms(filter: RoomListFilter) -> AsyncStream<RoomListDiff> {
        let (output, continuation) = AsyncStream<RoomListDiff>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let (refresh, refreshContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let filterBox = FilterBox(filter)
        let eventTimes = self.eventTimes
        let task = Task { [session, hasRecords, eventTimes, weak self] in
            do {
                _ = try Self.kind(for: filter)
                let client = try await session.signedInClient()
                let settings = await client.getNotificationSettings()
                // Push rules arrive in top-level `account_data` (`m.push_rules`), not `response.rooms.joined`, so a
                // mode change (on this device or another) does not name the room in `SyncChange.joined` (S07b, S10).
                // `NotificationSettingsDelegate` fires whenever push rules change and triggers a full summary refresh.
                let settingsDelegate = PushRulesChangeDelegate(refresh: refreshContinuation)
                settings.setDelegate(delegate: settingsDelegate)
                defer { settings.setDelegate(delegate: nil); _ = settingsDelegate }
                var summaries: [String: RoomSummary] = [:]
                var last: [RoomSummary]?
                @discardableResult
                func publish(changed: Set<String>?, forceAll: Bool = false) async throws(HaloError) -> Set<RoomID> {
                    // Fetch `NotificationSettings` per pass so push-rule updates from sync are always visible (S07b, S10).
                    let currentSettings = await client.getNotificationSettings()
                    let known = client.rooms().filter { !$0.isSpace() && [.joined, .invited].contains($0.membership()) }
                    var present: Set<String> = []
                    var presentIDs: Set<RoomID> = []
                    var toRebuild: [(roomID: String, id: RoomID, room: Room)] = []
                    for room in known {
                        let roomID = room.id()
                        present.insert(roomID)
                        let id = try RoomID(roomID)
                        presentIDs.insert(id)
                        if forceAll || summaries[roomID] == nil || changed?.contains(roomID) == true {
                            toRebuild.append((roomID, id, room))
                        }
                    }
                    if !toRebuild.isEmpty {
                        // Bounded per-room parallelism (R-19) avoids serial FFI fan-out on large accounts
                        // without flooding the SDK's SQLite/crypto locks.
                        let rebuilt = try await Self.rebuildSummaries(
                            toRebuild, settings: currentSettings, hasRecords: hasRecords, eventTimes: eventTimes)
                        for (roomID, summary) in rebuilt { summaries[roomID] = summary }
                    }
                    summaries = summaries.filter { present.contains($0.key) }
                    var list: [RoomSummary] = []
                    let chosen = filterBox.current
                    for room in known {
                        guard let summary = summaries[room.id()], try Self.includes(chosen, summary: summary) else { continue }
                        list.append(summary)
                    }
                    list.sort(by: Self.order)
                    if list != last {
                        last = list
                        continuation.yield(.reset(list))
                    }
                    return presentIDs
                }
                try await publish(changed: nil, forceAll: true)
                let changes = await session.syncChanges()
                enum Event: Sendable { case sync(Set<String>), refresh }
                // Sync responses and filter changes feed one loop, so the list is rebuilt one change at a time.
                let (events, eventContinuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
                let forward = Task { [weak self] in
                    for await change in changes {
                        if !change.left.isEmpty {
                            let leftIDs = Set(change.left.compactMap { try? RoomID($0) })
                            self?.publishLeft(leftIDs)
                        }
                        eventContinuation.yield(.sync(change.joined.union(change.invited).union(change.left)))
                    }
                }
                let refreshes = Task { for await _ in refresh { eventContinuation.yield(.refresh) } }
                defer { forward.cancel(); refreshes.cancel(); eventContinuation.finish() }
                for await event in events {
                    switch event {
                    case .sync(let changed):
                        let present = try await publish(changed: changed)
                        self?.publishSynced(present)
                    case .refresh:
                        try await publish(changed: nil, forceAll: true)
                    }
                }
            } catch {
                // The stream ends; the consumer resubscribes (RoomListCoordinator) and gets a fresh `.reset`.
            }
            continuation.finish()
        }
        current.withLock { $0 = Subscription(id: id, refresh: refreshContinuation, filter: filterBox) }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            refreshContinuation.finish()
            self?.eventTimes.clear()
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

    public func leftRooms() -> AsyncStream<Set<RoomID>> {
        let (stream, continuation) = AsyncStream<Set<RoomID>>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        leftObservers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.leftObservers.withLock { _ = $0.removeValue(forKey: id) } }
        return stream
    }

    private func publishLeft(_ rooms: Set<RoomID>) {
        guard !rooms.isEmpty else { return }
        let continuations = leftObservers.withLock { Array($0.values) }
        for continuation in continuations { continuation.yield(rooms) }
    }

    public func syncCompletions() -> AsyncStream<Set<RoomID>> {
        let (stream, continuation) = AsyncStream<Set<RoomID>>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        syncObservers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.syncObservers.withLock { _ = $0.removeValue(forKey: id) } }
        return stream
    }

    private func publishSynced(_ present: Set<RoomID>) {
        let continuations = syncObservers.withLock { Array($0.values) }
        for continuation in continuations { continuation.yield(present) }
    }

    // MARK: Mapping

    /// `.unread` needs read-state inputs and arrives with the unread engine (M1); asking for it now is
    /// an explicit error, not a silently wrong list.
    static func kind(for filter: RoomListFilter) throws(HaloError) {
        if case .unread = filter { throw .unsupported("FILTER_UNREAD_M1") }
    }

    private static let maxRebuildConcurrency = 8

    private static func rebuildSummaries(
        _ rooms: [(roomID: String, id: RoomID, room: Room)],
        settings: NotificationSettings,
        hasRecords: @escaping @Sendable (RoomID) -> Bool,
        eventTimes: EventTimeCache?
    ) async throws(HaloError) -> [(String, RoomSummary)] {
        do {
            return try await withThrowingTaskGroup(of: (String, RoomSummary).self) { group in
                var iterator = rooms.makeIterator()
                for _ in 0..<min(maxRebuildConcurrency, rooms.count) {
                    guard let next = iterator.next() else { break }
                    let roomHasRecords = hasRecords(next.id)
                    group.addTask { (next.roomID, try await Self.summary(next.room, settings, hasRecords: roomHasRecords, eventTimes: eventTimes)) }
                }
                var results: [(String, RoomSummary)] = []
                results.reserveCapacity(rooms.count)
                while let pair = try await group.next() {
                    results.append(pair)
                    if let next = iterator.next() {
                        let roomHasRecords = hasRecords(next.id)
                        group.addTask { (next.roomID, try await Self.summary(next.room, settings, hasRecords: roomHasRecords, eventTimes: eventTimes)) }
                    }
                }
                return results
            }
        } catch let error as HaloError {
            throw error
        } catch {
            throw ErrorMapper.map(error)
        }
    }

    static func includes(_ filter: RoomListFilter, summary: RoomSummary) throws(HaloError) -> Bool {
        switch filter {
        case .all: return true
        case .invites: return summary.membership == .invited
        case .people: return summary.membership == .joined && summary.isDirect
        case .rooms: return summary.membership == .joined && !summary.isDirect
        case .favourites: return summary.membership == .joined && summary.isFavourite
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

    static func summary(
        _ room: Room, _ settings: NotificationSettings, hasRecords: Bool = false, eventTimes: EventTimeCache? = nil
    ) async throws(HaloError) -> RoomSummary {
        // Fetch RoomInfo once per room and reuse it across direct/encryption/counts/favourite/inviter (R-19).
        let info = try? await room.roomInfo()
        let isDirect: Bool = if let info { info.isDirect } else { await room.isDirect() }
        let isEncrypted: Bool = if let info, info.encryptionState != .unknown {
            info.encryptionState == .encrypted
        } else {
            await room.isEncrypted()
        }
        let read = await readCounts(of: room, info: info, settings: settings, isEncrypted: isEncrypted, isOneToOne: isDirect)
        let inviter = await inviterInfo(room, cached: info?.inviter)
        let latest = await room.latestEvent()
        let ownReceipt = await ownReadThrough(of: room, counts: read, hasRecords: hasRecords, eventTimes: eventTimes)
        return try RoomSummary(
            id: RoomID(room.id()),
            name: room.displayName(),
            isDirect: isDirect,
            isEncrypted: isEncrypted,
            membership: membership(room.membership()),
            read: read,
            latestEvent: latestEvent(latest),
            ownReadThrough: ownReceipt?.timestamp,
            ownReceiptEventID: ownReceipt?.eventID,
            isFavourite: info?.isFavourite ?? false,
            preview: preview(latest, ownUserID: room.ownUserId()),
            avatar: avatar(room.avatarUrl()),
            inviter: inviter?.name,
            inviterID: inviter?.id
        )
    }

    /// Who invited the user, for an invited room only (reuses `RoomInfo.inviter` when already loaded).
    static func inviterInfo(_ room: Room, cached: MatrixRustSDK.RoomMember? = nil) async -> (name: String, id: UserID?)? {
        guard room.membership() == .invited else { return nil }
        let member: MatrixRustSDK.RoomMember?
        if let cached { member = cached } else { member = try? await room.inviter() }
        guard let member else { return nil }
        let name = member.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? member.userId
        return (name, try? UserID(member.userId))
    }

    /// The avatar's media reference from its `mxc://` URI; `nil` for none or an unusable URI.
    static func avatar(_ url: String?) -> MediaRef? {
        guard let url, !url.isEmpty, let source = try? MediaSource.fromUrl(url: url) else { return nil }
        return TimelineMapper.ref(source)
    }

    /// The event ID and time of the event the user's newest own receipt points at (read from another device). Resolved for
    /// rooms that look unread or have pending notification records (so a UTD push read on another device is still covered,
    /// R-02); quiet rooms without records cost nothing. A failed lookup leaves the room as unread, the safe error.
    static func ownReadThrough(
        of room: Room, counts: RoomReadCounts, hasRecords: Bool = false, eventTimes: EventTimeCache? = nil
    ) async -> (eventID: EventID, timestamp: Date)? {
        let looksUnread = counts.server.notification > 0 || counts.server.highlight > 0 || counts.sdk.unreadMessages > 0
            || counts.sdk.unreadNotifications > 0 || counts.isMarkedUnread
        guard looksUnread || hasRecords else { return nil }
        let me = room.ownUserId()
        var newest: (eventId: String, receipt: UInt64)?
        for type in [ReceiptType.read, .readPrivate] {
            guard let found = try? await room.loadUserReceipt(receiptType: type, thread: .unthreaded, userId: me) else { continue }
            let at = found.receipt.timestamp ?? 0
            if let current = newest {
                if at >= current.receipt { newest = (found.eventId, at) }
            } else {
                newest = (found.eventId, at)
            }
        }
        guard let rawEventId = newest?.eventId, let eventID = try? EventID(rawEventId) else { return nil }
        if let known = eventTimes?.get(rawEventId) { return (eventID, known) }
        guard let event = try? await room.loadOrFetchEvent(eventId: rawEventId) else { return nil }
        let time = Date(timeIntervalSince1970: Double(event.timestamp()) / 1000)
        eventTimes?.set(rawEventId, time)
        return (eventID, time)
    }

    /// The room's unread counts and effective notification mode. A mode that can't be read counts as "all messages":
    /// showing too much attention is the safe error (a missed message is worse than an extra dot).
    static func readCounts(of room: Room, info: RoomInfo? = nil, settings: NotificationSettings, isEncrypted: Bool, isOneToOne: Bool) async -> RoomReadCounts {
        let resolvedInfo: RoomInfo?
        if let info { resolvedInfo = info } else { resolvedInfo = try? await room.roomInfo() }
        var mode = NotificationMode.allMessages
        if let effective = try? await settings.getRoomNotificationSettings(roomId: room.id(), isEncrypted: isEncrypted, isOneToOne: isOneToOne) {
            mode = Self.mode(effective.mode)
        }
        guard let resolvedInfo else { return RoomReadCounts(mode: mode, server: .zero, sdk: .zero, isMarkedUnread: false) }
        return RoomReadCounts(
            mode: mode,
            server: ServerCounts(notification: Int(resolvedInfo.notificationCount), highlight: Int(resolvedInfo.highlightCount)),
            sdk: SDKCounts(unreadMessages: Int(resolvedInfo.numUnreadMessages), unreadNotifications: Int(resolvedInfo.numUnreadNotifications), unreadMentions: Int(resolvedInfo.numUnreadMentions)),
            isMarkedUnread: resolvedInfo.isMarkedUnread)
    }

    /// The newest event for the read-state policy. Invites and rooms without events have none; a local echo is the
    /// user's own event (its time is when it was queued).
    static func latestEvent(_ value: LatestEventValue) -> LatestEventRef? {
        func date(_ ms: Timestamp) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
        switch value {
        case .none, .remoteInvite: return nil
        case .remote(let timestamp, _, let isOwn, _, _): return LatestEventRef(timestamp: date(timestamp), senderIsSelf: isOwn)
        case .local(let timestamp, _, _, _, _): return LatestEventRef(timestamp: date(timestamp), senderIsSelf: true, isLocal: true)
        }
    }

    /// One line of the newest message. Messages show their text, media a label; a state change, call or unknown event has none.
    static func preview(_ value: LatestEventValue, ownUserID: String? = nil) -> LatestMessagePreview? {
        switch value {
        case .none, .remoteInvite: return nil
        // The SDK skips messages it can't decrypt when it picks the latest event, so an encrypted room often ends on a
        // membership change: say it as a sentence (no "Name:" prefix) rather than leave the line empty.
        case .remote(_, _, let isOwn, _, .roomMembership(_, let name, let change, _)):
            return membershipLine(who: isOwn ? "You" : (name ?? "Someone"), change).map { LatestMessagePreview(text: $0, senderName: nil, isOwn: false) }
        case .remote(_, let sender, let isOwn, let profile, let content):
            return previewText(content).map {
                LatestMessagePreview(
                    text: $0, senderName: displayName(profile), isOwn: isOwn,
                    senderID: try? UserID(sender), formattedBody: TimelineMapper.formattedHTML(of: content),
                    isReply: isReply(content), mentionsMe: !isOwn && mentions(content, userID: ownUserID))
            }
        case .local(_, let sender, let profile, let content, _):
            return previewText(content).map {
                LatestMessagePreview(
                    text: $0, senderName: displayName(profile), isOwn: true,
                    senderID: try? UserID(sender), formattedBody: TimelineMapper.formattedHTML(of: content),
                    isReply: isReply(content), mentionsMe: false)
            }
        }
    }

    static func isReply(_ content: TimelineItemContent) -> Bool {
        guard case .msgLike(let like) = content else { return false }
        return like.inReplyTo != nil
    }

    static func mentions(_ content: TimelineItemContent, userID: String?) -> Bool {
        guard let userID, case .msgLike(let like) = content, case .message(let message) = like.kind,
              let mentions = message.mentions else { return false }
        return mentions.room || mentions.userIds.contains(userID)
    }

    /// "Ann joined", "You left"; `nil` for changes not worth a preview line.
    static func membershipLine(who: String, _ change: MatrixRustSDK.MembershipChange?) -> String? {
        switch change {
        case .joined, .invitationAccepted: "\(who) joined"
        case .left: "\(who) left"
        case .invited: "\(who) was invited"
        case .kicked, .kickedAndBanned: "\(who) was removed"
        case .banned: "\(who) was banned"
        default: nil
        }
    }

    static func displayName(_ profile: ProfileDetails) -> String? {
        if case .ready(let name, _, _, _, _) = profile { return name }
        return nil
    }

    static func previewText(_ content: TimelineItemContent) -> String? {
        guard case .msgLike(let like) = content else { return nil }
        func single(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        }
        func labelled(_ kind: String, _ detail: String?) -> String {
            guard let detail = detail.map(single)?.trimmingCharacters(in: .whitespaces), !detail.isEmpty else { return kind }
            return "\(kind): \(detail)"
        }
        switch like.kind {
        case .message(let message):
            switch message.msgType {
            case .text(let text): return single(text.body)
            case .notice(let notice): return single(notice.body)
            case .emote(let emote): return "* " + single(emote.body)
            // A caption or a file's name says more than the kind alone ("Photo: at the beach", "File: report.pdf").
            case .image(let image): return labelled("Photo", image.caption)
            case .video(let video): return labelled("Video", video.caption)
            case .audio(let audio): return labelled("Audio", audio.caption)
            case .file(let file): return labelled("File", file.filename)
            case .gallery: return "Photos"
            case .location: return "Location"
            case .other(_, let body): return single(body)
            }
        case .sticker(let body, _, _): return labelled("Sticker", body)
        case .poll(let question, _, _, _, _, _, _): return "Poll: " + single(question)
        case .redacted: return "Message deleted"
        case .unableToDecrypt: return "Encrypted message"
        case .liveLocation: return "Live location"
        case .other: return nil
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

private final class PushRulesChangeDelegate: NotificationSettingsDelegate {
    private let refresh: AsyncStream<Void>.Continuation

    init(refresh: AsyncStream<Void>.Continuation) {
        self.refresh = refresh
    }

    func settingsDidChange() {
        // Never block the callback thread or call back into the FFI synchronously (AGENTS.md §8).
        refresh.yield()
    }
}
