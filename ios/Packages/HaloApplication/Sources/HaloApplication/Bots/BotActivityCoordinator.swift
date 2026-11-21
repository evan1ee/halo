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

    private let port: any BotTaskPort
    private let log: HaloLog?
    /// The last entries stored per room, so an unchanged timeline snapshot writes nothing.
    private var lastWritten: [RoomID: [BotTaskEntry]] = [:]

    public init(port: any BotTaskPort, log: HaloLog? = nil) {
        self.port = port
        self.log = log?.with(category: .bot)
    }

    /// Reads the bot messages in `items` (oldest first) and stores the entries they describe. Cheap when `botSenders` is empty or
    /// nothing changed.
    public func observe(room: RoomID, items: [TimelineItem], botSenders: Set<String>) async {
        guard !botSenders.isEmpty else { return }
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

    public func snapshot() async -> Snapshot {
        do { return Snapshot(entries: try await port.entries()) } catch { return Snapshot(failed: true) }
    }

    /// "Rebuild index": empties it; it fills again from timelines as they are opened.
    public func rebuild() async {
        lastWritten = [:]
        try? await port.removeAll()
    }

    /// Forgets the in-memory write cache (sign-out).
    public func reset() { lastWritten = [:] }
}
