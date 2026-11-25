import FeatureBotActivity
import HaloApplication
import HaloDomain
import HaloFoundation

/// Bot allowlist synchronization and Activity scanning (ADR-0022 step 2).
extension AppRoot {
    /// Loads `one.mbm.halo.bot_allowlist` from account data into `PreferencesStore`; if the server has none yet
    /// and this device already had entries, seeds the server once.
    func syncBotAllowlist() async {
        do {
            if let remote = try await botAllowlistPort.load() {
                preferences.botSenders = remote.bots.map(\.rawValue)
                await roomList.refresh()
            } else {
                let local = preferences.botSenders.compactMap { try? UserID($0) }
                if !local.isEmpty { _ = try? await botAllowlistPort.change(from: BotAllowlist(), to: BotAllowlist(bots: local)) }
            }
        } catch {
            // Keep the local cache until the next launch or edit.
        }
    }

    /// Applies an edit of the bot allowlist to `one.mbm.halo.bot_allowlist` account data and refreshes room previews. Returns the
    /// account's list, or `nil` when it couldn't be synced (the edit then stays on this device).
    func saveBotSenders(from old: [String], to new: [String]) async -> [String]? {
        func list(_ rawIDs: [String]) -> BotAllowlist { BotAllowlist(bots: rawIDs.compactMap { try? UserID($0) }) }
        preferences.botSenders = new
        await roomList.refresh()
        guard let merged = try? await botAllowlistPort.change(from: list(old), to: list(new)).bots.map(\.rawValue) else { return nil }
        if merged != new, preferences.botSenders == new {
            preferences.botSenders = merged
            await roomList.refresh()
        }
        return merged
    }

    /// Reads rooms whose newest message is from an allowlisted bot and that changed since the last scan.
    func scanBotRooms() async {
        let senders = Set(preferences.botSenders)
        guard !senders.isEmpty else { return }
        let hints = await roomCoordinator.rooms.filter { $0.membership == .joined }.map {
            BotActivityCoordinator.RoomHint(room: $0.id, latestSender: $0.preview?.senderID?.rawValue, latestAt: $0.latestEvent?.timestamp)
        }
        await botActivity.scan(hints, botSenders: senders)
    }

    /// The Activity screen's model: names of rooms from the room list.
    func makeBotActivity() -> BotActivityViewModel {
        BotActivityViewModel(
            coordinator: botActivity, actions: botActions,
            roomName: { [roomList] room in
                guard case .loaded(_, let rows) = roomList.content else { return nil }
                return rows.first { $0.id == room }?.name
            }
        )
    }
}
