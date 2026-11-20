import Foundation
import HaloDomain
import HaloFoundation

/// Keeps the app badge equal to the number of rooms that need attention, recomputed from the room list's read inputs
/// and the notification records on every change (D5, D9: never incremented). Because Synapse's native sliding sync
/// serves no notification counts (V-RS-7), the room list alone can't show unread: a notifying event the extension
/// fetched is a record (rule E4) that counts until the user reads the room here. The extension doesn't write the
/// badge from its own counter: it recomputes the same union (UNREAD_STATE §2, C5).
public actor BadgeCoordinator {
    public private(set) var attentionRooms: Set<RoomID> = []
    /// The first evaluation always writes, even an empty set, so a stale badge can be cleared.
    private var hasWritten = false

    private let rooms: RoomListCoordinator
    private let records: any NotificationRecordPort
    private let port: any BadgePort
    private let receipts: ReadReceiptCoordinator?
    private var audit: Audit?
    private var audited: [RoomID: Set<AuditFinding>] = [:]

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
    private var tasks: [Task<Void, Never>] = []

    public init(rooms: RoomListCoordinator, records: any NotificationRecordPort, port: any BadgePort, receipts: ReadReceiptCoordinator? = nil) {
        self.receipts = receipts
        self.rooms = rooms
        self.records = records
        self.port = port
    }

    deinit { for task in tasks { task.cancel() } }

    /// Starts following the room list and the records. Call once at launch.
    public func begin() async {
        guard tasks.isEmpty else { return }
        let roomInputs = await rooms.readInputs()
        let changes = records.changes()
        var follow: [Task<Void, Never>] = []
        if let receipts {
            let positions = await receipts.positions()
            follow.append(Task { [weak self] in for await positions in positions { await self?.positionsChanged(positions) } })
        }
        tasks = follow + [
            Task { [weak self] in for await inputs in roomInputs { await self?.roomsChanged(inputs) } },
            Task { [weak self] in for await _ in changes { await self?.recompute() } },
        ]
    }

    /// Starts (or, with `nil`, stops) the auditor. The audit store belongs to an account, so it is attached once the
    /// account's database is open and detached on sign-out.
    public func setAudit(_ audit: Audit?) {
        self.audit = audit
        audited = [:]
    }

    /// The badge value for the current states.
    public var badge: Int { attentionRooms.count }

    /// The attention set for `inputs` and `records`: every room whose state needs attention, plus rooms that have
    /// records but aren't in the loaded list (their only evidence is the push).
    public static func attention(inputs: [RoomReadInputs], records: [NotificationRecord], positions: [RoomID: Date] = [:]) -> Set<RoomID> {
        let byRoom = Dictionary(grouping: records, by: \.roomID)
        var result = Set(evaluated(inputs: inputs, records: records, positions: positions).filter(\.state.attention).map(\.input.roomID))
        let known = Set(inputs.map(\.roomID))
        for room in byRoom.keys where !known.contains(room) { result.insert(room) }
        return result
    }

    /// The policy's output for each room with the inputs it was given (the read position and the unconfirmed pushes folded in).
    public static func evaluated(inputs: [RoomReadInputs], records: [NotificationRecord], positions: [RoomID: Date] = [:])
        -> [(input: RoomReadInputs, state: RoomReadState)] {
        let byRoom = Dictionary(grouping: records, by: \.roomID)
        var result: [(input: RoomReadInputs, state: RoomReadState)] = []
        for input in inputs {
            // A pushed event the user has read (here, or on another device) is no longer unread.
            let readThrough = [positions[input.roomID], input.localIntent].compactMap { $0 }.max()
            let notified = (byRoom[input.roomID] ?? [])
                .filter { record in readThrough.map { record.timestamp > $0 } ?? true }
                .map { NotifiedRef(timestamp: $0.timestamp, isMention: $0.isMention) }
            let effective = RoomReadInputs(
                roomID: input.roomID, membership: input.membership, isEncrypted: input.isEncrypted, counts: input.counts,
                latestEvent: input.latestEvent, localIntent: readThrough, unconfirmedNotified: notified)
            result.append((effective, ReadStatePolicy.evaluate(effective)))
        }
        return result
    }

    private func positionsChanged(_ positions: [RoomID: Date]) async {
        self.positions = positions
        await recompute()
    }

    private func roomsChanged(_ inputs: [RoomReadInputs]) async {
        self.inputs = inputs
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

    private func recompute() async {
        let stored = records.all()
        await runAudit(Self.evaluated(inputs: inputs, records: stored, positions: positions))
        let attention = Self.attention(inputs: inputs, records: stored, positions: positions)
        guard attention != attentionRooms || !hasWritten else { return }
        hasWritten = true
        attentionRooms = attention
        await port.update(attentionRooms: attention)
    }
}
