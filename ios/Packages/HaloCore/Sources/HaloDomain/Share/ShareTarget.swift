import Foundation
import HaloFoundation

/// A chat the share extension offers as a destination (M16, D92).
public struct ShareTarget: Sendable, Equatable, Identifiable {
    public let id: RoomID
    public let name: String
    public let isDirect: Bool
    public let isFavourite: Bool
    /// When the newest event arrived; `nil` for a room without one.
    public let lastActivity: Date?

    public init(id: RoomID, name: String, isDirect: Bool, isFavourite: Bool, lastActivity: Date?) {
        self.id = id
        self.name = name
        self.isDirect = isDirect
        self.isFavourite = isFavourite
        self.lastActivity = lastActivity
    }

    /// Favourites first, then the most recent chat, then by name.
    public static func ordered(_ targets: [ShareTarget]) -> [ShareTarget] {
        targets.sorted { a, b in
            if a.isFavourite != b.isFavourite { return a.isFavourite }
            switch (a.lastActivity, b.lastActivity) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

/// The joined chats a share can go to, read from the SDK's local store without starting sync (the extension never syncs,
/// AGENTS §17). Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol ShareTargetPort: Sendable {
    func targets() async throws(HaloError) -> [ShareTarget]
}
