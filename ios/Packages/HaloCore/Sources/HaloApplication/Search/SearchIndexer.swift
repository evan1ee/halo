import Foundation
import HaloDomain
import HaloFoundation

/// Fills Halo's search index (MESSAGE_SEARCH FR-9, FR-10; ADR-0024): the live lane writes what each sync brings, the history lane reads
/// every room back to its start while nothing speaks against it. One writer; the index and the rooms decide what comes next, so killing
/// the app at any point repeats at most one slice.
public actor SearchIndexer {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Wait before history starts after a launch: sync and the first screen come first.
    public static let settleDelay: Duration = .seconds(5)
    /// While history can't be read (or is done), the conditions are looked at again after this.
    public static let idleInterval: Duration = .seconds(30)
    /// How long history waits after the person did something.
    public static let busyInterval: Duration = .seconds(3)
    static let statusInterval: Duration = .seconds(2)

    public private(set) var status = SearchIndexStatus() {
        didSet { if status != oldValue { broadcaster.publish(status) } }
    }

    private let index: any LocalSearchIndexPort
    private let source: any MessageIndexSourcePort
    private let rooms: @Sendable () async -> [RoomID]
    private let conditions: @Sendable () async -> SearchIndexPolicy.Conditions
    private let sleep: Sleep
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let log: HaloLog?
    private var broadcaster = SnapshotBroadcaster<SearchIndexStatus>()
    private var liveTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    private var isWorking = false
    private var busyUntil: ContinuousClock.Instant?
    private var eventsInClient = 0
    private var roomsInClient: Set<RoomID> = []
    private var failures = 0
    private var statusAt: ContinuousClock.Instant?
    private var hasWritten = false

    /// - Parameters:
    ///   - rooms: the joined rooms, most recent first.
    ///   - conditions: what speaks for or against reading history now.
    public init(
        index: any LocalSearchIndexPort, source: any MessageIndexSourcePort, rooms: @escaping @Sendable () async -> [RoomID],
        conditions: @escaping @Sendable () async -> SearchIndexPolicy.Conditions, log: HaloLog? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.index = index
        self.source = source
        self.rooms = rooms
        self.conditions = conditions
        self.log = log
        self.sleep = sleep
        self.clock = clock
    }

    deinit {
        liveTask?.cancel()
        historyTask?.cancel()
        nap?.cancel()
    }

    public func statuses() -> AsyncStream<SearchIndexStatus> { broadcaster.subscribe(current: status) }

    // MARK: Running

    /// Listens to sync, then reads history. Call before sync starts, so the first response is heard.
    public func begin() async {
        guard liveTask == nil else { return }
        let batches = source.batches()
        liveTask = Task { [weak self] in
            for await batch in batches { await self?.receive(batch) }
        }
        await source.followKnownRooms()
        historyTask = Task { [weak self] in
            guard let self else { return }
            let joined = await self.rooms()
            if !joined.isEmpty { await self.source.follow(joined) }
            do { try await self.sleep(Self.settleDelay) } catch { return }
            await self.runHistory()
        }
    }

    /// Stops for good (sign-out, revocation). Returns when nothing is being read any more, or after two seconds: a call into the SDK can
    /// take long to fail without a network, and what it returns is dropped.
    public func stop() async {
        liveTask?.cancel()
        historyTask?.cancel()
        nap?.cancel()
        liveTask = nil
        let history = historyTask
        historyTask = nil
        await source.stop()
        let (ended, continuation) = AsyncStream<Void>.makeStream()
        Task {
            await history?.value
            continuation.finish()
        }
        let timeout = Task { [sleep] in
            try? await sleep(.seconds(2))
            continuation.finish()
        }
        for await _ in ended {}
        timeout.cancel()
        status = SearchIndexStatus()
    }

    /// The person is doing something (scrolling, opening a chat, searching): history waits a moment.
    public func noteActivity() { busyUntil = clock() + Self.busyInterval }

    /// The conditions changed (the app came to the front, a setting): look at them now.
    public func conditionsChanged() { nudge() }

    /// The set of joined rooms changed. An empty list is one that isn't loaded yet.
    public func roomsChanged() async {
        let joined = await rooms()
        guard !joined.isEmpty else { return }
        await source.follow(joined)
        nudge()
    }

    /// A key backup was connected or keys were imported: messages without a key are asked for again at once (AC-SRCH-1).
    public func keysArrived() async {
        try? await index.retryUndecryptableNow()  // best-effort: the index repairs itself: the next pass redoes what is missing
        nudge()
    }

    /// Empties the index and reads everything again (Settings → Storage).
    public func rebuild() async throws(HaloError) {
        await source.endBatch()
        try await index.clear()
        statusAt = nil
        await refreshStatus()
        nudge()
    }

    /// Reads history until it is done, the conditions end it or the task is cancelled (a processing task on the charger).
    public func runInBackground() async {
        while !Task.isCancelled {
            switch await step() {
            case .worked: continue
            case .occupied: await rest(.seconds(1))
            case .idle, .failed: return await endBatch()
            }
        }
        await endBatch()
    }

    // MARK: Live lane

    private func receive(_ batch: SearchLiveBatch) async {
        var operations: [SearchIndexOperation] = []
        if !batch.left.isEmpty { operations.append(.removeRooms(batch.left.sorted { $0.rawValue < $1.rawValue })) }
        let events = batch.events.filter { !batch.left.contains($0.room) }
        if !events.isEmpty { operations.append(.live(events)) }
        let check = SearchIndexPolicy.roomsToCheck(batch)
        if !check.isEmpty { operations.append(.check(check.sorted { $0.rawValue < $1.rawValue })) }
        if !operations.isEmpty {
            hasWritten = true
            do { try await index.apply(operations) } catch {
                // What sync brought is gone from here: the rooms are read again from the server later.
                log?.error("search: writing a sync response failed", error: error)
                missed.formUnion(events.map(\.room))
            }
        }
        if batch.isCatchUp {
            await removeStaleRooms()
        }
        if !check.isEmpty { nudge() }
    }

    /// Rooms whose messages couldn't be written.
    private var missed: Set<RoomID> = []

    /// Rooms left while the app wasn't listening.
    private func removeStaleRooms() async {
        guard let joined = await source.joinedRooms(), !joined.isEmpty, let indexed = try? await index.indexedRooms() else { return }  // best-effort: the index repairs itself: the next pass redoes what is missing
        let stale = indexed.subtracting(joined)
        if !stale.isEmpty { try? await index.apply([.removeRooms(stale.sorted { $0.rawValue < $1.rawValue })]) }  // best-effort: the index repairs itself: the next pass redoes what is missing
    }

    // MARK: History lane

    private enum Step: Equatable { case worked, idle, failed, occupied }

    private func runHistory() async {
        while !Task.isCancelled {
            switch await step() {
            case .worked:
                // Leaves the device room to breathe: history takes about as long as it waits.
                await rest(lastDuration)
            case .idle, .occupied: await rest(status.phase == .paused(.busy) ? Self.busyInterval : Self.idleInterval)
            case .failed: await rest(SearchIndexPolicy.backoff(afterFailures: failures))
            }
        }
    }

    private var lastDuration: Duration = .zero

    /// Looks again now; kept when the lane isn't asleep yet, so it isn't lost between deciding to wait and waiting.
    private func nudge() {
        isNudged = true
        nap?.cancel()
    }

    private var isNudged = false

    private func rest(_ duration: Duration) async {
        guard duration > .zero, !Task.isCancelled, !isNudged else { return }
        let wait = sleep
        let task = Task { _ = try? await wait(duration) }  // best-effort: the index repairs itself: the next pass redoes what is missing
        nap = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        nap = nil
    }

    private func step() async -> Step {
        guard !isWorking else { return .occupied }
        isWorking = true
        defer { isWorking = false }
        isNudged = false
        var conditions = await conditions()
        if let busyUntil, clock() < busyUntil { conditions.isBusy = true }
        if let pause = SearchIndexPolicy.pause(conditions) {
            if pause != .busy { await endBatch() }
            await refreshStatus(phase: .paused(pause))
            return .idle
        }
        if !missed.isEmpty, (try? await index.apply([.check(missed.sorted { $0.rawValue < $1.rawValue })])) != nil { missed = [] }  // best-effort: the index repairs itself: the next pass redoes what is missing
        let joined = await rooms()
        let work: SearchHistoryWork?
        do { work = try await index.nextWork(rooms: joined, limit: 1).first } catch {
            await refreshStatus(phase: error == .storage(.unavailable) ? .unavailable : .indexing)
            return .idle
        }
        guard let work else {
            await endBatch()
            await refreshStatus(phase: .done)
            return .idle
        }
        await refreshStatus(phase: .indexing)
        let began = clock()
        hasWritten = true
        do {
            try await perform(work)
            failures = 0
            lastDuration = clock() - began
            return Task.isCancelled ? .idle : .worked
        } catch {
            return await failed(work, error)
        }
    }

    private func perform(_ work: SearchHistoryWork) async throws(HaloError) {
        switch work {
        case .check(let room):
            let recent = try await source.recentMessages(in: room, limit: SearchIndexPolicy.checkedEvents)
            let known = try await index.known(recent.map(\.event), in: room)
            let from: EventID? = switch SearchIndexPolicy.gapStart(recent: recent, known: known) {
            case .none: nil
            case .from(let event): event
            case .newest: try await source.newestEvent(in: room)
            }
            try await index.apply([.checked(room, gapFrom: from)])
        case .gap(let room, let event):
            // A page is usually enough; a longer gap goes on from where this one ends.
            let slice = try await read(room, from: event, pages: 1)
            try await index.apply([.slice(slice, .gap(room, before: event))])
        case .retry(let room, let event):
            let slice = try await read(room, from: event, pages: 1)
            try await index.apply([.slice(slice, .retry(room, around: event))])
        case .start(let room):
            guard let newest = try await source.newestEvent(in: room) else {
                try await index.apply([.slice(SearchHistorySlice(reachedStart: true), .history(room))])
                return
            }
            let slice = try await read(room, from: newest, pages: SearchIndexPolicy.pagesPerSlice)
            try await index.apply([.slice(slice, .history(room))])
        case .history(let room, let event):
            let slice = try await read(room, from: event, pages: SearchIndexPolicy.pagesPerSlice)
            try await index.apply([.slice(slice, .history(room))])
        }
    }

    private func read(_ room: RoomID, from event: EventID, pages: Int) async throws(HaloError) -> SearchHistorySlice {
        if roomsInClient.count >= SearchIndexPolicy.roomsPerClient || eventsInClient >= SearchIndexPolicy.eventsPerClient { await endBatch() }
        roomsInClient.insert(room)
        let slice = try await source.history(in: room, from: event, pages: pages)
        eventsInClient += slice.eventCount
        return slice
    }

    private func endBatch() async {
        guard !roomsInClient.isEmpty else { return }
        roomsInClient = []
        eventsInClient = 0
        await source.endBatch()
    }

    private func failed(_ work: SearchHistoryWork, _ error: HaloError) async -> Step {
        switch error {
        case .cancelled: return .idle
        case .notFound, .forbidden:
            // The server doesn't give this part of the room: other rooms go on.
            let operation: SearchIndexOperation = switch work {
            case .gap(let room, let event): .slice(SearchHistorySlice(reachedStart: true), .gap(room, before: event))
            case .retry(let room, let event): .slice(SearchHistorySlice(), .retry(room, around: event))
            case .check(let room): .checked(room, gapFrom: nil)
            case .start(let room), .history(let room, _): .blocked(room)
            }
            guard (try? await index.apply([operation])) != nil else { break }  // best-effort: the index repairs itself: the next pass redoes what is missing
            log?.info("search: part of a room isn't readable", error: error)
            return .worked
        default: break
        }
        failures += 1
        await endBatch()
        log?.info("search: reading history failed", error: error)
        return .failed
    }

    // MARK: Status

    /// Counting costs a moment on a large index: only when something was written, at most every two seconds, and at every change of phase.
    private func refreshStatus(phase: SearchIndexStatus.Phase? = nil) async {
        let phase = phase ?? status.phase
        if phase == status.phase, let statusAt, !hasWritten || clock() - statusAt < Self.statusInterval { return }
        statusAt = clock()
        hasWritten = false
        var new = status
        new.phase = phase
        let joined = await rooms()
        if let coverage = try? await index.coverage(), let statistics = try? await index.statistics() {  // best-effort: the index repairs itself: the next pass redoes what is missing
            new.totalRooms = joined.count
            new.completeRooms = joined.reduce(0) { count, room in count + (coverage[room].map { $0.state != .partial } ?? false ? 1 : 0) }
            new.searchedBackTo = SearchIndexPolicy.searchedBackTo(joined, coverage: coverage)
            new.statistics = statistics
        }
        status = new
    }
}
