import Foundation
import HaloDomain
import HaloFoundation

/// Keeps the unsent text of each room (MESSAGING FR-5). The text lives in memory at once and is written to the store as
/// soon as one is attached (the database is per account, so it only exists after sign-in). Storage errors never block typing.
public actor DraftCoordinator {
    private var store: (any DraftPort)?
    private var cache: [RoomID: String] = [:]

    public init(store: (any DraftPort)? = nil) { self.store = store }

    /// Attaches the store once the account is known; drafts typed before that are written to it.
    public func attach(_ store: any DraftPort) async {
        self.store = store
        for (room, text) in cache { try? await store.save(text, for: room) }
    }

    /// The draft of `room`: what was typed in this run, else what the store holds.
    public func draft(for room: RoomID) async -> String {
        if let text = cache[room] { return text }
        guard let store, let text = try? await store.draft(for: room) else { return "" }
        cache[room] = text
        return text
    }

    /// Remembers `text` as the draft of `room`; blank text removes it. Writes are best effort.
    public func save(_ text: String, for room: RoomID) async {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // An empty entry (not removal) so a read racing the store write can't bring the old text back.
        cache[room] = blank ? "" : text
        try? await store?.save(text, for: room)
    }
}
