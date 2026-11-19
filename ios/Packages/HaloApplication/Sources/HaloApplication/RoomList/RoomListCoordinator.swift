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

    public private(set) var rooms: [RoomSummary] = []
    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { broadcaster.publish(status) } }
    }

    private let port: any RoomListPort
    private var broadcaster = SnapshotBroadcaster<Status>()
    private var readBroadcaster = SnapshotBroadcaster<[RoomReadState]>()
    private var readStatesCache: [RoomReadState] = []
    private var subscription: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var diffsInSubscription = 0

    public init(port: any RoomListPort) {
        self.port = port
    }

    deinit {
        subscription?.cancel()
    }

    /// The current status, then its changes; latest value wins (CONCURRENCY §3).
    public func statuses() -> AsyncStream<Status> {
        broadcaster.subscribe(current: status)
    }

    /// The read state of every loaded room (`ReadStatePolicy`), now and after each change; latest value wins. Only the
    /// rooms the list has loaded so far are included (the first page until the list pages further).
    public func readStates() -> AsyncStream<[RoomReadState]> { readBroadcaster.subscribe(current: readStatesCache) }

    public func start(filter: RoomListFilter = .all) {
        consecutiveFailures = 0
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

    private func publishReadStates() {
        let states = rooms.map {
            ReadStatePolicy.evaluate(RoomReadInputs(roomID: $0.id, membership: $0.membership, isEncrypted: $0.isEncrypted, counts: $0.read))
        }
        guard states != readStatesCache else { return }
        readStatesCache = states
        readBroadcaster.publish(states)
    }

    /// Applies one diff; returns `false` when this subscription must stop.
    private func apply(_ diff: RoomListDiff, generation: Int, filter: RoomListFilter) -> Bool {
        guard generation == self.generation else { return false }
        do {
            try RoomListReducer.apply(diff, to: &rooms)
            diffsInSubscription += 1
            // The first diff of a subscription is the port's fresh start (.reset), which always
            // applies; only a later diff proves the stream is healthy again.
            if diffsInSubscription > 1 { consecutiveFailures = 0 }
            status = .loaded(roomCount: rooms.count)
            publishReadStates()
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
