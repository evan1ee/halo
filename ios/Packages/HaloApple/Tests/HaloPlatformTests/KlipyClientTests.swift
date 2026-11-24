import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPlatform

@Suite("KlipyClient")
struct KlipyClientTests {
    private let client = KlipyClient(appKey: "KEY", customerID: "cid", locale: "de")

    @Test("list URLs put the key in the path and send page, size, customer, filter, query and region")
    func listURL() throws {
        let url = try client.listURL(.stickers, endpoint: "search", query: "happy cat", page: 0)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "api.klipy.com" && components.path == "/api/v1/KEY/stickers/search")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == ["page": "1", "per_page": "24", "customer_id": "cid", "content_filter": "medium", "q": "happy cat", "locale": "de"])
    }

    @Test("trending has no q")
    func trendingURL() throws {
        let url = try client.listURL(.gifs, endpoint: "trending", query: nil, page: 3)
        #expect(!url.absoluteString.contains("q=") && url.absoluteString.contains("page=3"))
    }

    @Test("the customer ID is random, then stable")
    func customerID() throws {
        let defaults = try #require(UserDefaults(suiteName: "KlipyClientTests-\(UUID())"))
        let first = KlipyClient.customerID(defaults)
        #expect(UUID(uuidString: first) != nil)
        #expect(KlipyClient.customerID(defaults) == first)
    }

    @Test("no key configured, no client")
    func unconfigured() {
        #expect(KlipyClient.configured(bundle: Bundle(for: Marker.self)) == nil)
    }

    @Test("only KLIPY media URLs are fetched")
    func mediaGuard() async throws {
        let url = try #require(URL(string: "https://example.com/a.gif"))
        await #expect(throws: HaloError.invalidInput("NOT_KLIPY_MEDIA")) { try await client.media(url) }
    }

    @Test("the session keeps nothing on disk")
    func ephemeral() {
        let session = KlipyClient.makeSession()
        #expect(session.configuration.urlCache == nil && session.configuration.httpCookieStorage == nil)
    }
}

private final class Marker {}

@Suite("KlipyShelfStore")
struct KlipyShelfStoreTests {
    @Test("saves and loads per account, keyed without the Matrix ID")
    func roundTrip() async throws {
        let defaults = try #require(UserDefaults(suiteName: "KlipyShelfStoreTests-\(UUID())"))
        let alice = KlipyShelfStore(account: try UserID("@alice:example.org"), defaults: defaults)
        let bob = KlipyShelfStore(account: try UserID("@bob:example.org"), defaults: defaults)
        #expect(!alice.key.contains("alice") && alice.key != bob.key)
        var shelf = KlipyShelf()
        let rendition = KlipyRendition(url: "https://static.klipy.com/a.gif", width: 1, height: 1, size: 1)
        shelf.toggleFavourite(KlipyItem(slug: "a", kind: .gifs, title: "A", preview: rendition, shared: rendition))
        await alice.save(shelf)
        #expect(await alice.load() == shelf)
        #expect(await bob.load() == KlipyShelf())
    }
}
