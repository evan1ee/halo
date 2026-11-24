import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("KLIPY models")
struct KlipyModelsTests {
    /// Shape of a real KLIPY sticker/GIF response (trimmed), plus an ad-like entry without files.
    private let response = Data("""
        {"result": true, "data": {"data": [
          {"id": 1, "slug": "sleepy-bear", "title": "Sleepy Bear", "type": "sticker", "file": {
            "md": {"gif": {"url": "https://static.klipy.com/ii/a/md.gif", "width": 423, "height": 343, "size": 488433},
                   "webp": {"url": "https://static.klipy.com/ii/a/md.webp", "width": 423, "height": 343, "size": 219022},
                   "webm": {"url": "https://static.klipy.com/ii/a/md.webm", "width": 423, "height": 344, "size": 1}},
            "sm": {"webp": {"url": "https://static1.klipy.com/ii/a/sm.webp", "width": 200, "height": 167, "size": 78132},
                   "mp4": {"url": "https://static.klipy.com/ii/a/sm.mp4", "width": 200}}
          }, "blur_preview": "data:image/jpeg;base64,AAA"},
          {"id": 2, "slug": "hello", "title": "Hello", "type": "gif", "file": {
            "md": {"gif": {"url": "https://static.klipy.com/ii/b/md.gif", "width": 498, "height": 498, "size": 3721260}},
            "xs": {"gif": {"url": "https://static.klipy.com/ii/b/xs.gif", "width": 90, "height": 90, "size": 71468}}
          }},
          {"id": 3, "type": "ad", "content": "<div/>"},
          {"id": 4, "slug": "nofile", "title": "x", "type": "gif"}
        ], "current_page": 2, "per_page": 24, "has_next": true}}
        """.utf8)

    @Test("a page keeps KLIPY's order, picks preview and sent files, and skips entries without usable files")
    func parse() throws {
        let stickers = try KlipyResponseParser.page(from: response, kind: .stickers)
        #expect(stickers.page == 2 && stickers.hasNext)
        #expect(stickers.items.map(\.slug) == ["sleepy-bear", "hello"])
        let bear = stickers.items[0]
        #expect(bear.preview.url == "https://static1.klipy.com/ii/a/sm.webp")
        #expect(bear.shared.url == "https://static.klipy.com/ii/a/md.webp")
        #expect(bear.id == "stickers/sleepy-bear" && bear.title == "Sleepy Bear")

        let gifs = try KlipyResponseParser.page(from: response, kind: .gifs)
        #expect(gifs.items[0].shared.url == "https://static.klipy.com/ii/a/md.gif")
        #expect(gifs.items[1].preview.url == "https://static.klipy.com/ii/b/xs.gif")
    }

    @Test("a failed or unreadable response is an error")
    func failures() {
        #expect(throws: HaloError.internal(code: "KLIPY_RESULT")) { try KlipyResponseParser.page(from: Data(#"{"result": false}"#.utf8), kind: .gifs) }
        #expect(throws: HaloError.internal(code: "KLIPY_DECODE")) { try KlipyResponseParser.page(from: Data("<html>".utf8), kind: .gifs) }
    }

    @Test("only a message that is exactly one https KLIPY media link counts")
    func links() {
        #expect(KlipyLink.mediaURL(in: " https://static.klipy.com/ii/b/md.gif \n")?.absoluteString == "https://static.klipy.com/ii/b/md.gif")
        #expect(KlipyLink.mediaURL(in: "https://static2.klipy.com/x/y.WEBP") != nil)
        #expect(KlipyLink.mediaURL(in: "look https://static.klipy.com/ii/b/md.gif") == nil)
        #expect(KlipyLink.mediaURL(in: "http://static.klipy.com/ii/b/md.gif") == nil)
        #expect(KlipyLink.mediaURL(in: "https://api.klipy.com/a.gif") == nil)
        #expect(KlipyLink.mediaURL(in: "https://evilklipy.com/a.gif") == nil)
        #expect(KlipyLink.mediaURL(in: "https://static.klipy.com/a.mp4") == nil)
    }

    @Test("shelf: favourites toggle at the front; recents move to the front, dedupe and cap; filtered by kind")
    func shelf() throws {
        let page = try KlipyResponseParser.page(from: response, kind: .stickers)
        let (bear, hello) = (page.items[0], page.items[1])
        var shelf = KlipyShelf()
        shelf.toggleFavourite(bear)
        shelf.toggleFavourite(hello)
        #expect(shelf.favourites.map(\.slug) == ["hello", "sleepy-bear"])
        shelf.toggleFavourite(hello)
        #expect(!shelf.isFavourite(hello) && shelf.isFavourite(bear))

        shelf.recordSent(bear)
        shelf.recordSent(hello)
        shelf.recordSent(bear)
        #expect(shelf.recents.map(\.slug) == ["sleepy-bear", "hello"])
        #expect(shelf.recents(.gifs).isEmpty && shelf.recents(.stickers).count == 2)

        for index in 0..<40 {
            shelf.recordSent(KlipyItem(slug: "s\(index)", kind: .gifs, title: "", preview: bear.preview, shared: bear.shared))
        }
        #expect(shelf.recents.count == KlipyShelf.maxRecents && shelf.recents.first?.slug == "s39")
    }

    @Test("the shelf survives a JSON round trip")
    func codable() throws {
        let page = try KlipyResponseParser.page(from: response, kind: .gifs)
        var shelf = KlipyShelf()
        shelf.toggleFavourite(page.items[0])
        shelf.recordSent(page.items[1])
        let decoded = try JSONDecoder().decode(KlipyShelf.self, from: JSONEncoder().encode(shelf))
        #expect(decoded == shelf)
    }
}
