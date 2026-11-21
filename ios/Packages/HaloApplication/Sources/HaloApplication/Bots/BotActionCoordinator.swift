import Foundation
import HaloDomain
import HaloFoundation

/// Ticks a bot task from the Activity screen (docs/features/BOT_MESSAGES.md FR-3/§6, BOT_ACTIVITY FR-4): one 👍 on the message that
/// created the task, never on a list, and "done" only when the bot confirms (a newer list, or `Marked task as done`, seen in the
/// room's timeline). Delivery of the reaction is not confirmation. While a tick is pending a short-lived timeline of the room is
/// kept open, so the bot's answer reaches the index even though the user isn't in the room; it is closed at confirmation, at the
/// timeout (state `.noResponse`, tap again to retry) or on failure.
///
/// Pending state is in memory only (`bot_action` isn't built): after a restart the task simply shows open again, and a second tick
/// is safe because the reaction is only added when absent.
public actor BotActionCoordinator {
    public enum State: Sendable, Equatable {
        /// 👍 sent, waiting for the bot.
        case pending
        /// The reaction couldn't be sent.
        case failed
        /// No confirmation within `timeout`.
        case noResponse
    }

    /// How long to wait for the bot before reporting "No response from bot" (BOT_MESSAGES §6).
    public static let defaultTimeout: Duration = .seconds(120)

    private let port: any TimelinePort
    private let activity: BotActivityCoordinator
    private let botSenders: @Sendable () -> Set<String>
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var states: [BotTaskEntry.Key: State] = [:]
    private var broadcaster = SnapshotBroadcaster<[BotTaskEntry.Key: State]>()

    public init(
        port: any TimelinePort, activity: BotActivityCoordinator, botSenders: @escaping @Sendable () -> Set<String>,
        timeout: Duration = defaultTimeout, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.activity = activity
        self.botSenders = botSenders
        self.timeout = timeout
        self.sleep = sleep
    }

    /// The states of ticks in progress or ended unsuccessfully, then every change. A key is absent when idle or confirmed.
    public func stateChanges() -> AsyncStream<[BotTaskEntry.Key: State]> { broadcaster.subscribe(current: states) }

    /// Ticks `entry` and returns when the bot confirmed, the timeout passed or sending failed. Ignored unless it is an open task
    /// with a source message (a reminder or a task seen only in a list has nothing to react to) and not already pending.
    public func tick(_ entry: BotTaskEntry) async {
        guard entry.key.kind == .todo, entry.status == .open, let source = entry.sourceEventID, states[entry.key] != .pending else { return }
        set(entry.key, .pending)
        let room = entry.key.room
        let coordinator = TimelineCoordinator(port: port, room: room)
        await coordinator.open()
        guard await waitUntilLive(coordinator) else {
            set(entry.key, .failed)
            await coordinator.close()
            return
        }
        do {
            try await coordinator.addReaction(on: source, key: "👍")
        } catch {
            set(entry.key, .failed)
            await coordinator.close()
            return
        }
        let confirmed = await waitForConfirmation(of: entry.key, in: coordinator)
        await coordinator.close()
        set(entry.key, confirmed ? nil : .noResponse)
    }

    // MARK: Private

    private func set(_ key: BotTaskEntry.Key, _ state: State?) {
        states[key] = state
        broadcaster.publish(states)
    }

    private func waitUntilLive(_ coordinator: TimelineCoordinator) async -> Bool {
        for await status in await coordinator.statuses() {
            switch status {
            case .live: return true
            case .failed: return false
            case .idle, .opening: continue
            }
        }
        return false
    }

    /// Feeds every snapshot of the room to the index and stops when the entry is completed, or after `timeout`.
    private func waitForConfirmation(of key: BotTaskEntry.Key, in coordinator: TimelineCoordinator) async -> Bool {
        let activity = activity, senders = botSenders
        let watcher = Task<Bool, Never> {
            for await status in await coordinator.statuses() {
                guard case .live(let snapshot) = status else { continue }
                await activity.observe(room: key.room, items: snapshot.items, botSenders: senders())
                if await activity.snapshot().entries.first(where: { $0.key == key })?.status == .completed { return true }
            }
            return false
        }
        let sleep = sleep, timeout = timeout
        let timer = Task {
            try? await sleep(timeout)
            watcher.cancel()
        }
        let confirmed = await watcher.value
        timer.cancel()
        return confirmed
    }
}
