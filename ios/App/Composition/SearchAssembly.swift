import FeatureSearch
import FeatureSettings
import FeatureTimeline
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPersistence
import HaloPlatform

extension MessageSearchEngine {
    /// iOS's side of message search: the shared device conditions and the background processing task (wiring only).
    static func environment(conditions: DeviceConditionsBox, log: HaloLog) -> Environment {
        Environment(
            device: { conditions.searchDevice },
            scheduleProcessing: { SearchProcessingTask.schedule(log: log) },
            removeAllIndexes: {
                SearchIndexStore.removeAll(in: HaloShared.searchDirectory())
                SearchProcessingTask.cancel()
            })
    }

    /// Settings → Message search.
    func settingsStatus() -> SearchIndexSettingsActions.Status? {
        guard isAttached else { return nil }
        let chats = "\(status.completeRooms) of \(status.totalRooms) chats"
        let progress: String = switch status.phase {
        case .done: status.isComplete ? "Complete" : chats
        case .indexing: "Reading · \(chats)"
        case .paused(.busy): "Reading · \(chats)"
        case .paused: "Paused · \(chats)"
        case .unavailable: "Not available now"
        case .stopped: "Starting"
        }
        return .init(progress: progress, size: StorageSize(name: "Search index (\(status.statistics.messages.formatted()) messages)", bytes: status.statistics.bytes))
    }
}

extension AppRoot {
    /// Message search view model for the `.searchable` room list (D85).
    func makeMessageSearch() -> MessageSearchViewModel {
        let media = media
        return MessageSearchViewModel(
            coordinator: search.coordinator,
            roomName: { [roomList] room in roomList.roomName(for: room) ?? "Room" },
            roomAvatar: { [roomList] room in roomList.roomAvatar(for: room) },
            thumbnail: { ref, size in
                try? await media.thumbnail(ref, width: size, height: size)  // best-effort: missing or offline thumbnails keep their placeholder
            },
            statuses: { [search] in await search.statuses() },
            needsVerification: { [recovery] in recovery.needsRecovery })
    }

    /// In-room message search view model with previous/next stepping and M20-1 focused jumps (ROADMAP M20-11).
    func makeRoomSearch(room: RoomID, timeline: TimelineViewModel) -> RoomSearchViewModel {
        let searchEngine = search
        let coordinator = searchEngine.makeRoomSearchCoordinator()
        return RoomSearchViewModel(
            room: room,
            coordinator: coordinator,
            statuses: { await searchEngine.statuses() },
            roomCoverage: { await searchEngine.roomCoverage(for: room) },
            jumpToEvent: { [weak timeline] event in
                guard let timeline else { return false }
                return await timeline.jump(toEvent: event)
            }
        )
    }
}
