import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("SearchIndexPolicy")
struct SearchIndexPolicyTests {
    private func room(_ number: Int) throws -> RoomID { try RoomID("!r\(number):x.org") }

    @Test("history is read only when nothing speaks against it; the person's own pause comes first")
    func pause() {
        #expect(SearchIndexPolicy.pause(.init()) == nil)
        #expect(SearchIndexPolicy.pause(.init(pausedByUser: true, lowPower: true, offline: true)) == .user)
        #expect(SearchIndexPolicy.pause(.init(mayRun: false)) == .background)
        #expect(SearchIndexPolicy.pause(.init(lowPower: true)) == .lowPower)
        #expect(SearchIndexPolicy.pause(.init(isHot: true)) == .hot)
        #expect(SearchIndexPolicy.pause(.init(onMobileData: true)) == .mobileData)
        #expect(SearchIndexPolicy.pause(.init(onMobileData: true, mobileDataAllowed: true)) == nil)
        #expect(SearchIndexPolicy.pause(.init(isBusy: true)) == .busy)
    }

    @Test("a catch-up checks every touched room, a later response only rooms with many messages")
    func checks() throws {
        let a = try room(1), b = try room(2)
        func events(_ room: RoomID, _ count: Int) throws -> [SearchLiveEvent] { try (0..<count).map { .undecryptable(room, try EventID("$\($0)")) } }
        let many = SearchLiveBatch(events: try events(a, 5) + events(b, 4), touched: [a, b])
        #expect(SearchIndexPolicy.roomsToCheck(many) == [a])
        #expect(SearchIndexPolicy.roomsToCheck(SearchLiveBatch(touched: [a, b], left: [b], isCatchUp: true)) == [a])
    }

    @Test("a gap is read from outside a thread")
    func gapStart() throws {
        func message(_ id: String, _ threaded: Bool = false) throws -> SearchRecentMessage { SearchRecentMessage(event: try EventID("$\(id)"), isThreaded: threaded) }
        let recent = [try message("5", true), try message("4"), try message("3", true), try message("2"), try message("1")]
        func known(_ ids: String...) throws -> Set<EventID> { Set(try ids.map { try EventID("$\($0)") }) }
        #expect(SearchIndexPolicy.gapStart(recent: recent, known: try known("1", "2", "3", "4", "5")) == .none)
        #expect(SearchIndexPolicy.gapStart(recent: recent, known: try known("1", "2", "4", "5")) == .from(try EventID("$4")))
        #expect(SearchIndexPolicy.gapStart(recent: recent, known: try known("3", "4", "5")) == .from(try EventID("$2")))
        #expect(SearchIndexPolicy.gapStart(recent: recent, known: try known("4")) == .newest)
        #expect(SearchIndexPolicy.gapStart(recent: [], known: []) == .none)
    }

    @Test("searched back to: the newest of the oldest messages of rooms still being read; unknown while one wasn't read at all")
    func coverage() throws {
        let a = try room(1), b = try room(2), c = try room(3)
        func state(_ room: RoomID, _ state: RoomSearchState, _ oldest: Double?) -> RoomSearchCoverage {
            RoomSearchCoverage(room: room, state: state, anchor: nil, oldest: oldest.map { Date(timeIntervalSince1970: $0) })
        }
        let known = [a: state(a, .complete, 1), b: state(b, .partial, 500), c: state(c, .partial, 900)]
        #expect(SearchIndexPolicy.searchedBackTo([a, b, c], coverage: known) == Date(timeIntervalSince1970: 900))
        #expect(SearchIndexPolicy.searchedBackTo([a, b, c, try room(4)], coverage: known) == nil)
        #expect(SearchIndexPolicy.searchedBackTo([a], coverage: known) == nil)
        #expect(SearchIndexPolicy.retryDelay(attempts: 1) == 60 && SearchIndexPolicy.retryDelay(attempts: 50) == 43_200)
        #expect(SearchIndexPolicy.backoff(afterFailures: 1) == .seconds(5) && SearchIndexPolicy.backoff(afterFailures: 99) == .seconds(300))
    }
}
