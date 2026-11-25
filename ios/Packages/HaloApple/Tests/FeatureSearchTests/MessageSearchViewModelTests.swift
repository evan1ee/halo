import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureSearch

@Suite("MessageSearchViewModel (FeatureSearch)", .timeLimit(.minutes(1)))
struct MessageSearchViewModelTests {
    @Test("searches what is typed, resolves room names, marks matches, pages, filters and clears")
    @MainActor
    func searches() async throws {
        let room = try RoomID("!a:x.org")
        let port = FakeSearchPort(
            corpus: [
                MessageSearchHit(roomID: room, eventID: try EventID("$1"), senderID: "@bob:x.org", senderName: "Bob", body: "the deploy checklist", timestamp: Date(timeIntervalSince1970: 200)),
                MessageSearchHit(roomID: room, eventID: try EventID("$2"), threadRoot: try EventID("$r"), senderID: "@bob:x.org", senderName: nil, body: "deploy.pdf", timestamp: Date(timeIntervalSince1970: 100), kind: .file),
            ],
            pageSize: 1)
        var activity = 0
        let model = MessageSearchViewModel(
            coordinator: SearchCoordinator(port: port, sleep: { _ in }), roomName: { $0 == room ? "Ops" : "Unknown" }, onActivity: { activity += 1 })
        await model.start()
        model.query = "deploy"
        while model.rows.isEmpty { await Task.yield() }
        #expect(model.rows[0].roomName == "Ops" && model.rows[0].sender == "Bob" && model.hasMore && activity == 1)
        #expect(model.rows[0].highlights == [4..<10])
        await model.loadMore()
        while model.rows.count < 2 { await Task.yield() }
        #expect(model.rows[1].sender == "@bob:x.org" && model.rows[1].threadRoot?.rawValue == "$r" && !model.hasMore)
        model.filter = .files
        while model.rows.count != 1 || model.isLoading { await Task.yield() }
        #expect(model.rows[0].kind == .file)
        model.query = ""
        while !model.rows.isEmpty { await Task.yield() }
        #expect(model.filter == .all && model.searchedQuery.isEmpty)
    }

    @Test("the coverage notice: how far back, why it waits, what can't be read; nothing when all is searchable (FR-13)")
    func coverage() {
        let march = Date(timeIntervalSince1970: 1_710_000_000)
        func text(_ status: SearchIndexStatus, verify: Bool = false) -> MessageSearchViewModel.Coverage? {
            MessageSearchViewModel.coverage(status, canVerify: verify, locale: Locale(identifier: "en_GB"))
        }
        #expect(text(SearchIndexStatus()) == nil)
        #expect(text(SearchIndexStatus(phase: .done, completeRooms: 3, totalRooms: 3)) == nil)
        #expect(text(SearchIndexStatus(phase: .indexing, completeRooms: 1, totalRooms: 3))?.text == "Reading your chats · 1 of 3 chats complete")
        #expect(text(SearchIndexStatus(phase: .paused(.lowPower), completeRooms: 1, totalRooms: 3, searchedBackTo: march))?.text
            == "Searched back to March 2024 · 1 of 3 chats complete\nPaused in Low Power Mode.")
        let missing = text(SearchIndexStatus(phase: .done, completeRooms: 3, totalRooms: 3, statistics: .init(undecryptable: 2)), verify: true)
        #expect(missing?.text == "2 messages can't be searched: their keys aren't on this device." && missing?.canVerify == true)
    }
}
