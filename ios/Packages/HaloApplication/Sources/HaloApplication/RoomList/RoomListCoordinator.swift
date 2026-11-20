import HaloDomain
import HaloFoundation

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

    /// The rooms to show: the list minus the rooms Halo itself created for sticker packs.
    public var rooms: [RoomSummary] { hidden.isEmpty ? allRooms : allRooms.filter { !hidden.contains($0.id) } }
    private var allRooms: [RoomSummary] = []
    private var hidden: Set<RoomID> = []
    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { broadcaster.publish(status) } }
    }

    private let port: any RoomListPort
    private let hiddenRooms: (any HiddenRoomsPort)?
    private let loadsAllPages: Bool
    /// The room count at the last automatic page request; a page that adds no rooms yields no diff, which ends the loop.
    private var requestedAt = 0
    private var broadcaster = SnapshotBroadcaster<Status>()
    private var readBroadcaster = SnapshotBroadcaster<[RoomReadInputs]>()
    private var readInputsCache: [RoomReadInputs] = []
    private var summaryBroadcaster = SnapshotBroadcaster<[RoomSummary]>()
    private var summaryCache: [RoomSummary] = []
    private var subscription: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var diffsInSubscription = 0

    /// - Parameter loadsAllPages: keep requesting pages while each one adds rooms, so the badge sees every room
    ///   (UNREAD_STATE: the badge counts all rooms, not the first page).
    /// - Parameter hiddenRooms: rooms to leave out of the list and the badge (sticker pack rooms); read again after every change.
    public init(port: any RoomListPort, loadsAllPages: Bool = false, hiddenRooms: (any HiddenRoomsPort)? = nil) {
        self.hiddenRooms = hiddenRooms
        self.port = port
        self.loadsAllPages = loadsAllPages
    }

    deinit {
        subscription?.cancel()
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

    public func start(filter: RoomListFilter = .all) {
        consecutiveFailures = 0
        requestedAt = 0
        subscribe(filter: filter)
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
        generation += 1
        status = .idle
    }

    public func loadMore() async throws(HaloError) {
        try await port.loadMore()
    }

    // MARK: Private

    private func subscribe(filter: RoomListFilter) {
        subscription?.cancel()
        generation += 1
        diffsInSubscription = 0
        let current = generation
        status = .loading
        let diffs = port.rooms(filter: filter)
        subscription = Task { [weak self] in
            for await diff in diffs {
                guard let self, await self.apply(diff, generation: current, filter: filter) else { return }
            }
        }
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
    }

    private func publishSummaries() {
        let current = rooms
        guard current != summaryCache else { return }
        summaryCache = current
        summaryBroadcaster.publish(current)
    }

    private func publishReadInputs() {
        let inputs = rooms.map { RoomReadInputs(roomID: $0.id, membership: $0.membership, isEncrypted: $0.isEncrypted, counts: $0.read, latestEvent: $0.latestEvent, localIntent: $0.ownReadThrough) }
        guard inputs != readInputsCache else { return }
        readInputsCache = inputs
        readBroadcaster.publish(inputs)
    }

    /// Applies one diff; returns `false` when this subscription must stop.
    private func apply(_ diff: RoomListDiff, generation: Int, filter: RoomListFilter) -> Bool {
        guard generation == self.generation else { return false }
        do {
            try RoomListReducer.apply(diff, to: &allRooms)
            diffsInSubscription += 1
            // The first diff of a subscription is the port's fresh start (.reset), which always
            // applies; only a later diff proves the stream is healthy again.
            if diffsInSubscription > 1 { consecutiveFailures = 0 }
            status = .loaded(roomCount: rooms.count)
            publishReadInputs()
            publishSummaries()
            if loadsAllPages, allRooms.count > requestedAt {
                requestedAt = allRooms.count
                Task { [port] in try? await port.loadMore() }
            }
            refreshHidden(generation: generation)
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
