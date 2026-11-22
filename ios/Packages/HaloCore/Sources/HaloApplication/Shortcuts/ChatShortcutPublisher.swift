import Observation
import Foundation
import HaloDomain
import HaloFoundation

/// Offers the joined chats to Siri, Shortcuts and Spotlight while the person has switched that on (M16, D88). Off means
/// nothing is stored or indexed, and switching off or signing out removes what was. It follows the room list; the list stays
/// the source of truth.
public actor ChatShortcutPublisher {
    /// Enough for Siri and Spotlight to be useful; more would only index old rooms.
    public static let limit = 100

    private let port: any ChatShortcutPort
    private var last: [ChatShortcut]?

    public init(port: any ChatShortcutPort) { self.port = port }

    /// Applies the room list: stores the named, joined chats (favourites first, then list order) when `enabled`, else clears.
    public func update(rooms: [RoomSummary], enabled: Bool) async {
        guard enabled else {
            await clear()
            return
        }
        var seen: Set<String> = []
        let joined = rooms.filter { $0.membership == .joined }
        let ordered = joined.filter(\.isFavourite) + joined.filter { !$0.isFavourite }
        let shortcuts = ordered.compactMap { room -> ChatShortcut? in
            let name = room.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, seen.insert(room.id.rawValue).inserted else { return nil }
            return ChatShortcut(id: room.id.rawValue, name: name)
        }.prefix(Self.limit)
        let next = Array(shortcuts)
        guard next != last else { return }
        last = next
        await port.replace(with: next)
    }

    /// Removes every chat from the system.
    public func clear() async {
        guard last != [] else { return }
        last = []
        await port.clear()
    }
}

/// A request from outside the app (Siri, Shortcuts, a Spotlight result) to open a chat. The app's root view consumes it; one
/// made before the room list exists waits.
@MainActor @Observable
public final class OpenChatRequest {
    public var pending: RoomID?
    public init() {}

    public func request(_ room: RoomID) { pending = room }
}
