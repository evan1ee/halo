import Foundation
import HaloDomain
import HaloFoundation

/// Keeps the Activity index (docs/features/BOT_ACTIVITY.md): `observe` is called with every snapshot of an open timeline and
/// stores what its known bots' messages say about tasks; `snapshot` reads it back for the Activity screen. It never talks to the
/// network, and it only knows rooms whose timeline has been opened on this device ("From messages on this device").
public actor BotActivityCoordinator {
    /// What the Activity screen shows.
    public struct Snapshot: Sendable, Equatable {
        public var entries: [BotTaskEntry]
        /// The index couldn't be read.
        public var failed: Bool
        public init(entries: [BotTaskEntry] = [], failed: Bool = false) {
            self.entries = entries
            self.failed = failed
        }
    }

    private var port: (any BotTaskPort)?
    private let timelines: (any TimelinePort)?
    private let settle: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The newest-event time of each room as of its last background scan, so a room is read again only when something new arrived.
    private var scanned: [RoomID: Date] = [:]
    private var scanning = false
    /// At most this many rooms are read per `scan`, newest first.
    public static let scanLimit = 8
    private let log: HaloLog?
    private let now: @Sendable () -> Date
    /// Entries whose newest bot message is older than this are dropped when an account is attached (BOT_ACTIVITY FR-5).
    public static let retention: TimeInterval = 90 * 24 * 3600
    /// The last entries stored per room, so an unchanged timeline snapshot writes nothing.
    private var lastWritten: [RoomID: [BotTaskEntry]] = [:]

    /// - Parameter timelines: when given, `scan` can read rooms that aren't open by briefly opening their timelines.
    public init(
        port: (any BotTaskPort)? = nil, timelines: (any TimelinePort)? = nil, log: HaloLog? = nil, now: @escaping @Sendable () -> Date = { Date() },
        settle: Duration = .seconds(2), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.timelines = timelines
        self.settle = settle
        self.sleep = sleep
        self.port = port
        self.log = log?.with(category: .bot)
    }

    /// Reads the bot messages in `items` (oldest first) and stores the entries they describe. Cheap when `botSenders` is empty or
    /// nothing changed.
    public func observe(room: RoomID, items: [TimelineItem], botSenders: Set<String>) async {
        guard let port, !botSenders.isEmpty else { return }
        await markDeletedSources(room: room, items: items, port: port)
        var observations: [BotObservation] = []
        for item in items {
            guard case .event(let event) = item.content, let sender = event.sender?.rawValue, botSenders.contains(sender),
                let html = event.formattedBody, let card = BotTemplates.parse(html)
            else { continue }
            observations.append(BotObservation(bot: sender, eventID: event.eventID, timestamp: event.timestamp, card: card))
        }
        let entries = BotTaskDerivation.entries(room: room, observations: observations)
        guard entries != lastWritten[room], !entries.isEmpty else { return }
        do {
            try await port.upsert(entries)
            lastWritten[room] = entries
        } catch {
            // The index is derived: a failed write is retried by the next snapshot of the same timeline.
            log?.warning("bot task index write failed", error: error)
        }
    }

    /// A room as the room list knows it, for deciding which rooms to read in the background.
    public struct RoomHint: Sendable, Equatable {
        public let room: RoomID
        /// Who wrote the room's newest message, when known.
        public let latestSender: String?
        public let latestAt: Date?
        public init(room: RoomID, latestSender: String?, latestAt: Date?) {
            self.room = room
            self.latestSender = latestSender
            self.latestAt = latestAt
        }
    }

    /// Reads rooms that aren't open (BOT_ACTIVITY FR-1, "from rooms as they are synced"): for rooms whose newest message is from an
    /// allowlisted bot and that changed since the last scan, a timeline is opened just long enough to take its first snapshot, which
    /// goes through `observe`. Newest rooms first, at most `scanLimit` per call, one at a time; a room that can't be opened is
    /// tried again at its next change.
    public func scan(_ rooms: [RoomHint], botSenders: Set<String>) async {
        guard let timelines, port != nil, !botSenders.isEmpty, !scanning else { return }
        scanning = true
        defer { scanning = false }
        let due = rooms
            .filter { hint in hint.latestSender.map(botSenders.contains) == true && scanned[hint.room] != hint.latestAt }
            .sorted { ($0.latestAt ?? .distantPast) > ($1.latestAt ?? .distantPast) }
            .prefix(Self.scanLimit)
        for hint in due {
            let coordinator = TimelineCoordinator(port: timelines, room: hint.room)
            await coordinator.open()
            let items = await firstItems(of: coordinator)
            await coordinator.close()
            guard let items else { continue }
            scanned[hint.room] = hint.latestAt
            await observe(room: hint.room, items: items, botSenders: botSenders)
        }
    }

    /// The items of the first live snapshot that has any (or of the last one seen when none has by `settle`); `nil` when the
    /// timeline couldn't be opened.
    private func firstItems(of coordinator: TimelineCoordinator) async -> [TimelineItem]? {
        let watcher = Task<[TimelineItem]?, Never> {
            var latest: [TimelineItem]?
            for await status in await coordinator.statuses() {
                switch status {
                case .live(let snapshot):
                    latest = snapshot.items
                    if !snapshot.items.isEmpty { return latest }
                case .failed: return nil
                case .idle, .opening: continue
                }
            }
            return latest
        }
        let sleep = sleep, settle = settle
        let timer = Task {
            try? await sleep(settle)
            watcher.cancel()
        }
        let items = await watcher.value
        timer.cancel()
        return items
    }

    /// A task whose creating message was deleted keeps its entry but can't be ticked or opened at (BOT_ACTIVITY FR-1, redaction).
    private func markDeletedSources(room: RoomID, items: [TimelineItem], port: any BotTaskPort) async {
        var redacted: Set<EventID> = []
        for item in items {
            if case .event(let event) = item.content, case .redacted = event.kind, let id = event.eventID { redacted.insert(id) }
        }
        guard !redacted.isEmpty, let stored = try? await port.entries() else { return }
        var changed = stored.filter { $0.key.room == room && !$0.sourceRedacted && $0.sourceEventID.map(redacted.contains) == true }
        guard !changed.isEmpty else { return }
        for index in changed.indices { changed[index].sourceRedacted = true }
        do { try await port.upsert(changed) } catch { log?.warning("bot task redaction write failed", error: error) }
    }

    public func snapshot() async -> Snapshot {
        guard let port else { return Snapshot() }
        do { return Snapshot(entries: try await port.entries()) } catch { return Snapshot(failed: true) }
    }

    /// "Rebuild index": empties it; it fills again from timelines as they are opened.
    public func rebuild() async {
        lastWritten = [:]
        scanned = [:]
        try? await port?.removeAll()
    }

    /// Starts keeping the index of the signed-in account in `port`.
    public func attach(_ port: any BotTaskPort) async {
        self.port = port
        lastWritten = [:]
        scanned = [:]
        do { try await port.prune(before: now().addingTimeInterval(-Self.retention)) } catch { log?.warning("bot task prune failed", error: error) }
    }

    /// Sign-out: drops the port and the write cache, so nothing of this account is read or written for the next one.
    public func reset() {
        port = nil
        lastWritten = [:]
        scanned = [:]
    }
}
