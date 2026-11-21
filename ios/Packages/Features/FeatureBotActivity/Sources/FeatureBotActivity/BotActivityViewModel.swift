import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Presents the bot task index (docs/features/BOT_ACTIVITY.md): sections Open / Reminders / Completed, filters by room and bot.
/// The index is what Halo has seen in message timelines on this device, never the bot's own list: the screen says so.
@MainActor @Observable
public final class BotActivityViewModel: Identifiable {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: BotTaskEntry.Key { key }
        public let key: BotTaskEntry.Key
        public let title: String
        public let roomName: String
        /// The bot's user ID without `@` and server, e.g. "todobot".
        public let botName: String
        /// A reminder's time as the bot wrote it, or a task's owner.
        public let detail: String?
        /// When the newest bot message about it was sent ("as of").
        public let asOf: Date
        public let sourceEventID: EventID?
    }

    public struct Sections: Equatable, Sendable {
        public var open: [Item] = []
        public var reminders: [Item] = []
        public var completed: [Item] = []
        public var isEmpty: Bool { open.isEmpty && reminders.isEmpty && completed.isEmpty }
    }

    public enum Phase: Equatable, Sendable { case loading, loaded, failed }

    /// Completed tasks stay listed this long after the bot's confirmation (BOT_ACTIVITY FR-3).
    public static let completedWindow: TimeInterval = 7 * 24 * 3600

    public private(set) var phase: Phase = .loading
    public private(set) var entries: [BotTaskEntry] = []
    public var roomFilter: RoomID?
    public var botFilter: String?

    private let coordinator: BotActivityCoordinator
    private let roomName: @MainActor (RoomID) -> String?
    private let now: @Sendable () -> Date

    public init(coordinator: BotActivityCoordinator, roomName: @escaping @MainActor (RoomID) -> String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.coordinator = coordinator
        self.roomName = roomName
        self.now = now
    }

    public func load() async {
        let snapshot = await coordinator.snapshot()
        if snapshot.failed {
            phase = .failed
        } else {
            entries = snapshot.entries
            phase = .loaded
        }
    }

    /// "Rebuild index": empties it; rooms fill it again as they are opened.
    public func rebuild() async {
        await coordinator.rebuild()
        roomFilter = nil
        botFilter = nil
        await load()
    }

    /// Rooms and bots that have entries, for the filter menus.
    public var roomChoices: [(id: RoomID, name: String)] {
        Dictionary(grouping: entries, by: \.key.room).keys.map { ($0, name(of: $0)) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var botChoices: [String] { Array(Set(entries.map(\.key.bot))).sorted() }

    public var sections: Sections {
        let cutoff = now().addingTimeInterval(-Self.completedWindow)
        var result = Sections()
        for entry in entries where roomFilter == nil || entry.key.room == roomFilter {
            guard botFilter == nil || entry.key.bot == botFilter else { continue }
            let item = Item(
                key: entry.key, title: entry.title ?? "Task #\(entry.key.id)", roomName: name(of: entry.key.room), botName: Self.botName(entry.key.bot),
                detail: entry.detail, asOf: entry.asOf, sourceEventID: entry.sourceEventID)
            switch (entry.status, entry.key.kind) {
            case (.open, .todo): result.open.append(item)
            case (.open, .reminder): result.reminders.append(item)
            case (.completed, _) where entry.asOf >= cutoff: result.completed.append(item)
            default: break  // deleted, or completed long ago
            }
        }
        return result
    }

    private func name(of room: RoomID) -> String { roomName(room) ?? "Unknown room" }

    static func botName(_ id: String) -> String {
        id.hasPrefix("@") ? String(id.dropFirst().prefix { $0 != ":" }) : id
    }
}
