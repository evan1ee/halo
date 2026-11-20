import Foundation
import HaloDomain
import HaloFoundation

/// Turns "the user has seen this event" into read receipts (docs/matrix/READ_RECEIPTS.md §1): ignores candidates that
/// don't advance the read position, keeps only the newest intent per room, sends at most one receipt per room per
/// `minimumInterval`, and retries retryable failures with backoff. The caller decides *what is visible* (D6: ≥ 50 %
/// for ≥ 0.5 s, app active, room on top); this actor never looks at views.
/// With a `ReadIntentPort` intents survive a relaunch: unsent ones are sent after `restore()`, sent ones expire after 7 days.
public actor ReadReceiptCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let minimumInterval: Duration = .seconds(2)
    public static let initialBackoff: Duration = .seconds(1)
    public static let maximumBackoff: Duration = .seconds(300)

    private struct Intent {
        var event: EventID
        var timestamp: Date
        var sent: Bool
    }

    /// The last storage failure, if any. Intents stay in memory and are still sent; there is no `HaloLog` yet to record it.
    public private(set) var lastStorageError: HaloError?

    private let port: any ReadMarkerPort
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: Sleep
    private var store: (any ReadIntentPort)?
    private let wallClock: @Sendable () -> Date
    private var created: [RoomID: Date] = [:]
    private var isPrivate: Bool
    private var intents: [RoomID: Intent] = [:]
    private var lastSend: [RoomID: ContinuousClock.Instant] = [:]
    private var failures: [RoomID: Int] = [:]
    private var positionBroadcaster = SnapshotBroadcaster<[RoomID: Date]>()
    private var scheduled: [RoomID: Task<Void, Never>] = [:]
    /// Rooms with a send in progress; a second send for the same room would repeat the receipt.
    private var sending: Set<RoomID> = []

    public init(
        port: any ReadMarkerPort, store: (any ReadIntentPort)? = nil, privateReceipts: Bool = false,
        wallClock: @escaping @Sendable () -> Date = { Date() },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.store = store
        self.wallClock = wallClock
        self.isPrivate = privateReceipts
        self.now = now
        self.sleep = sleep
    }

    deinit { for task in scheduled.values { task.cancel() } }

    /// How long a sent intent is kept (READ_RECEIPTS §1).
    public static let sentRetention: TimeInterval = 7 * 24 * 3600

    /// Loads stored intents and sends the unsent ones. Call once after sign-in. A newer intent reported before this
    /// finishes wins over a stored older one.
    public func restore() async {
        guard let store else { return }
        await load(from: store)
    }

    /// Attaches the store once the account is known (the database is per account) and restores from it.
    public func restore(from store: any ReadIntentPort) async {
        self.store = store
        await load(from: store)
    }

    private func load(from store: any ReadIntentPort) async {
        let stored: [ReadIntent]
        do {
            try await store.removeSent(createdBefore: wallClock().addingTimeInterval(-Self.sentRetention))
            stored = try await store.all()
        } catch { lastStorageError = error; return }
        for intent in stored {
            if let current = intents[intent.room], current.timestamp >= intent.timestamp { continue }
            intents[intent.room] = Intent(event: intent.event, timestamp: intent.timestamp, sent: intent.isSent)
            created[intent.room] = intent.createdAt
            if !intent.isSent { schedule(intent.room, after: dueIn(intent.room)) }
        }
        positionBroadcaster.publish(currentPositions())
    }

    /// The privacy setting (D7); applies to receipts sent from now on.
    public func setPrivateReceipts(_ value: Bool) { isPrivate = value }

    /// The event time the user reached in each room on this device, now and after every change (the policy's local
    /// intent, UNREAD_STATE rule E1).
    public func positions() -> AsyncStream<[RoomID: Date]> { positionBroadcaster.subscribe(current: currentPositions()) }

    private func currentPositions() -> [RoomID: Date] { intents.mapValues(\.timestamp) }

    /// The time of the newest event the user has read in `room` through this coordinator, if any.
    public func readPosition(of room: RoomID) -> Date? { intents[room]?.timestamp }

    /// The newest event the user has seen in `room`. Local echoes have no event ID and must not be reported.
    /// Candidates not newer than the current intent are ignored.
    public func reportSeen(room: RoomID, event: EventID, timestamp: Date) {
        if let current = intents[room], timestamp <= current.timestamp { return }
        intents[room] = Intent(event: event, timestamp: timestamp, sent: false)
        created[room] = wallClock()
        positionBroadcaster.publish(currentPositions())
        failures[room] = nil
        persist(room)
        schedule(room, after: dueIn(room))
    }

    /// "Mark as read" from the room list: reads the whole room on the server, clears the unread flag and records the
    /// position at `latestEventTime` (the room list's newest event), already sent. A room without events only loses its flag.
    public func markRoomRead(_ room: RoomID, latestEventTime: Date?) async throws(HaloError) {
        let event = try await port.markRoomRead(room: room, isPrivate: isPrivate)
        try await port.setMarkedUnread(room: room, false)
        guard let event, let latestEventTime, latestEventTime > (intents[room]?.timestamp ?? .distantPast) else { return }
        intents[room] = Intent(event: event, timestamp: latestEventTime, sent: true)
        created[room] = wallClock()
        scheduled[room]?.cancel()
        scheduled[room] = nil
        positionBroadcaster.publish(currentPositions())
        persist(room)
    }

    /// The user opened `room` and it is visible: clears `m.marked_unread` (READ_RECEIPTS §1). Best effort; the flag stays
    /// set (and the room keeps its attention) if the server can't be reached, and the next open tries again.
    public func roomOpened(_ room: RoomID) async {
        do { try await port.setMarkedUnread(room: room, false) } catch { return }
    }

    /// "Mark as unread" from the room list.
    public func markRoomUnread(_ room: RoomID) async throws(HaloError) {
        try await port.setMarkedUnread(room: room, true)
    }

    /// Sends every unsent intent now (foreground, reconnect, background flush); backoff is bypassed.
    public func flush() async {
        for room in intents.keys where intents[room]?.sent == false {
            scheduled[room]?.cancel()
            scheduled[room] = nil
            await send(room)
        }
    }

    // MARK: -

    /// Writes the room's intent without blocking the caller; writes are ordered by the store's own monotonic rules.
    private func persist(_ room: RoomID) {
        guard let store, let intent = intents[room], let createdAt = created[room] else { return }
        let record = ReadIntent(room: room, event: intent.event, timestamp: intent.timestamp, isSent: intent.sent, createdAt: createdAt)
        Task { [weak self] in
            do throws(HaloError) { try await store.save(record) } catch { await self?.storageFailed(error) }
        }
    }

    private func storageFailed(_ error: HaloError) { lastStorageError = error }

    private func dueIn(_ room: RoomID) -> Duration {
        guard let last = lastSend[room] else { return .zero }
        let elapsed = last.duration(to: now())
        return elapsed >= Self.minimumInterval ? .zero : Self.minimumInterval - elapsed
    }

    private func schedule(_ room: RoomID, after delay: Duration) {
        scheduled[room]?.cancel()
        scheduled[room] = Task { [weak self, sleep] in
            if delay > .zero { do { try await sleep(delay) } catch { return } }
            await self?.send(room)
        }
    }

    private func send(_ room: RoomID) async {
        guard let intent = intents[room], !intent.sent, !sending.contains(room) else { return }
        scheduled[room] = nil
        sending.insert(room)
        defer { sending.remove(room) }
        lastSend[room] = now()
        do {
            try await port.sendReceipt(room: room, event: intent.event, isPrivate: isPrivate)
            // A newer intent may have arrived while sending; only mark ours.
            if intents[room]?.event == intent.event { intents[room]?.sent = true; persist(room) }
            failures[room] = nil
            do { try await port.setFullyRead(room: room, event: intent.event) } catch {
                // The receipt is what counts; the marker follows with the next intent.
            }
            if let newer = intents[room], !newer.sent { schedule(room, after: dueIn(room)) }
        } catch {
            guard error.isRetryable else { return }
            let attempt = failures[room, default: 0]
            failures[room] = attempt + 1
            let backoff = min(Self.initialBackoff * (1 << min(attempt, 20)), Self.maximumBackoff)
            schedule(room, after: backoff)
        }
    }
}
