import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Testing
@testable import FeatureStickers

private actor FakeKlipy: KlipyPort {
    var shares: [String] = []
    var calls: [String] = []

    static func item(_ slug: String) -> KlipyItem {
        let rendition = KlipyRendition(url: "https://static.klipy.com/\(slug).gif", width: 1, height: 1, size: 1)
        return KlipyItem(slug: slug, kind: .gifs, title: slug, preview: rendition, shared: rendition)
    }

    func trending(_ kind: KlipyKind, page: Int) async throws(HaloError) -> KlipyPage {
        calls.append("trending \(page)")
        // Page 2 repeats an item of page 1: shown once.
        return page == 1
            ? KlipyPage(items: (1...6).map { Self.item("t\($0)") }, page: 1, hasNext: true)
            : KlipyPage(items: [Self.item("t6"), Self.item("t7")], page: 2, hasNext: false)
    }

    func search(_ kind: KlipyKind, query: String, page: Int) async throws(HaloError) -> KlipyPage {
        calls.append("search \(query)")
        if query == "fail" { throw .network(retryable: true) }
        return KlipyPage(items: [Self.item(query)], page: 1, hasNext: false)
    }

    func registerShare(_ item: KlipyItem, query: String?) async throws(HaloError) { shares.append("\(item.slug)|\(query ?? "-")") }
    func media(_ url: URL) async throws(HaloError) -> Data { Data() }
}

@MainActor
@Suite("KlipyPanelModel")
struct KlipyPanelModelTests {
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200_000 where !condition() { await Task.yield() }
    }

    @Test("opens on trending in KLIPY's order and pages without repeating items")
    func trendingAndPaging() async throws {
        let port = FakeKlipy()
        let model = KlipyPanelModel(kind: .gifs, catalog: KlipyCatalog(port: port), debounce: .zero) { _ throws(HaloError) in }
        await model.start()
        #expect(model.phase == .ready && model.items.map(\.slug) == ["t1", "t2", "t3", "t4", "t5", "t6"] && model.hasMore)
        await model.loadMoreIfNeeded(after: try #require(model.items.last))
        #expect(model.items.map(\.slug).suffix(2) == ["t6", "t7"] && model.items.count == 7 && !model.hasMore)
    }

    @Test("typing searches; a failure shows as failed; clearing goes back to trending")
    func search() async {
        let port = FakeKlipy()
        let model = KlipyPanelModel(kind: .gifs, catalog: KlipyCatalog(port: port), debounce: .zero) { _ throws(HaloError) in }
        await model.start()
        model.query = "cats"
        await settle { model.items.first?.slug == "cats" }
        #expect(model.items.map(\.slug) == ["cats"] && model.favourites.isEmpty)
        model.query = "fail"
        await settle { model.phase == .failed }
        #expect(model.phase == .failed && model.items.isEmpty)
        model.query = ""
        await settle { model.items.count == 6 }
        #expect(model.phase == .ready)
    }

    @Test("tap sends, then records it as recent and tells KLIPY with the search text")
    func tapSends() async {
        let port = FakeKlipy()
        let catalog = KlipyCatalog(port: port)
        var sent: [String] = []
        let model = KlipyPanelModel(kind: .gifs, catalog: catalog, debounce: .zero) { item throws(HaloError) in sent.append(item.shared.url) }
        await model.start()
        model.query = "cats"
        await settle { model.items.first?.slug == "cats" }
        #expect(await model.tap(FakeKlipy.item("cats")))
        #expect(sent == ["https://static.klipy.com/cats.gif"])
        for _ in 0..<200_000 { if await !port.shares.isEmpty { break }; await Task.yield() }
        #expect(await port.shares == ["cats|cats"])
        #expect(await catalog.currentShelf().recents.map(\.slug) == ["cats"])
    }

    @Test("a failed send explains and records nothing")
    func failedSend() async {
        let port = FakeKlipy()
        let catalog = KlipyCatalog(port: port)
        let model = KlipyPanelModel(kind: .gifs, catalog: catalog, debounce: .zero) { _ throws(HaloError) in throw .network(retryable: true) }
        #expect(await !model.tap(FakeKlipy.item("x")))
        #expect(model.sendError == "Can't reach the server. It wasn't sent.")
        let recents = await catalog.currentShelf().recents
        let shares = await port.shares
        #expect(recents.isEmpty && shares.isEmpty)
    }

    @Test("favourites follow the shared shelf and hide while searching")
    func favourites() async {
        let catalog = KlipyCatalog(port: FakeKlipy())
        let model = KlipyPanelModel(kind: .gifs, catalog: catalog, debounce: .zero) { _ throws(HaloError) in }
        await model.start()
        await model.toggleFavourite(FakeKlipy.item("fav"))
        await settle { !model.favourites.isEmpty }
        #expect(model.favourites.map(\.slug) == ["fav"] && model.isFavourite(FakeKlipy.item("fav")))
        model.query = "x"
        #expect(model.favourites.isEmpty)
    }
}
