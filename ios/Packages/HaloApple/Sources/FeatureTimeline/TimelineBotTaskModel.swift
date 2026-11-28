import Foundation
import HaloApplication
import HaloBotRendering
import HaloDomain
import HaloFoundation
import Observation

/// Owns bot-card parsing, task-list state, pending 👍 ticks, and response timeouts for a room (audit F-08, BOT_MESSAGES §6).
@MainActor @Observable
public final class TimelineBotTaskModel {
    /// User IDs of bots whose messages may become cards (Settings → Bots, BOT_MESSAGES §3).
    public var botSenders: Set<String> = []
    /// Reports a known bot's message whose formatted body no template recognised (by event ID; for the diagnostics count).
    public var unrecognisedBotMessages: UnrecognisedBotMessages?
    /// Receives every snapshot of this room so the Activity index learns the bots' tasks (BOT_ACTIVITY FR-1).
    public var botActivity: BotActivityCoordinator?
    /// What the room's bot messages say about tasks (BOT_MESSAGES §6); recomputed with every snapshot.
    public internal(set) var tasks = BotTaskTracker([])
    /// Tasks the user ticked and the bot hasn't confirmed yet, and those that got no answer in time.
    var tapped: Set<BotTaskTracker.Key> = []
    var unanswered: Set<BotTaskTracker.Key> = []
    var timeouts: [BotTaskTracker.Key: Task<Void, Never>] = [:]
    /// How long to wait for the bot before showing "No response from bot" (BOT_MESSAGES §6).
    var timeout: Duration = .seconds(120)

    public init() {}

    isolated deinit {
        for task in timeouts.values { task.cancel() }
    }

    public func cancelTimeouts() {
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
    }

    /// Recomputes tracked bot tasks from a live snapshot and forwards them to `botActivity` when active.
    public func update(items: [TimelineItem], room: RoomID?, isFocused: Bool) {
        tasks = buildTracker(items)
        if let botActivity, let room, !botSenders.isEmpty, !isFocused {
            let senders = botSenders
            Task { await botActivity.observe(room: room, items: items, botSenders: senders) }
        }
        tapped.subtract(tasks.completed)
        unanswered.subtract(tasks.completed)
        for key in tasks.completed {
            timeouts.removeValue(forKey: key)?.cancel()
        }
    }

    /// The card for a message from an allowlisted bot whose HTML a parser recognises.
    public func card(for event: TimelineEvent) -> BotCard? {
        guard let sender = event.sender?.rawValue, botSenders.contains(sender), let html = event.formattedBody else { return nil }
        let card = BotTemplates.parse(html)
        if card == nil, let id = event.eventID?.rawValue { unrecognisedBotMessages?.record(eventID: id) }
        return card
    }

    /// The state of one row of a bot's todo list.
    public func rowState(bot: String?, id: String) -> TimelineViewModel.BotRowState {
        guard let bot else { return .unavailable }
        let key = BotTaskTracker.Key(bot: bot, id: id)
        if tasks.isCompleted(key) { return .completed }
        guard tasks.source(of: key) != nil else { return .unavailable }
        if tapped.contains(key) { return .pending }
        return unanswered.contains(key) ? .noResponse : .open
    }

    /// Ticks a row: one 👍 on the message that created the task, never on the list (BOT_MESSAGES FR-3).
    /// Ignored while pending, done or unavailable, and no second 👍 is sent when the user already has one on that message.
    public func tick(
        bot: String?,
        id: String,
        rows: [TimelineRow],
        toggleReaction: (EventID, String) async throws -> Void,
        onError: (String) -> Void
    ) async {
        guard let bot else { return }
        let state = rowState(bot: bot, id: id)
        guard state == .open || state == .noResponse else { return }
        let key = BotTaskTracker.Key(bot: bot, id: id)
        guard let source = tasks.source(of: key) else { return }
        unanswered.remove(key)
        tapped.insert(key)
        let alreadyReacted: Bool = {
            guard let target = rows.first(where: { $0.eventID == source.eventID }) else { return false }
            return target.reactions.contains { $0.key == "👍" && $0.reactedByMe }
        }()
        if !alreadyReacted {
            do {
                try await toggleReaction(source.eventID, "👍")
            } catch {
                tapped.remove(key)
                onError("That didn't work. Try again.")
                return
            }
        }
        timeouts[key]?.cancel()
        let delay = timeout
        timeouts[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.timedOut(key)
        }
    }

    func timedOut(_ key: BotTaskTracker.Key) {
        guard tapped.remove(key) != nil else { return }
        unanswered.insert(key)
        timeouts[key] = nil
    }

    private func buildTracker(_ items: [TimelineItem]) -> BotTaskTracker {
        guard !botSenders.isEmpty else { return BotTaskTracker([]) }
        var messages: [BotTaskTracker.Message] = []
        for item in items {
            guard case .event(let event) = item.content, let card = card(for: event), let sender = event.sender?.rawValue else { continue }
            messages.append(.init(bot: sender, eventID: event.eventID, card: card))
        }
        return BotTaskTracker(messages)
    }
}
