import Foundation
import HaloDomain
import HaloFoundation

/// KLIPY GIFs and stickers for the composer panels and the timeline (docs/features/COMPOSER_PANELS.md §6, D98).
///
/// Results pass through in KLIPY's order (its integration rules). Favourites and recents are the signed-in account's
/// `KlipyShelf`, attached on sign-in and dropped on sign-out (D69). Media is held only in a bounded memory cache.
public actor KlipyCatalog {
    public static let mediaCacheBytes = 48 * 1024 * 1024

    private let port: (any KlipyPort)?
    private var shelfStore: (any KlipyShelfPort)?
    private var shelf = KlipyShelf()
    private var generation = 0
    private var broadcaster = SnapshotBroadcaster<KlipyShelf>()
    private var cache: [URL: Data] = [:]
    private var cacheOrder: [URL] = []
    private var cacheBytes = 0
    private var inFlight: [URL: Task<Data, any Error>] = [:]

    /// - Parameter port: `nil` when the build has no KLIPY key; the panels then hide KLIPY.
    public init(port: (any KlipyPort)?) { self.port = port }

    public nonisolated var isAvailable: Bool { port != nil }

    // MARK: Shelf

    /// Uses the account's shelf store from now on (sign-in), or none (sign-out).
    public func attach(_ store: (any KlipyShelfPort)?) async {
        generation += 1
        let started = generation
        shelfStore = store
        shelf = KlipyShelf()
        publish()
        guard let store else { return }
        let loaded = await store.load()
        guard started == generation else { return }
        shelf = loaded
        publish()
    }

    public func reset() async {
        await attach(nil)
        cache = [:]
        cacheOrder = []
        cacheBytes = 0
    }

    public func shelfSnapshots() -> AsyncStream<KlipyShelf> { broadcaster.subscribe(current: shelf) }
    public func currentShelf() -> KlipyShelf { shelf }

    public func toggleFavourite(_ item: KlipyItem) async {
        shelf.toggleFavourite(item)
        publish()
        await shelfStore?.save(shelf)
    }

    /// Call once the item's message was sent: moves it to the front of Recent and tells KLIPY (its share trigger).
    /// The trigger is best effort; a failure doesn't touch the sent message.
    public func didSend(_ item: KlipyItem, query: String?) async {
        shelf.recordSent(item)
        publish()
        await shelfStore?.save(shelf)
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await port?.registerShare(item, query: trimmed?.isEmpty == false ? trimmed : nil)  // best-effort: diagnostics, cache or best-effort sync; the next update repeats it
    }

    // MARK: Results

    /// Trending items when `query` is blank, else search results; one page.
    public func page(_ kind: KlipyKind, query: String, page: Int) async throws(HaloError) -> KlipyPage {
        guard let port else { throw .unsupported("KLIPY_UNAVAILABLE") }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? try await port.trending(kind, page: page)
            : try await port.search(kind, query: trimmed, page: page)
    }

    // MARK: Media

    /// A KLIPY media file, from memory when it was loaded recently. Concurrent requests for one URL share a load.
    public func media(_ url: URL) async throws(HaloError) -> Data {
        if let hit = cache[url] {
            touch(url)
            return hit
        }
        guard let port else { throw .unsupported("KLIPY_UNAVAILABLE") }
        let task = inFlight[url] ?? Task { try await port.media(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data: Data
        do { data = try await task.value } catch let error as HaloError { throw error } catch { throw .network(retryable: true) }
        store(data, for: url)
        return data
    }

    private func touch(_ url: URL) {
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
    }

    private func store(_ data: Data, for url: URL) {
        guard data.count <= Self.mediaCacheBytes / 4 else { return }
        if let old = cache[url] { cacheBytes -= old.count }
        cache[url] = data
        cacheBytes += data.count
        touch(url)
        while cacheBytes > Self.mediaCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cacheBytes -= cache.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    /// Bytes held in memory (for tests).
    var cachedBytes: Int { cacheBytes }

    private func publish() { broadcaster.publish(shelf) }
}
