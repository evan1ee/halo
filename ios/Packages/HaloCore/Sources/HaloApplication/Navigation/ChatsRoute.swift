import Foundation
import HaloFoundation

/// Typed routes pushed onto Halo's single `NavigationStack` (`docs/design/NAVIGATION.md` §1–2, D85, ADR-0022).
///
/// The room list ("Chats") is the only root; every other destination is pushed via `ChatsRoute` or presented
/// as a short-task sheet.
public enum ChatsRoute: Hashable, Codable, Sendable {
    case room(RoomID, focus: EventID? = nil)
    case thread(RoomID, rootEvent: EventID)
    case settings
    case stickerLibrary
    case activity
    case globalMediaGallery
}

/// Pure navigation state machine for Halo's single `NavigationStack` (`docs/design/NAVIGATION.md` §2–4, D85).
///
/// Notification taps, `matrix:` / `matrix.to` links, search hits, Activity jumps, and state restoration all
/// route through `ChatsRouter` so pushes are never duplicated and left rooms are pruned on relaunch.
public struct ChatsRouter: Sendable, Equatable {
    public var path: [ChatsRoute]

    public init(path: [ChatsRoute] = []) {
        self.path = path
    }

    /// Opens `room` (optionally focusing `focus`). Avoids pushing a duplicate room when it is already on top;
    /// if the same room is already on top with a different `focus`, replaces the top entry so the jump runs.
    public mutating func openRoom(_ room: RoomID, focus: EventID? = nil) {
        if case .room(let current, let currentFocus) = path.last, current == room {
            if focus != nil && focus != currentFocus {
                path[path.count - 1] = .room(room, focus: focus)
            }
            return
        }
        path.append(.room(room, focus: focus))
    }

    /// Opens a thread rooted at `rootEvent` in `room`, deduplicating if already on top.
    public mutating func openThread(room: RoomID, rootEvent: EventID) {
        let target = ChatsRoute.thread(room, rootEvent: rootEvent)
        guard path.last != target else { return }
        path.append(target)
    }

    /// Pushes a destination onto the stack if it is not already the top route.
    public mutating func push(_ route: ChatsRoute) {
        switch route {
        case .room(let room, let focus):
            openRoom(room, focus: focus)
        case .thread(let room, let rootEvent):
            openThread(room: room, rootEvent: rootEvent)
        case .settings, .stickerLibrary, .activity, .globalMediaGallery:
            guard path.last != route else { return }
            path.append(route)
        }
    }

    /// Clears the navigation stack back to the Chats root.
    public mutating func popToRoot() {
        path.removeAll()
    }

    /// Removes `.room` and `.thread` entries whose room is no longer joined (NAVIGATION §4 state restoration).
    /// Non-room destinations (Settings, Stickers, Activity, Media Gallery) are preserved.
    public mutating func pruneInvalidRooms(joinedRoomIDs: Set<RoomID>) {
        path.removeAll { route in
            switch route {
            case .room(let room, _), .thread(let room, _):
                return !joinedRoomIDs.contains(room)
            case .settings, .stickerLibrary, .activity, .globalMediaGallery:
                return false
            }
        }
    }

    /// Encodes `path` for `@SceneStorage` persistence (NAVIGATION §4).
    public func encodePath() -> Data? {
        try? JSONEncoder().encode(path)
    }

    /// Restores `path` from `@SceneStorage` data; invalid or corrupt data leaves `path` unchanged.
    public mutating func restorePath(from data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode([ChatsRoute].self, from: data) else { return }
        path = decoded
    }
}
