import Foundation
import HaloDomain
import HaloFoundation

/// The single owner of read-state evaluation (docs/matrix/UNREAD_STATE.md §7, R-05).
///
/// Assembles `RoomReadInputs` for every room from the room list, local read intents, notification records and
/// sync completeness, evaluates `ReadStatePolicy` once, publishes `[RoomID: RoomReadState]` to the room list,
/// runs the read-state auditor, and writes the recomputed attention set / app badge (D5, D9: never incremented).
public actor ReadStateCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    /// How often the read-state auditor re-runs while the app is in the foreground (LOGGING_AND_DIAGNOSTICS §2).
    public static let defaultAuditInterval: Duration = .seconds(600)

    /// The latest evaluated read state per visible room; consumed by the room list so list and badge always agree (R-05).
    public private(set) var roomStates: [RoomID: RoomReadState] = [:]
    /// Per-room unread badge counts for rooms needing attention (D82).
    public private(set) var attentionCounts: [RoomID: Int] = [:]
    public var attentionRooms: Set<RoomID> { Set(attentionCounts.keys) }
    /// The first evaluation always writes, even an empty set, so a stale badge can be cleared.
    private var hasWritten = false

    private let rooms: RoomListCoordinator
    private var records: (any NotificationRecordPort)?
    private let port: any BadgePort
    private let receipts: ReadReceiptCoordinator?
    private var audit: Audit?
    private var audited: [RoomID: Set<AuditFinding>] = [:]
    /// Per-room badge counts carried from the last write (loaded from the port at launch) for rooms this run's room
    /// list hasn't shown yet. Kept until the list shows them or the first sync completes (D73, R-04, D82).
    private var carried: [RoomID: Int] = [:]
    /// What was shown when this run started: a floor for each room until the first sync response (rule E6), then empty.
    private var shownAtLaunch: [RoomID: Int] = [:]
    /// Rooms the list has shown in this run; once shown, a room that disappears from the list is dropped, not carried.
    private var seen: Set<RoomID> = []
    /// Rooms that must not count towards attention (left, hidden sticker-pack rooms, ignored-inviter invites, R-03).
    private var excludedRooms: Set<RoomID> = []
    /// Whether the first sync response of this run has completed (R-04): once true, carried rooms and records for rooms
    /// not reported as joined/invited by the server are dropped.
    private var hasSynced = false
    private var syncedRooms: Set<RoomID> = []

    /// Where the read-state auditor writes (LOGGING_AND_DIAGNOSTICS §2): debug and TestFlight builds only.
    public struct Audit: Sendable {
        let port: any AuditEventPort
        let roomHash: @Sendable (RoomID) -> String
        let appVersion: String
        let now: @Sendable () -> Date

        public init(port: any AuditEventPort, roomHash: @escaping @Sendable (RoomID) -> String, appVersion: String, now: @escaping @Sendable () -> Date = { Date() }) {
            self.port = port
            self.roomHash = roomHash
            self.appVersion = appVersion
            self.now = now
        }
    }
    private var readPositions: [RoomID: LocalReadPosition] = [:]
    /// Incremented on every completed sync response; used to know when a sent receipt has gone through at least one
    /// sync round-trip (R-06, ADR-0020).
    public private(set) var syncEpoch = 0
    /// The room list's sync count this coordinator last applied, and the newest epoch whose evaluation has been written.
    private var appliedSyncCount = 0
    private var writtenSyncEpoch = 0
    private var syncWaiters: [UUID: (epoch: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    /// The newest queued port write; writes run one at a time in evaluation order, so an older one can't land last.
    private var lastWrite: Task<Void, Never>?
    /// Records as last read; kept when the database can't be read (suspended, still locked) instead of counting none.
    private var lastRecords: [NotificationRecord] = []
    /// For each room whose local intent became `.isSent`, the `(eventID, syncEpoch)` at which it was observed sent.
    private var sentAtEpoch: [RoomID: (eventID: EventID, epoch: Int)] = [:]
    private var inputs: [RoomReadInputs] = []
    private var statesBroadcaster = SnapshotBroadcaster<[RoomID: RoomReadState]>()
    private var tasks: [Task<Void, Never>] = []
    private var recordsTask: Task<Void, Never>?
    private let auditInterval: Duration
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private var isForeground = false
    private var periodicAudit: Task<Void, Never>?

    public init(
        rooms: RoomListCoordinator, records: (any NotificationRecordPort)? = nil, port: any BadgePort,
        receipts: ReadReceiptCoordinator? = nil, auditInterval: Duration = ReadStateCoordinator.defaultAuditInterval,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.receipts = receipts
        self.rooms = rooms
        self.records = records
        self.port = port
        self.auditInterval = auditInterval
        self.sleep = sleep
    }

    deinit {
        for task in tasks { task.cancel() }
        recordsTask?.cancel()
        periodicAudit?.cancel()
    }

    /// The latest evaluated read states per room, now and after each change; latest value wins (R-05).
    public func states() -> AsyncStream<[RoomID: RoomReadState]> {
        statesBroadcaster.subscribe(current: roomStates)
    }

    /// Starts following the room list, read receipts, sync completions and notification records. Call once at launch.
    public func begin() async {
        guard tasks.isEmpty else { return }
        carried = await port.lastAttention()
        shownAtLaunch = carried
        let snapshots = await rooms.readSnapshots()
        let excluded = await rooms.excludedRoomChanges()
        var follow: [Task<Void, Never>] = []
        if let receipts {
            let positions = await receipts.readPositions()
            follow.append(Task { [weak self] in for await positions in positions { await self?.readPositionsChanged(positions) } })
        }
        tasks = follow + [
            Task { [weak self] in for await snapshot in snapshots { await self?.snapshotChanged(snapshot) } },
            Task { [weak self] in for await rooms in excluded { await self?.excludedChanged(rooms) } },
        ]
        observeRecords()
    }

    /// Attaches (or, with `nil`, detaches) the signed-in account's persistent notification record store (R-13).
    public func attach(records: (any NotificationRecordPort)?) async {
        self.records = records
        lastRecords = []
        if !tasks.isEmpty { observeRecords() }
        if records != nil { await recompute() }
    }

    private func observeRecords() {
        recordsTask?.cancel()
        recordsTask = nil
        guard let records else { return }
        let changes = records.changes()
        recordsTask = Task { [weak self] in
            for await _ in changes { await self?.recompute() }
        }
    }

    /// Starts (or, with `nil`, stops) the auditor. The audit store belongs to an account, so it is attached once the
    /// account's database is open and detached on sign-out.
    public func setAudit(_ audit: Audit?) {
        self.audit = audit
        audited = [:]
        updatePeriodicAudit()
    }

    /// Runs the read-state auditor every 10 minutes while the app is in the foreground (LOGGING_AND_DIAGNOSTICS §2).
    public func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        updatePeriodicAudit()
    }

    /// Drops the stored state and notification records of `room` (the user left it) so it isn't carried over (R-03).
    public func forget(_ room: RoomID) async {
        carried.removeValue(forKey: room)
        seen.insert(room)
        excludedRooms.insert(room)
        records?.clear(room: room)
        await recompute()
    }

    /// Forces a fresh evaluation of all current read inputs, notification records and read positions,
    /// writing the badge and running the auditor (ROOM_LIST FR-8, SETTINGS §3). Preserves carried-over rooms (D73).
    /// No-op before `begin()` so a cold-launch foreground transition never overwrites the cached badge with 0.
    public func reconcile() async {
        guard !tasks.isEmpty else { return }
        hasWritten = false
        await recompute()
    }

    /// Waits until the evaluation of a sync response after `epoch` has reached the badge and the widgets, so background work
    /// can report "done" to iOS only then (iOS suspends the app right after). `false` if it takes longer than `timeout`.
    public func waitForSync(after epoch: Int, timeout: Duration) async -> Bool {
        if writtenSyncEpoch > epoch { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            syncWaiters[id] = (epoch, continuation)
            Task { [weak self, sleep] in
                try? await sleep(timeout)
                await self?.finishWaiter(id, reached: false)
            }
        }
    }

    private func finishWaiter(_ id: UUID, reached: Bool) {
        syncWaiters.removeValue(forKey: id)?.continuation.resume(returning: reached)
    }

    /// Account change or sign-out: forgets everything, including the stored counts and notification records, and clears the badge (R-03).
    public func reset() async {
        periodicAudit?.cancel()
        periodicAudit = nil
        carried = [:]
        shownAtLaunch = [:]
        lastRecords = []
        seen = []
        excludedRooms = []
        hasSynced = false
        syncedRooms = []
        syncEpoch = 0
        sentAtEpoch = [:]
        readPositions = [:]
        inputs = []
        if !roomStates.isEmpty {
            roomStates = [:]
            statesBroadcaster.publish([:])
        }
        attentionCounts = [:]
        hasWritten = false
        audited = [:]
        records?.clearAll()
        await enqueue { [port] in await port.reset() }
    }

    /// Runs `write` after every earlier one and returns when it has landed. Not tied to the caller's cancellation: a scene
    /// phase change must not drop a badge write halfway.
    private func enqueue(_ write: @escaping @Sendable () async -> Void) async {
        let previous = lastWrite
        let task = Task {
            await previous?.value
            await write()
        }
        lastWrite = task
        await task.value
    }

    /// The badge value for the current states: total unread messages across rooms needing attention (D82).
    public var badge: Int { attentionCounts.values.reduce(0, +) }

    /// The attention set for `inputs` and `records`: every room whose state needs attention, plus rooms that have
    /// records but aren't in the loaded list (excluding left/hidden/ignored rooms, R-03).
    public static func attention(
        inputs: [RoomReadInputs], records: [NotificationRecord], positions: [RoomID: Date] = [:], excluded: Set<RoomID> = []
    ) -> Set<RoomID> {
        let byRoom = Dictionary(grouping: records, by: \.roomID)
        var result = Set(evaluated(inputs: inputs, records: records, positions: positions).filter(\.state.attention).map(\.input.roomID))
        let known = Set(inputs.map(\.roomID))
        for room in byRoom.keys where !known.contains(room) && !excluded.contains(room) { result.insert(room) }
        return result
    }

    /// The policy's output for each room with the inputs it was given (the read position and the unconfirmed pushes folded in).
    public static func evaluated(inputs: [RoomReadInputs], records: [NotificationRecord], positions: [RoomID: Date] = [:])
        -> [(input: RoomReadInputs, state: RoomReadState)] {
        evaluatedWithSuperseded(inputs: inputs, records: records, legacyPositions: positions).results
    }

    private static func evaluatedWithSuperseded(
        inputs: [RoomReadInputs], records: [NotificationRecord],
        readPositions: [RoomID: LocalReadPosition] = [:], legacyPositions: [RoomID: Date] = [:],
        syncEpoch: Int = 0, sentAtEpoch: [RoomID: (eventID: EventID, epoch: Int)] = [:],
        unsyncedCarried: [RoomID: Int] = [:]
    ) -> (results: [(input: RoomReadInputs, state: RoomReadState)], superseded: Set<EventID>) {
        let byRoom = Dictionary(grouping: records, by: \.roomID)
        var results: [(input: RoomReadInputs, state: RoomReadState)] = []
        var superseded: Set<EventID> = []
        for input in inputs {
            let localPos = readPositions[input.roomID]
            let useLocal: Bool = {
                guard let localPos else { return false }
                if !localPos.isSent { return true }
                guard let remoteTs = input.localIntent else { return true }
                return localPos.timestamp >= remoteTs
            }()
            let readThrough: Date? = {
                if useLocal, let localPos { return localPos.timestamp }
                return [localPos?.timestamp, legacyPositions[input.roomID], input.localIntent].compactMap { $0 }.max()
            }()
            let intentEventID: EventID? = useLocal
                ? localPos?.eventID
                : (input.ownReceiptEventID ?? input.localIntentEventID ?? localPos?.eventID)
            let intentConfirmed: Bool = {
                if useLocal, let localPos {
                    guard localPos.isSent else { return false }
                    if input.ownReceiptEventID == localPos.eventID { return true }
                    if let sent = sentAtEpoch[input.roomID], sent.eventID == localPos.eventID, syncEpoch > sent.epoch { return true }
                    return false
                }
                return input.localIntentConfirmed || (input.ownReceiptEventID != nil && input.localIntent != nil)
            }()
            let base = RoomReadInputs(
                roomID: input.roomID, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
                latestEvent: input.latestEvent, localIntent: readThrough, receiptReadThrough: input.receiptReadThrough,
                localIntentEventID: intentEventID, localIntentConfirmed: intentConfirmed, ownReceiptEventID: input.ownReceiptEventID)
            let partition = ReadStatePolicy.partitionRecords(for: base, records: byRoom[input.roomID] ?? [])
            superseded.formUnion(partition.superseded)
            let effective = RoomReadInputs(
                roomID: input.roomID, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
                latestEvent: input.latestEvent, localIntent: readThrough, receiptReadThrough: input.receiptReadThrough,
                localIntentEventID: intentEventID, localIntentConfirmed: intentConfirmed, ownReceiptEventID: input.ownReceiptEventID,
                unconfirmedNotified: partition.unconfirmed, unsyncedCarried: unsyncedCarried[input.roomID] ?? 0)
            results.append((effective, ReadStatePolicy.evaluate(effective)))
        }
        return (results, superseded)
    }

    private func readPositionsChanged(_ positions: [RoomID: LocalReadPosition]) async {
        readPositions = positions
        for (room, pos) in positions {
            if pos.isSent {
                if sentAtEpoch[room]?.eventID != pos.eventID {
                    sentAtEpoch[room] = (pos.eventID, syncEpoch)
                }
            } else {
                sentAtEpoch[room] = nil
            }
        }
        sentAtEpoch = sentAtEpoch.filter { positions[$0.key] != nil }
        await recompute()
    }

    private func snapshotChanged(_ snapshot: RoomReadSnapshot) async {
        inputs = snapshot.inputs
        let responses = snapshot.syncCount - appliedSyncCount
        appliedSyncCount = snapshot.syncCount
        guard let present = snapshot.present else {
            hasSynced = false
            syncedRooms = []
            return await recompute()
        }
        guard responses > 0 else { return await recompute() }
        hasSynced = true
        shownAtLaunch = [:]  // a later resubscription must not bring launch-time counts back
        syncEpoch += responses
        syncedRooms = present
        // Drop any carried room that the server did not report as joined/invited (R-04).
        // Rooms in `present` whose diff hasn't arrived yet remain carried until their inputs arrive.
        carried = carried.filter { present.contains($0.key) }
        // Drop stale notification records for rooms not in the post-sync room set (R-03).
        if let stored = records?.all() {
            let absent = Set(stored.map(\.roomID)).subtracting(present)
            if !absent.isEmpty { records?.clear(rooms: absent) }
        }
        // Each sync response writes even unchanged counts: whatever else touched the icon since (a push handled by the
        // extension while the app was opening, the system) is corrected within one sync.
        hasWritten = false
        let epoch = syncEpoch
        await recompute()
        writtenSyncEpoch = max(writtenSyncEpoch, epoch)
        for (id, waiter) in syncWaiters where writtenSyncEpoch > waiter.epoch { finishWaiter(id, reached: true) }
    }

    private func excludedChanged(_ rooms: Set<RoomID>) async {
        excludedRooms = rooms
        if !rooms.isEmpty {
            for room in rooms { carried.removeValue(forKey: room) }
            seen.formUnion(rooms)
            records?.clear(rooms: rooms)
        }
        await recompute()
    }

    /// Writes the findings that are new for a room (a finding that persists isn't written again until it goes away).
    private func runAudit(_ evaluated: [(input: RoomReadInputs, state: RoomReadState)]) async {
        guard let audit else { return }
        var events: [AuditEvent] = []
        var next: [RoomID: Set<AuditFinding>] = [:]
        for (input, state) in evaluated {
            let findings = Set(ReadStateAuditor.audit(input, state: state))
            if findings.isEmpty { continue }
            next[input.roomID] = findings
            for finding in findings.subtracting(audited[input.roomID] ?? []).sorted(by: { $0.reason < $1.reason }) {
                events.append(AuditEvent(
                    at: audit.now(), roomHash: audit.roomHash(input.roomID), finding: finding,
                    inputsJSON: AuditEvent.inputsJSON(for: input), appVersion: audit.appVersion))
            }
        }
        audited = next
        if !events.isEmpty { try? await audit.port.append(events) }  // best-effort: diagnostics, cache or best-effort sync; the next update repeats it
    }

    private func updatePeriodicAudit() {
        periodicAudit?.cancel()
        periodicAudit = nil
        guard isForeground, audit != nil else { return }
        let interval = auditInterval
        let sleep = sleep
        periodicAudit = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.auditCurrentState()
            }
        }
    }

    private func auditCurrentState() async {
        let stored = records?.all() ?? []
        await runAudit(Self.evaluatedWithSuperseded(
            inputs: inputs, records: stored, readPositions: readPositions, syncEpoch: syncEpoch, sentAtEpoch: sentAtEpoch).results)
    }

    /// The stored records, or the last ones read when the database can't be read right now.
    private func currentRecords() -> [NotificationRecord] {
        guard let records else { return [] }
        if let stored = records.load() { lastRecords = stored }
        return lastRecords
    }

    /// Evaluates everything and queues the result. No suspension point between reading the inputs and queueing the write, so
    /// the queue order is the evaluation order.
    private func recompute() async {
        let evaluatedAt = now()
        if !excludedRooms.isEmpty { records?.clear(rooms: excludedRooms) }
        let stored = currentRecords()
        let floor = shownAtLaunch.filter { readPositions[$0.key]?.isFromThisRun != true }
        let pass = Self.evaluatedWithSuperseded(
            inputs: inputs, records: stored, readPositions: readPositions, syncEpoch: syncEpoch, sentAtEpoch: sentAtEpoch,
            unsyncedCarried: floor)
        if !pass.superseded.isEmpty {
            records?.remove(events: pass.superseded)
        }
        let nextStates = Dictionary(uniqueKeysWithValues: pass.results.map { ($0.input.roomID, $0.state) })
        if nextStates != roomStates {
            roomStates = nextStates
            statesBroadcaster.publish(nextStates)
        }
        seen.formUnion(inputs.map(\.roomID))
        seen.formUnion(excludedRooms)
        let activeRecords = stored.filter { !pass.superseded.contains($0.eventID) && !excludedRooms.contains($0.roomID) }
        var counts: [RoomID: Int] = [:]
        for (input, state) in pass.results where state.attention {
            counts[input.roomID] = max(state.badgeCount, 1)
        }
        let known = Set(inputs.map(\.roomID))
        // Before the first sync response of the run, records for rooms not yet in the loaded list still count;
        // once sync has reported the full joined/invited set, unknown rooms no longer count (R-03, R-04).
        if !hasSynced {
            for record in activeRecords where !known.contains(record.roomID) {
                counts[record.roomID, default: 0] += 1
            }
        }
        let carryable = hasSynced ? carried.filter { syncedRooms.contains($0.key) } : carried
        for (room, count) in carryable where !seen.contains(room) && !excludedRooms.contains(room) && count > 0 {
            // The stored count already includes the records the extension added to it: the larger one, never the sum.
            counts[room] = max(counts[room] ?? 0, count)
        }
        for room in excludedRooms { counts.removeValue(forKey: room) }
        carried = counts
        if counts != attentionCounts || !hasWritten {
            hasWritten = true
            attentionCounts = counts
            let snapshot = BadgeSnapshot(
                attentionCounts: counts, evaluatedAt: evaluatedAt,
                syncedThrough: inputs.reduce(into: [:]) { $0[$1.roomID] = $1.latestEvent?.timestamp })
            await enqueue { [port] in await port.update(snapshot) }
        }
        await runAudit(pass.results)
    }
}

/// Compatibility alias for tests and docs referencing the earlier name.
public typealias BadgeCoordinator = ReadStateCoordinator
