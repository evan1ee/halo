import Foundation

/// A chat Siri, Shortcuts and Spotlight may offer by name (M16 App Intents). Only the room ID and its display name: never
/// messages, previews or avatars. Derived from the room list and rebuildable (AGENTS §4.1).
public struct ChatShortcut: Sendable, Equatable, Codable, Identifiable {
    /// The Matrix room ID.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Where the offered chats live for the system: a file in the App Group (read by intents) and the Spotlight index.
/// Implemented in `HaloPlatform`; faked in `HaloTestSupport`.
public protocol ChatShortcutPort: Sendable {
    /// What was last stored; empty when nothing was.
    func load() -> [ChatShortcut]
    /// Makes `shortcuts` the whole set, removing chats that are no longer in it from the system.
    func replace(with shortcuts: [ChatShortcut]) async
    /// Removes every chat from the system (switched off, or signed out).
    func clear() async
}
