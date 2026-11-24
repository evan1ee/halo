import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloApplication

private actor FakeKlipy: KlipyPort {
    var calls: [String] = []
    var shares: [(String, String?)] = []
    var mediaLoads = 0
    var mediaSize = 10

    func setMediaSize(_ size: Int) { mediaSize = size }

    static func item(_ slug: String, _ kind: KlipyKind = .gifs) -> KlipyItem {
        let rendition = KlipyRendition(url: "https://static.klipy.com/\(slug).gif", width: 2, height: 1, size: 1)
        return KlipyItem(slug: slug, kind: kind, title: slug, preview: rendition, shared: rendition)
    }

    func trending(_ kind: KlipyKind, page: Int) async throws(HaloError) -> KlipyPage {
        calls.append("trending \(kind.rawValue) \(page)")
        return KlipyPage(items: [Self.item("t\(page)", kind)], page: page, hasNext: page < 2)
    }

    func search(_ kind: KlipyKind, query: String, page: Int) async throws(HaloError) -> KlipyPage {
        calls.append("search \(kind.rawValue) \(query) \(page)")
        return KlipyPage(items: [Self.item(query, kind)], page: page, hasNext: false)
    }

    func registerShare(_ item: KlipyItem, query: String?) async throws(HaloError) {
        shares.append((item.slug, query))
        throw .network(retryable: true)  // best effort: must not matter
    }

    func media(_ url: URL) async throws(HaloError) -> Data {
        mediaLoads += 1
        return Data(repeating: 1, count: mediaSize)
    }
}

private actor MemoryShelf: KlipyShelfPort {
    var stored: KlipyShelf
    init(_ shelf: KlipyShelf = KlipyShelf()) { stored = shelf }
    func load() async -> KlipyShelf { stored }
    func save(_ shelf: KlipyShelf) async { stored = shelf }
}

@Suite("KlipyCatalog")
struct KlipyCatalogTests {
    @Test("without a key the catalog is unavailable")
    func unavailable() async {
        let catalog = KlipyCatalog(port: nil)
        #expect(!catalog.isAvailable)
        await #expect(throws: HaloError.unsupported("KLIPY_UNAVAILABLE")) { try await catalog.page(.gifs, query: "", page: 1) }
    }

    @Test("a blank query asks for trending; text searches, trimmed")
    func routing() async throws {
        let port = FakeKlipy()
        let catalog = KlipyCatalog(port: port)
        let trending = try await catalog.page(.stickers, query: "  ", page: 2)
        #expect(trending.items.first?.slug == "t2" && !trending.hasNext)
        _ = try await catalog.page(.gifs, query: " cats ", page: 1)
        #expect(await port.calls == ["trending stickers 2", "search gifs cats 1"])
    }

    @Test("sending records a recent, saves the shelf and sends the share trigger with the search text")
    func send() async {
        let port = FakeKlipy()
        let store = MemoryShelf()
        let catalog = KlipyCatalog(port: port)
        await catalog.attach(store)
        await catalog.didSend(FakeKlipy.item("a"), query: " cats ")
        await catalog.didSend(FakeKlipy.item("b"), query: "")
        #expect(await catalog.currentShelf().recents.map(\.slug) == ["b", "a"])
        #expect(await store.stored.recents.count == 2)
        let shares = await port.shares
        #expect(shares.map(\.0) == ["a", "b"] && shares[0].1 == "cats" && shares[1].1 == nil)
    }

    @Test("favourites persist; attach loads the account's shelf and sign-out forgets it (D69)")
    func shelfLifecycle() async {
        var saved = KlipyShelf()
        saved.toggleFavourite(FakeKlipy.item("fav"))
        let catalog = KlipyCatalog(port: FakeKlipy())
        await catalog.attach(MemoryShelf(saved))
        #expect(await catalog.currentShelf().favourites.map(\.slug) == ["fav"])
        await catalog.toggleFavourite(FakeKlipy.item("fav"))
        #expect(await catalog.currentShelf().favourites.isEmpty)
        await catalog.toggleFavourite(FakeKlipy.item("x"))
        await catalog.reset()
        #expect(await catalog.currentShelf() == KlipyShelf())
    }

    @Test("media is loaded once and then served from memory; the cache stays within its budget")
    func mediaCache() async throws {
        let port = FakeKlipy()
        let catalog = KlipyCatalog(port: port)
        let url = try #require(URL(string: "https://static.klipy.com/a.gif"))
        _ = try await catalog.media(url)
        _ = try await catalog.media(url)
        #expect(await port.mediaLoads == 1)

        await port.setMediaSize(KlipyCatalog.mediaCacheBytes / 5)
        for index in 0..<8 {
            _ = try await catalog.media(try #require(URL(string: "https://static.klipy.com/\(index).gif")))
        }
        #expect(await catalog.cachedBytes <= KlipyCatalog.mediaCacheBytes)
    }
}
