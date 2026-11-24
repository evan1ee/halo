import HaloDomain
import HaloFoundation

/// The read inputs of every visible room together with the sync responses they include. One value, so a consumer never
/// sees "sync has completed" with the inputs from before it.
public struct RoomReadSnapshot: Sendable, Equatable {
    public let inputs: [RoomReadInputs]
    /// The joined/invited rooms at the last sync response of this subscription; `nil` before the first one (R-04).
    public let present: Set<RoomID>?
    /// How many sync responses have been applied since launch.
    public let syncCount: Int

    static let empty = RoomReadSnapshot(inputs: [], present: nil, syncCount: 0)
}

/// Keeps the ordered room list from `RoomListPort` and publishes its status, including the room
/// count that M0's exit criterion shows (docs/ROADMAP.md M0).
public actor RoomListCoordinator {
    public enum Status: Sendable, Equatable {
        case idle
        /// Subscribed; the first diff hasn't arrived yet.
        case loading
        case loaded(roomCount: Int)
        /// The list kept disagreeing with the port's diffs after `maximumResubscriptions` fresh starts.
        case failed(HaloError)
    }

    /// How often a subscription is restarted after a diff that doesn't apply before giving up.
    public static let maximumResubscriptions = 3

    /// The rooms to show: the list minus sticker-pack rooms and pending invitations from ignored users.
    public var rooms: [RoomSummary] {
        guard !hidden.isEmpty || !ignored.isEmpty else { return allRooms }
        return allRooms.filter { room in
            if hidden.contains(room.id) { return false }
            if room.membership == .invited, let inviter = room.inviterID, ignored.contains(inviter) { return false }
            return true
        }
    }
    private var allRooms: [RoomSummary] = []
    private var hidden: Set<RoomID> = []
    private var ignored: Set<UserID> = []
    private var left: Set<RoomID> = []
    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { broadcaster.publish(status) } }
    }

    private let port: any RoomListPort
    private let hiddenRooms: (any HiddenRoomsPort)?
    private let profiles: (any ProfilePort)?
    private let loadsAllPages: Bool
    /// The room count at the last automatic page request; a page that adds no rooms yields no diff, which ends the loop.
    private var requestedAt = 0
    private var broadcaster = SnapshotBroadcaster<Status>()
    private var readBroadcaster = SnapshotBroadcaster<[RoomReadInputs]>()
    private var readInputsCache: [RoomReadInputs] = []
    private var snapshotBroadcaster = SnapshotBroadcaster<RoomReadSnapshot>()
    private var snapshotCache = RoomReadSnapshot.empty
    private var summaryBroadcaster = SnapshotBroadcaster<[RoomSummary]>()
    private var summaryCache: [RoomSummary] = []
    private var excludedBroadcaster = SnapshotBroadcaster<Set<RoomID>>()
    private var excludedCache: Set<RoomID> = []
    private var lastSyncedRooms: Set<RoomID>?
    private var syncCount = 0
    private var subscription: Task<Void, Never>?
    private var leftSubscription: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var diffsInSubscription = 0

    /// - Parameter loadsAllPages: keep requesting pages while each one adds rooms, so the badge sees every room
    ///   (UNREAD_STATE: the badge counts all rooms, not the first page).
    /// - Parameter hiddenRooms: rooms to leave out of the list and the badge (sticker pack rooms); read again after every change.
    /// - Parameter profiles: used to hide pending invitations from ignored users in both the list and the badge.
    public init(port: any RoomListPort, loadsAllPages: Bool = false, hiddenRooms: (any HiddenRoomsPort)? = nil, profiles: (any ProfilePort)? = nil) {
        self.hiddenRooms = hiddenRooms
        self.profiles = profiles
        self.port = port
        self.loadsAllPages = loadsAllPages
    }

    deinit {
        subscription?.cancel()
        leftSubscription?.cancel()
    }

    /// The current status, then its changes; latest value wins (CONCURRENCY §3).
    public func statuses() -> AsyncStream<Status> {
        broadcaster.subscribe(current: status)
    }

    /// The read inputs of every loaded room, now and after each change; latest value wins. Only the rooms the list has
    /// loaded so far are included (the first page until the list pages further). `BadgeCoordinator` evaluates them.
    public func readInputs() -> AsyncStream<[RoomReadInputs]> { readBroadcaster.subscribe(current: readInputsCache) }

    /// The visible rooms whenever any field of any room changed (a rename, a favourite, a new latest event), not only the read inputs.
    public func summaryChanges() -> AsyncStream<[RoomSummary]> { summaryBroadcaster.subscribe(current: summaryCache) }

    /// Rooms that must not count towards attention and whose notification records should be pruned: left rooms, hidden
    /// sticker-pack rooms, and pending invitations from ignored users (R-03).
    public func excludedRoomChanges() -> AsyncStream<Set<RoomID>> { excludedBroadcaster.subscribe(current: excludedCache) }

    /// The read inputs and the sync progress they belong to, now and after each change; latest value wins.
    public func readSnapshots() -> AsyncStream<RoomReadSnapshot> { snapshotBroadcaster.subscribe(current: snapshotCache) }

    /// Always subscribes to `.all` so `readInputs()` never shrinks the badge's room set; UI filters run in
    /// `RoomListViewModel` (R-27).
    public func start() {
        consecutiveFailures = 0
        requestedAt = 0
        subscribe(filter: .all)
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
        leftSubscription?.cancel()
        leftSubscription = nil
        generation += 1
        hidden = []
        ignored = []
        left = []
        lastSyncedRooms = nil
        publishSnapshot()
        publishExcluded()
        status = .idle
    }

    /// Re-reads the ignored-user list immediately (e.g. after ignoring or unignoring someone in the UI).
    public func refreshIgnoredUsers() async {
        guard let profiles, let list = try? await profiles.ignoredUsers() else { return }
        setIgnored(Set(list), generation: generation)
    }

    public func loadMore() async throws(HaloError) {
        try await port.loadMore()
    }

    // MARK: Private

    private func subscribe(filter: RoomListFilter) {
        subscription?.cancel()
        leftSubscription?.cancel()
        generation += 1
        diffsInSubscription = 0
        let current = generation
        status = .loading
        let updates = port.updates(filter: filter)
        let leftStream = port.leftRooms()
        subscription = Task { [weak self] in
            for await update in updates {
                switch update {
                case .diff(let diff):
                    guard let self, await self.apply(diff, generation: current, filter: filter) else { return }
                case .synced(let present):
                    await self?.syncCompleted(present, generation: current)
                }
            }
        }
        leftSubscription = Task { [weak self] in
            for await rooms in leftStream {
                await self?.roomsLeft(rooms, generation: current)
            }
        }
    }

    private func syncCompleted(_ present: Set<RoomID>, generation: Int) {
        guard generation == self.generation else { return }
        lastSyncedRooms = present
        syncCount += 1
        publishSnapshot()
    }

    private func roomsLeft(_ rooms: Set<RoomID>, generation: Int) {
        guard generation == self.generation, !rooms.isEmpty else { return }
        left.formUnion(rooms)
        publishExcluded()
    }

    /// Reads the hidden set again; when it changed, the list and the read inputs are published anew.
    private func refreshHidden(generation: Int) {
        guard let hiddenRooms else { return }
        Task { [weak self] in
            let value = await hiddenRooms.hiddenRooms()
            await self?.setHidden(value, generation: generation)
        }
    }

    private func setHidden(_ value: Set<RoomID>, generation: Int) {
        guard generation == self.generation, value != hidden else { return }
        hidden = value
        if case .loaded = status { status = .loaded(roomCount: rooms.count) }
        publishReadInputs()
        publishSummaries()
        publishExcluded()
    }

    /// Reads the ignored-user list when pending invitations exist, so invitations from ignored users stay hidden.
    private func refreshIgnored(generation: Int) {
        guard let profiles, allRooms.contains(where: { $0.membership == .invited }) else { return }
        Task { [weak self] in
            guard let list = try? await profiles.ignoredUsers() else { return }
            await self?.setIgnored(Set(list), generation: generation)
        }
    }

    private func setIgnored(_ value: Set<UserID>, generation: Int) {
        guard generation == self.generation, value != ignored else { return }
        ignored = value
        if case .loaded = status { status = .loaded(roomCount: rooms.count) }
        publishReadInputs()
        publishSummaries()
        publishExcluded()
    }

    private func publishExcluded() {
        var current = hidden.union(left)
        if !ignored.isEmpty {
            for room in allRooms where room.membership == .invited {
                if let inviter = room.inviterID, ignored.contains(inviter) { current.insert(room.id) }
            }
        }
        guard current != excludedCache else { return }
        excludedCache = current
        excludedBroadcaster.publish(current)
    }

    private func publishSummaries() {
        let current = rooms
        guard current != summaryCache else { return }
        summaryCache = current
        summaryBroadcaster.publish(current)
    }

    private func publishReadInputs() {
        let inputs = rooms.map {
            RoomReadInputs(
                roomID: $0.id, membership: $0.membership, isEncrypted: $0.isEncrypted, counts: $0.read,
                latestEvent: $0.latestEvent, localIntent: $0.ownReadThrough, receiptReadThrough: $0.ownReadThrough,
                ownReceiptEventID: $0.ownReceiptEventID)
        }
        guard inputs != readInputsCache else { return }
        readInputsCache = inputs
        readBroadcaster.publish(inputs)
        publishSnapshot()
    }

    private func publishSnapshot() {
        let snapshot = RoomReadSnapshot(inputs: readInputsCache, present: lastSyncedRooms, syncCount: syncCount)
        guard snapshot != snapshotCache else { return }
        snapshotCache = snapshot
        snapshotBroadcaster.publish(snapshot)
    }

    /// Applies one diff; returns `false` when this subscription must stop.
    private func apply(_ diff: RoomListDiff, generation: Int, filter: RoomListFilter) -> Bool {
        guard generation == self.generation else { return false }
        do {
            try RoomListReducer.apply(diff, to: &allRooms)
            // If a previously left room was rejoined or re-invited, it is no longer left.
            if !left.isEmpty {
                left.subtract(allRooms.map(\.id))
            }
            diffsInSubscription += 1
            // The first diff of a subscription is the port's fresh start (.reset), which always
            // applies; only a later diff proves the stream is healthy again.
            if diffsInSubscription > 1 { consecutiveFailures = 0 }
            status = .loaded(roomCount: rooms.count)
            publishReadInputs()
            publishSummaries()
            publishExcluded()
            if loadsAllPages, allRooms.count > requestedAt {
                requestedAt = allRooms.count
                Task { [port] in try? await port.loadMore() }
            }
            refreshHidden(generation: generation)
            refreshIgnored(generation: generation)
            return true
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures > Self.maximumResubscriptions {
                subscription = nil
                status = .failed(error)
            } else {
                // The port promises that every new subscription starts from a known state (.reset),
                // so a fresh subscription repairs the list.
                subscribe(filter: filter)
            }
            return false
        }
    }
}
