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
                if !local.isEmpty { try? await botAllowlistPort.save(BotAllowlist(bots: local)) }
            }
        } catch {
            // Keep the local cache until the next launch or edit.
        }
    }

    /// Syncs an updated bot allowlist to `one.mbm.halo.bot_allowlist` account data and refreshes room previews.
    func saveBotSenders(_ rawIDs: [String]) async -> Bool {
        preferences.botSenders = rawIDs
        let allowlist = BotAllowlist(bots: rawIDs.compactMap { try? UserID($0) })
        await roomList.refresh()
        do { try await botAllowlistPort.save(allowlist); return true } catch { return false }
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
