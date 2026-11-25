import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// One KLIPY grid in the composer's panels: GIFs, or KLIPY stickers (docs/features/COMPOSER_PANELS.md §6, D98).
///
/// Shows trending items until the user types, then search results (debounced), page by page in KLIPY's order. Favourites
/// and Recent come from the account's `KlipyShelf`. Tapping sends the item's KLIPY URL as a message through the room's
/// timeline (end-to-end encrypted like any message) and records the share with KLIPY.
@MainActor @Observable
public final class KlipyPanelModel {
    public enum Phase: Equatable { case idle, loading, ready, failed }

    public let kind: KlipyKind
    public private(set) var items: [KlipyItem] = []
    public private(set) var phase = Phase.idle
    public private(set) var hasMore = false
    public private(set) var shelf = KlipyShelf()
    public private(set) var sendError: String?
    public private(set) var isSending = false
    public var query = "" {
        didSet {
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            scheduleReload(debounce: true)
        }
    }

    private let catalog: KlipyCatalog
    private let send: @MainActor (KlipyItem) async throws(HaloError) -> Void
    private let debounce: Duration
    private var page = 0
    private var generation = 0
    private var reload: Task<Void, Never>?
    private var loadingMore = false
    private var shelfObservation: Task<Void, Never>?

    /// - Parameter send: sends the item's URL into the room (the timeline's view model).
    public init(
        kind: KlipyKind, catalog: KlipyCatalog, debounce: Duration = .milliseconds(300),
        send: @escaping @MainActor (KlipyItem) async throws(HaloError) -> Void
    ) {
        self.kind = kind
        self.catalog = catalog
        self.debounce = debounce
        self.send = send
    }

    isolated deinit {
        reload?.cancel()
        shelfObservation?.cancel()
    }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var favourites: [KlipyItem] { isSearching ? [] : shelf.favourites(kind) }
    public var recents: [KlipyItem] { isSearching ? [] : shelf.recents(kind) }
    public func isFavourite(_ item: KlipyItem) -> Bool { shelf.isFavourite(item) }

    /// Call when the panel appears: follows the shelf and loads the first page (once).
    public func start() async {
        if shelfObservation == nil {
            let stream = await catalog.shelfSnapshots()
            shelfObservation = Task { [weak self] in
                for await shelf in stream { self?.shelf = shelf }
            }
        }
        if phase == .idle { scheduleReload(debounce: false) }
        await reload?.value
    }

    public func retry() async {
        scheduleReload(debounce: false)
        await reload?.value
    }

    /// Loads the next page when the user nears the end of the grid.
    public func loadMoreIfNeeded(after item: KlipyItem) async {
        guard hasMore, !loadingMore, phase == .ready, items.suffix(6).contains(where: { $0.id == item.id }) else { return }
        loadingMore = true
        defer { loadingMore = false }
        let started = generation
        do {
            let next = try await catalog.page(kind, query: query, page: page + 1)
            guard started == generation else { return }
            page = next.page
            hasMore = next.hasNext && !next.items.isEmpty
            // KLIPY's order is kept; an item repeated on a later page is shown once.
            let known = Set(items.map(\.id))
            items.append(contentsOf: next.items.filter { !known.contains($0.id) })
        } catch {
            guard started == generation else { return }
            hasMore = false
        }
    }

    /// Sends the item; the panel stays open (like the keyboard). Returns `true` when sent.
    @discardableResult
    public func tap(_ item: KlipyItem) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            try await send(item)
        } catch {
            sendError = error == .network(retryable: true)
                ? "Can't reach the server. It wasn't sent."
                : kind == .gifs ? "The GIF couldn't be sent." : "The sticker couldn't be sent."
            return false
        }
        let search = isSearching ? query : nil
        let catalog = catalog
        Task { await catalog.didSend(item, query: search) }
        return true
    }

    public func toggleFavourite(_ item: KlipyItem) async { await catalog.toggleFavourite(item) }
    public func dismissSendError() { sendError = nil }

    /// A KLIPY file for a grid cell or the preview.
    public func media(_ rendition: KlipyRendition) async -> Data? {
        guard let url = URL(string: rendition.url) else { return nil }
        return try? await catalog.media(url)  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }

    /// The loader a grid cell hands to its image view.
    public nonisolated func loader(for rendition: KlipyRendition) -> @Sendable () async -> Data? {
        let catalog = catalog
        return {
            guard let url = URL(string: rendition.url) else { return nil }
            return try? await catalog.media(url)  // best-effort: a picture that can't load shows its placeholder; nothing changes
        }
    }

    private func scheduleReload(debounce shouldWait: Bool) {
        reload?.cancel()
        generation += 1
        let started = generation
        let text = query
        let wait = debounce
        reload = Task { [weak self] in
            if shouldWait { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            await self.load(text, generation: started)
        }
    }

    private func load(_ text: String, generation started: Int) async {
        phase = .loading
        do {
            let first = try await catalog.page(kind, query: text, page: 1)
            guard started == generation else { return }
            items = first.items
            page = first.page
            hasMore = first.hasNext && !first.items.isEmpty
            phase = .ready
        } catch {
            guard started == generation, error != .cancelled else { return }
            items = []
            hasMore = false
            phase = .failed
        }
    }
}
