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
    public private(set) var attentionRooms: Set<RoomID> = []
    /// The first evaluation always writes, even an empty set, so a stale badge can be cleared.
    private var hasWritten = false

    private let rooms: RoomListCoordinator
    private var records: (any NotificationRecordPort)?
    private let port: any BadgePort
    private let receipts: ReadReceiptCoordinator?
    private var audit: Audit?
    private var audited: [RoomID: Set<AuditFinding>] = [:]
    /// Rooms that needed attention at the last write (loaded from the port at launch) and that this run's room list
    /// hasn't shown yet. They keep their state until the list shows them or the first sync completes (D73, R-04).
    private var carried: Set<RoomID> = []
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
    private var positions: [RoomID: Date] = [:]
    private var inputs: [RoomReadInputs] = []
    private var statesBroadcaster = SnapshotBroadcaster<[RoomID: RoomReadState]>()
    private var tasks: [Task<Void, Never>] = []
    private var recordsTask: Task<Void, Never>?
    private let auditInterval: Duration
    private let sleep: Sleep
    private var isForeground = false
    private var periodicAudit: Task<Void, Never>?

    public init(
        rooms: RoomListCoordinator, records: (any NotificationRecordPort)? = nil, port: any BadgePort,
        receipts: ReadReceiptCoordinator? = nil, auditInterval: Duration = ReadStateCoordinator.defaultAuditInterval,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
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
        let roomInputs = await rooms.readInputs()
        let excluded = await rooms.excludedRoomChanges()
        let syncs = await rooms.syncCompletions()
        var follow: [Task<Void, Never>] = []
        if let receipts {
            let positions = await receipts.positions()
            follow.append(Task { [weak self] in for await positions in positions { await self?.positionsChanged(positions) } })
        }
        tasks = follow + [
            Task { [weak self] in for await inputs in roomInputs { await self?.roomsChanged(inputs) } },
            Task { [weak self] in for await rooms in excluded { await self?.excludedChanged(rooms) } },
            Task { [weak self] in for await present in syncs { await self?.syncCompleted(present) } },
        ]
        observeRecords()
    }

    /// Attaches (or, with `nil`, detaches) the signed-in account's persistent notification record store (R-13).
    public func attach(records: (any NotificationRecordPort)?) async {
        self.records = records
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
        carried.remove(room)
        seen.insert(room)
        excludedRooms.insert(room)
        records?.clear(room: room)
        await recompute()
    }

    /// Forces a fresh evaluation of all current read inputs, notification records and read positions,
    /// writing the badge and running the auditor (ROOM_LIST FR-8, SETTINGS §3). Preserves carried-over rooms (D73).
    public func reconcile() async {
        hasWritten = false
        await recompute()
    }

    /// Account change or sign-out: forgets everything, including the stored set and notification records, and clears the badge (R-03).
    public func reset() async {
        periodicAudit?.cancel()
        periodicAudit = nil
        carried = []
        seen = []
        excludedRooms = []
        hasSynced = false
        syncedRooms = []
        inputs = []
        if !roomStates.isEmpty {
            roomStates = [:]
            statesBroadcaster.publish([:])
        }
        attentionRooms = []
        hasWritten = false
        audited = [:]
        records?.clearAll()
        await port.reset()
    }

    /// The badge value for the current states.
    public var badge: Int { attentionRooms.count }

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
        evaluatedWithSuperseded(inputs: inputs, records: records, positions: positions).results
    }

    private static func evaluatedWithSuperseded(inputs: [RoomReadInputs], records: [NotificationRecord], positions: [RoomID: Date] = [:])
        -> (results: [(input: RoomReadInputs, state: RoomReadState)], superseded: Set<EventID>) {
        let byRoom = Dictionary(grouping: records, by: \.roomID)
        var results: [(input: RoomReadInputs, state: RoomReadState)] = []
        var superseded: Set<EventID> = []
        for input in inputs {
            let readThrough = [positions[input.roomID], input.localIntent].compactMap { $0 }.max()
            let base = RoomReadInputs(
                roomID: input.roomID, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
                latestEvent: input.latestEvent, localIntent: readThrough, receiptReadThrough: input.receiptReadThrough)
            let partition = ReadStatePolicy.partitionRecords(for: base, records: byRoom[input.roomID] ?? [])
            superseded.formUnion(partition.superseded)
            let effective = RoomReadInputs(
                roomID: input.roomID, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
                latestEvent: input.latestEvent, localIntent: readThrough, receiptReadThrough: input.receiptReadThrough,
                unconfirmedNotified: partition.unconfirmed)
            results.append((effective, ReadStatePolicy.evaluate(effective)))
        }
        return (results, superseded)
    }

    private func positionsChanged(_ positions: [RoomID: Date]) async {
        self.positions = positions
        await recompute()
    }

    private func roomsChanged(_ inputs: [RoomReadInputs]) async {
        self.inputs = inputs
        await recompute()
    }

    private func excludedChanged(_ rooms: Set<RoomID>) async {
        excludedRooms = rooms
        if !rooms.isEmpty {
            carried.subtract(rooms)
            seen.formUnion(rooms)
            records?.clear(rooms: rooms)
        }
        await recompute()
    }

    private func syncCompleted(_ present: Set<RoomID>?) async {
        guard let present else {
            hasSynced = false
            syncedRooms = []
            return
        }
        hasSynced = true
        syncedRooms = present
        // Drop any carried room that the server did not report as joined/invited (R-04).
        // Rooms in `present` whose diff hasn't arrived yet remain carried until their inputs arrive.
        carried.formIntersection(present)
        // Drop stale notification records for rooms not in the post-sync room set (R-03).
        if let stored = records?.all() {
            let absent = Set(stored.map(\.roomID)).subtracting(present)
            if !absent.isEmpty { records?.clear(rooms: absent) }
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
        if !events.isEmpty { try? await audit.port.append(events) }
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
        await runAudit(Self.evaluated(inputs: inputs, records: stored, positions: positions))
    }

    private func recompute() async {
        if !excludedRooms.isEmpty { records?.clear(rooms: excludedRooms) }
        let stored = records?.all() ?? []
        let pass = Self.evaluatedWithSuperseded(inputs: inputs, records: stored, positions: positions)
        if !pass.superseded.isEmpty {
            records?.remove(events: pass.superseded)
        }
        let nextStates = Dictionary(uniqueKeysWithValues: pass.results.map { ($0.input.roomID, $0.state) })
        if nextStates != roomStates {
            roomStates = nextStates
            statesBroadcaster.publish(nextStates)
        }
        await runAudit(pass.results)
        seen.formUnion(inputs.map(\.roomID))
        seen.formUnion(excludedRooms)
        let activeRecords = stored.filter { !pass.superseded.contains($0.eventID) && !excludedRooms.contains($0.roomID) }
        var attention = Set(pass.results.filter(\.state.attention).map(\.input.roomID))
        let known = Set(inputs.map(\.roomID))
        // Before the first sync response of the run, records for rooms not yet in the loaded list still count;
        // once sync has reported the full joined/invited set, unknown rooms no longer count (R-03, R-04).
        if !hasSynced {
            for record in activeRecords where !known.contains(record.roomID) { attention.insert(record.roomID) }
        }
        let carryable = hasSynced ? carried.intersection(syncedRooms) : carried
        attention.formUnion(carryable.subtracting(seen))
        attention.subtract(excludedRooms)
        carried = attention
        guard attention != attentionRooms || !hasWritten else { return }
        hasWritten = true
        attentionRooms = attention
        await port.update(attentionRooms: attention)
    }
}

/// Compatibility alias for tests and docs referencing the earlier name.
public typealias BadgeCoordinator = ReadStateCoordinator
