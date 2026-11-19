import HaloDomain
import HaloFoundation

/// Keeps the items of one room's timeline and back-pagination state (docs/features/TIMELINE.md §6).
/// M1 is read-only; sending, receipts and visibility reporting arrive in M2/M3.
public actor TimelineCoordinator {
    public struct Snapshot: Sendable, Equatable {
        public var items: [TimelineItem]
        public var isPaginating: Bool
        /// The start of the room's history has been loaded; pagination does nothing more.
        public var reachedStart: Bool
        /// The last back-pagination failed; shown with a retry button (TIMELINE §9).
        public var paginationError: HaloError?

        public init(items: [TimelineItem], isPaginating: Bool, reachedStart: Bool, paginationError: HaloError?) {
            self.items = items
            self.isPaginating = isPaginating
            self.reachedStart = reachedStart
            self.paginationError = paginationError
        }
    }

    public enum Status: Sendable, Equatable {
        case idle
        case opening
        case live(Snapshot)
        /// Opening failed, or the list kept disagreeing with the port's diffs after `maximumResubscriptions` fresh starts.
        case failed(HaloError)
    }

    public static let maximumResubscriptions = 3

    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { broadcaster.publish(status) } }
    }

    private let port: any TimelinePort
    private let room: RoomID
    private var broadcaster = SnapshotBroadcaster<Status>()
    private var session: (any TimelineSession)?
    private var subscription: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var diffsInSubscription = 0
    private var snapshot = Snapshot(items: [], isPaginating: false, reachedStart: false, paginationError: nil)

    public init(port: any TimelinePort, room: RoomID) {
        self.port = port
        self.room = room
    }

    deinit { subscription?.cancel() }

    /// The current status, then its changes; latest value wins (CONCURRENCY §3).
    public func statuses() -> AsyncStream<Status> { broadcaster.subscribe(current: status) }

    public func open() async {
        guard status == .idle else { return }
        status = .opening
        do {
            session = try await port.open(room: room)
        } catch {
            status = .failed(error)
            return
        }
        consecutiveFailures = 0
        subscribe()
    }

    public func close() async {
        generation += 1
        subscription?.cancel()
        subscription = nil
        let closing = session
        session = nil
        snapshot = Snapshot(items: [], isPaginating: false, reachedStart: false, paginationError: nil)
        status = .idle
        await closing?.close()
    }

    /// Loads older events once at a time (TIMELINE FR-3). A failure is kept in the snapshot for a retry.
    public func paginateBackwards() async {
        guard case .live = status, let session, !snapshot.isPaginating, !snapshot.reachedStart else { return }
        snapshot.isPaginating = true
        snapshot.paginationError = nil
        publish()
        let current = generation
        do {
            let reachedStart = try await session.paginateBackwards(count: 20)
            guard current == generation else { return }
            snapshot.reachedStart = reachedStart
        } catch {
            guard current == generation else { return }
            snapshot.paginationError = error
        }
        snapshot.isPaginating = false
        publish()
    }

    // MARK: Private

    private func subscribe() {
        guard let session else { return }
        subscription?.cancel()
        generation += 1
        diffsInSubscription = 0
        snapshot.items = []
        let current = generation
        let diffs = session.items()
        subscription = Task { [weak self] in
            for await diff in diffs {
                guard let self, await self.apply(diff, generation: current) else { return }
            }
        }
    }

    private func apply(_ diff: TimelineDiff, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        do {
            try ListReducer.apply(diff, to: &snapshot.items)
            diffsInSubscription += 1
            if diffsInSubscription > 1 { consecutiveFailures = 0 }
            publish()
            return true
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures > Self.maximumResubscriptions {
                subscription = nil
                status = .failed(error)
            } else {
                // A fresh subscription starts from a `.reset`, which repairs the list.
                subscribe()
            }
            return false
        }
    }

    /// The room's first event is loaded once the SDK has put its `timelineStart` marker on top; that is the
    /// authoritative signal (the SDK's pagination result can still say "more" for one more call).
    private func publish() {
        if snapshot.items.first?.content == .virtual(.timelineStart) { snapshot.reachedStart = true }
        status = .live(snapshot)
    }
}
