import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// The sticker panel of one room's composer (docs/features/STICKERS.md FR-3…FR-6).
@MainActor @Observable
public final class StickerPanelViewModel {
    public private(set) var snapshot = StickerLibrary.Snapshot()
    /// Search results for `query`; empty while the query is blank.
    public private(set) var results: [Sticker] = []
    public private(set) var sendError: String?
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            searchGeneration += 1
            let generation = searchGeneration
            let text = query
            Task {
                let found = await library.search(text)
                if generation == searchGeneration { results = found }
            }
        }
    }

    private let library: StickerLibrary
    private let media: MediaLoader?
    private let room: RoomID?
    private let send: @MainActor (Sticker) async throws(HaloError) -> Void
    private var observation: Task<Void, Never>?
    private var searchGeneration = 0
    private let makeNewPack: (@MainActor (@escaping @MainActor () async -> Void) -> NewPackViewModel)?

    /// - Parameter send: sends the sticker into the room the panel belongs to.
    public init(library: StickerLibrary, media: MediaLoader? = nil, room: RoomID?,
        newPack: (@MainActor (@escaping @MainActor () async -> Void) -> NewPackViewModel)? = nil,
        send: @escaping @MainActor (Sticker) async throws(HaloError) -> Void
    ) {
        self.makeNewPack = newPack
        self.library = library
        self.media = media
        self.room = room
        self.send = send
    }

    isolated deinit { observation?.cancel() }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Follows the library and loads it. Call when the panel appears.
    public func start() async {
        guard observation == nil else { return }
        let snapshots = await library.snapshots()
        observation = Task { [weak self] in
            for await snapshot in snapshots { self?.snapshot = snapshot }
        }
        await library.load(currentRoom: room)
    }

    /// Call when the panel closes: sends a pending recents write.
    public func stop() async {
        observation?.cancel()
        observation = nil
        await library.flush()
    }

    /// Tap: sends the sticker at once (AC-S1) and counts it as recent. A failure keeps the panel open and says so.
    public func tap(_ sticker: Sticker) async {
        sendError = nil
        do {
            try await send(sticker)
            await library.recordSent(sticker)
        } catch {
            sendError = error == .network(retryable: true) ? "Can't reach the server. The sticker wasn't sent." : "The sticker couldn't be sent."
        }
    }

    public func isFavourite(_ sticker: Sticker) -> Bool { snapshot.favourites.contains { $0.ref == sticker.ref } }

    public func toggleFavourite(_ sticker: Sticker) async { await library.toggleFavourite(sticker.ref) }

    /// Removes a favourite whose pack or image is gone.
    public func removeUnavailable(_ ref: StickerRef) async { await library.toggleFavourite(ref) }

    public func thumbnail(for sticker: Sticker) async -> Data? {
        guard let media, let image = sticker.image else { return nil }
        return try? await media.thumbnail(image, width: 256, height: 256)
    }

    /// The full image for the long-press preview (it may be animated); the thumbnail when it can't be loaded.
    public func previewContent(for sticker: Sticker) async -> Data? {
        guard let media, let image = sticker.image else { return nil }
        if let full = try? await media.content(image) { return full }
        return try? await media.thumbnail(image, width: 256, height: 256)
    }

    /// `true` when the panel can create packs.
    public var canCreatePack: Bool { makeNewPack != nil }

    /// The creation screen's model; the panel reloads when a pack was created.
    public func beginNewPack() -> NewPackViewModel? {
        makeNewPack?({ [library, room] in await library.load(currentRoom: room) })
    }

    /// Why the panel has nothing to show, or `nil` when it has something.
    public var emptyMessage: String? {
        if isSearching { return results.isEmpty ? "No stickers match “\(query)”." : nil }
        switch snapshot.phase {
        case .unloaded, .loading: return snapshot.packs.isEmpty ? "Loading stickers…" : nil
        case .failed: return "Stickers couldn't be loaded."
        case .ready, .partial: return snapshot.packs.isEmpty ? "No sticker packs yet." : nil
        }
    }

    /// `true` when some pack sources couldn't be read, so the list may be incomplete.
    public var isIncomplete: Bool { snapshot.phase == .partial }
}
